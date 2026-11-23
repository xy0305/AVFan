import Foundation
import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI

/// Pure shipping ownership policy, also executed by the CI regression harness.
struct PlaybackAudioOwnership {
    private(set) var owners: Set<UUID> = []
    private(set) var generation = 0
    mutating func acquire(_ id: UUID) {
        owners.insert(id)
        generation += 1
    }
    mutating func release(_ id: UUID) -> Int {
        owners.remove(id)
        generation += 1
        return generation
    }
    func mayDeactivate(_ token: Int) -> Bool {
        owners.isEmpty && generation == token
    }
}

/// Only concrete media playback owns the exclusive session, never app/page visibility.
@MainActor
final class PlaybackAudioSession {
    static let shared = PlaybackAudioSession()
    private var ownership = PlaybackAudioOwnership()
    private var active = false
    private var needsDeactivation = false

    func acquire(_ id: UUID) {
        ownership.acquire(id)
        // The engine/AVKit may activate too, even if our own attempt was refused.
        needsDeactivation = true
        do {
            if !active {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            }
            // Also reassert after an OS interruption. Do not reset a live category on seek/source changes.
            try AVAudioSession.sharedInstance().setActive(true)
            active = true
        } catch {
            NSLog("AVDB playback audio activation failed: %@", error.localizedDescription)
        }
    }

    func release(_ id: UUID) {
        let token = ownership.release(id)
        // Coalesce SwiftUI source/episode replacement, including .id(url), without an audible session bounce.
        deactivateWhenIdle(token: token, attempts: 3)
    }

    private func deactivateWhenIdle(token: Int, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
            guard ownership.mayDeactivate(token), needsDeactivation else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                active = false
                needsDeactivation = false
            } catch {
                NSLog("AVDB playback audio deactivation failed: %@", error.localizedDescription)
                if attempts > 1 { deactivateWhenIdle(token: token, attempts: attempts - 1) }
            }
        }
    }
}

@MainActor
final class PlaybackAudioLease: ObservableObject {
    private let id = UUID()
    func begin() { PlaybackAudioSession.shared.acquire(id) }
    func end() { PlaybackAudioSession.shared.release(id) }
    deinit {
        let id = id
        DispatchQueue.main.async { PlaybackAudioSession.shared.release(id) }
    }
}

/// The underlying representable's destruction, not onDisappear, is the terminal boundary.
/// Build 59: MPlayPlayer (libmpv) renders into MPlayVideoView. Audio ownership
/// is acquired BEFORE the player core is created in makeUIView, as before.
struct AudioOwnedMPlayVideoView: UIViewRepresentable {
    let engine: MPlayChromeCoordinator
    let audio: PlaybackAudioLease
    let url: URL
    let headers: [String: String]
    let onStop: () -> Void
    final class Coordinator {
        let engine: MPlayChromeCoordinator
        let audio: PlaybackAudioLease
        let onStop: () -> Void
        weak var videoView: MPlayVideoView?
        var openedURL: URL?
        init(engine: MPlayChromeCoordinator, audio: PlaybackAudioLease, onStop: @escaping () -> Void) {
            self.engine = engine
            self.audio = audio
            self.onStop = onStop
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(engine: engine, audio: audio, onStop: onStop) }
    func makeUIView(context: Context) -> MPlayVideoView {
        audio.begin()
        let view = MPlayVideoView()
        context.coordinator.videoView = view
        engine.open(url: url, headers: headers)
        context.coordinator.openedURL = url
        if let player = engine.player { view.attach(player: player) }
        installStopCommand(context: context)
        return view
    }
    private func installStopCommand(context: Context) {
        // Replace ONLY the stop command; preserve play/pause/seek/rate and all other controls.
        let coordinator = context.coordinator
        let command = MPRemoteCommandCenter.shared().stopCommand
        command.removeTarget(nil)
        command.addTarget { _ in
            Task { @MainActor in
                coordinator.engine.pause()
                coordinator.audio.end()
            }
            return .success
        }
    }
    func updateUIView(_ view: MPlayVideoView, context: Context) {
        if context.coordinator.openedURL != url {
            audio.begin()
            engine.open(url: url, headers: headers)
            context.coordinator.openedURL = url
            if let player = engine.player { view.attach(player: player) }
            installStopCommand(context: context)
        }
    }
    static func dismantleUIView(_ view: MPlayVideoView, coordinator: Coordinator) {
        // Build 59 deviation: PiP is not implemented in this build, so
        // there is no PiP wait here (the KSPlayer-era dismantle deferred
        // teardown while PiP was active). The original's PiP route is
        // known (pixel-frame pipeline + AVSampleBufferDisplayLayer,
        // IOS-FINDINGS §1) and is next build's first item; teardown here
        // stays immediate: stop callback, detach the render
        // surface BEFORE closing the core, then release audio ownership.
        Task { @MainActor in
            coordinator.onStop()
            view.detach()
            coordinator.engine.reset()
            coordinator.audio.end()
        }
    }
}

/// Stable Apple VideoPlayer storage. Constructing the preview alone does not activate audio.
@MainActor
final class TrailerPlayback: ObservableObject {
    let player: AVPlayer
    /// Invoked when the item fails to load, so the host can fall back.
    var onFailed: (() -> Void)?
    private let audio = PlaybackAudioLease()
    private var observation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?

    init(url: URL, headers: [String: String] = [:]) {
        if headers.isEmpty {
            player = AVPlayer(url: url)
        } else {
            // The literal option key: the SDK's renamed constant is
            // not visible in this build configuration.
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        observation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            // Waiting is already a real play request. Pause retains ownership for instant resume.
            guard player.timeControlStatus != .paused else { return }
            Task { @MainActor [weak self] in
                guard let self, self.player.timeControlStatus != .paused,
                      self.player.currentItem?.status != .failed else { return }
                self.audio.begin()
            }
        }
        itemObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onFailed?()
                self.finish()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.finish() }
            }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
            object: player.currentItem, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.onFailed?()
                    self.finish()
                }
            }
    }
    func finish() {
        player.pause()
        audio.end()
    }
    deinit {
        observation?.invalidate()
        itemObservation?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        player.pause()
        // audio lease deinit releases after the final player is stopped; no visibility hook needed.
    }
}

/// AVKit controls (same native controls as VideoPlayer), with an explicit PiP teardown boundary.
struct AudioOwnedTrailerPlayer: UIViewControllerRepresentable {
    let playback: TrailerPlayback
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let playback: TrailerPlayback
        var pictureInPicture = false
        init(_ playback: TrailerPlayback) { self.playback = playback }
        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            pictureInPicture = true
        }
        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            pictureInPicture = false
        }
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  failedToStartPictureInPictureWithError error: Error) {
            pictureInPicture = false
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(playback) }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = playback.player
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        Task { @MainActor in
            while coordinator.pictureInPicture {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            coordinator.playback.finish()
            controller.player = nil
            controller.delegate = nil
        }
    }
}
