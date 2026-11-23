//
//  MPlayEngine.swift
//  AVFan
//
//  Build 59: chrome-side coordinator over MPlayPlayer (libmpv), replacing
//  KSVideoPlayer.Coordinator + KSPlayerLayer. Owns one MPlayPlayer core for
//  the lifetime of one player screen; the view layer (AudioOwnedMPlayVideoView)
//  attaches an MPlayVideoView to `player` and calls open(...) here.
//
//  State is derived by polling MPlayPlayer.state()/progress() from the
//  chrome's existing 500 ms ticker (poll()), plus MPlayPlayer.onPlaybackEvent
//  for terminal edges. A monotonically increasing load generation replaces
//  the old `coordinator.playerLayer === layer` identity guards: every open()
//  bumps it, and callbacks carry the generation they belong to.
//

import Foundation
import SwiftUI

/// Fill behaviour, mapped to mpv properties in applyFillMode().
enum MPlayFillMode {
    case fit, fill, stretch
}

@MainActor
final class MPlayChromeCoordinator: ObservableObject {
    enum Phase {
        case idle, preparing, buffering, ready, ended, failed
    }

    /// The mpv core. Created lazily on first open(); nil after reset().
    private(set) var player: MPlayPlayer?
    private(set) var loadGeneration = 0
    private(set) var currentURL: URL?

    /// Stage B: the attached view's PiP controller, filled in by
    /// AudioOwnedMPlayVideoView (weak — the view owns it).  Chrome's
    /// PiP button goes through this slot, mirroring how the
    /// KSPlayer-era chrome reached the layer's pipController.
    weak var pictureInPictureController: MPlayPictureInPictureController?

    // Polled snapshot, refreshed by poll().
    private(set) var phase: Phase = .idle
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var cacheSpeed: Int64 = 0
    private(set) var videoSize: (width: Double, height: Double)?

    /// Fired once per load when playback first becomes ready (file loaded and
    /// not failed). The chrome applies resume / fill / rate there.
    var onReady: ((Int) -> Void)?
    /// Fired once per load on a terminal failure (open failure, END_FILE error,
    /// or state phase == failed). Carries the load generation.
    var onFailure: ((Int) -> Void)?
    /// Fired once per load when the file plays to its end.
    var onEnded: ((Int) -> Void)?

    private var readyFired = false
    private var failureFired = false
    private var endedFired = false
    private var fileLoaded = false
    private var createFailed = false

    // MARK: - Lifecycle

    private func ensurePlayer() -> MPlayPlayer? {
        if let player { return player }
        do {
            let created = try MPlayPlayer()
            created.onPlaybackEvent = { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handle(event)
                }
            }
            player = created
            return created
        } catch {
            createFailed = true
            return nil
        }
    }

    /// Opens (or replaces) the media on the shared core. Audio ownership is
    /// the caller's job and must begin before this is called.
    func open(url: URL, headers: [String: String]) {
        loadGeneration += 1
        let generation = loadGeneration
        currentURL = url
        readyFired = false
        failureFired = false
        endedFired = false
        fileLoaded = false
        createFailed = false
        phase = .preparing
        isPlaying = false
        position = 0
        duration = 0
        cacheSpeed = 0
        videoSize = nil
        guard let player = ensurePlayer() else {
            phase = .failed
            fireFailure(generation)
            return
        }
        player.open(url: url.absoluteString, headers: headers, autoplay: true) { [weak self] result in
            if case .failure = result {
                Task { @MainActor [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    self.phase = .failed
                    self.fireFailure(generation)
                }
            }
        }
    }

    /// Terminal teardown: close the core and forget it. The video view must
    /// detach BEFORE this is called (the frame sink unregisters before
    /// the core is destroyed).
    func reset() {
        player?.close()
        player = nil
        currentURL = nil
        phase = .idle
        isPlaying = false
    }

    // MARK: - Transport

    func play() {
        player?.setPaused(false)
    }

    func pause() {
        player?.setPaused(true)
    }

    var engineIsPlaying: Bool {
        guard let player else { return false }
        return !player.state().paused && fileLoaded
    }

    /// Seek with completion on PLAYBACK_RESTART (MPlayPlayer.seek semantics).
    /// After the seek lands, autoPlay decides the pause flag, mirroring
    /// KSPlayer's seek(time:autoPlay:).
    func seek(to seconds: Double, autoPlay: Bool, completion: (() -> Void)? = nil) {
        guard let player else { completion?(); return }
        player.seek(to: seconds) { [weak self] in
            Task { @MainActor [weak self] in
                if autoPlay { self?.player?.setPaused(false) }
                completion?()
            }
        }
    }

    func setRate(_ rate: Double) {
        player?.setRate(rate)
    }

    func applyFillMode(_ mode: MPlayFillMode) {
        guard let player else { return }
        switch mode {
        case .fit:
            player.setProp("keepaspect", "yes")
            player.setProp("panscan", "0.0")
        case .fill:
            player.setProp("keepaspect", "yes")
            player.setProp("panscan", "1.0")
        case .stretch:
            player.setProp("keepaspect", "no")
        }
    }

    // MARK: - External subtitles (Build 59: engine-rendered via libass)

    /// Adds an already-downloaded local subtitle file. The engine never
    /// fetches remote subtitle URLs (see MPlayChromePlayer subtitle wiring).
    func addSubtitle(localFile url: URL, encodingHint: String) {
        guard let player else { return }
        let codepage: String
        switch encodingHint.lowercased() {
        case "utf8", "utf-8": codepage = "UTF-8"
        case "gb18030", "gbk": codepage = "GB18030"
        case "big5": codepage = "BIG5"
        default: codepage = "auto"
        }
        if codepage != "auto" { player.setProp("sub-codepage", codepage) }
        player.addSubtitle(url: url.path)
    }

    /// Removes every external subtitle track previously added via sub-add.
    func removeExternalSubtitles() {
        guard let player else { return }
        let json = player.mediaJSON()
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = root["tracks"] as? [[String: Any]] else { return }
        for track in tracks {
            let kind = track["kind"] as? String
            let external = track["external"] as? Bool ?? false
            guard kind == "subtitle", external, let id = track["id"] as? NSNumber else { continue }
            player.command(["sub-remove", id.stringValue])
        }
    }

    func setSubtitleDelay(_ seconds: Double) {
        player?.setProp("sub-delay", String(seconds))
    }

    func setSubtitleFontSize(points: Double) {
        // mpv sub-font-size is in ASS points at a 720-line reference height;
        // the overlay's 18 pt default maps to mpv's default 55 (≈ ×3).
        player?.setProp("sub-font-size", String(max(10, points * 3)))
    }

    func setSubtitlePosition(y: Double) {
        player?.setProp("sub-pos", String(min(150, max(0, y * 100))))
    }

    func setSubtitleAlignmentX(x: Double) {
        let align = x < 1.0 / 3.0 ? "left" : (x > 2.0 / 3.0 ? "right" : "center")
        player?.setProp("sub-align-x", align)
    }

    // MARK: - Events / polling

    private func handle(_ event: MPlayPlaybackEvent) {
        switch event {
        case .fileLoaded:
            fileLoaded = true
        case .endFileError:
            phase = .failed
            fireFailure(loadGeneration)
        case .endFileEOF:
            if !endedFired {
                endedFired = true
                phase = .ended
                onEnded?(loadGeneration)
            }
        case .playbackRestart:
            break
        }
    }

    private func fireFailure(_ generation: Int) {
        guard !failureFired else { return }
        failureFired = true
        onFailure?(generation)
    }

    /// Called from the chrome ticker (~500 ms). Refreshes the snapshot and
    /// fires the ready edge exactly once per load.
    func poll() {
        guard let player, currentURL != nil else { return }
        let state = player.state()
        let progress = player.progress()
        position = progress.time
        if progress.duration > 0 { duration = progress.duration }
        cacheSpeed = progress.cacheSpeed
        if videoSize == nil { videoSize = player.videoSize() }
        isPlaying = state.phase == "playing"
        switch state.phase {
        case "failed":
            phase = .failed
            fireFailure(loadGeneration)
        case "ended":
            if !endedFired {
                endedFired = true
                phase = .ended
                onEnded?(loadGeneration)
            }
        case "preparing":
            if phase != .failed { phase = .preparing }
        case "playing", "paused":
            if progress.pausedForCache {
                phase = .buffering
            } else if fileLoaded || state.phase == "playing" {
                phase = .ready
                if !readyFired {
                    readyFired = true
                    onReady?(loadGeneration)
                }
            }
        default:
            break
        }
        if phase == .ready, progress.pausedForCache { phase = .buffering }
    }
}
