//
//  MPlayChromePlayer.swift
//  AVFan
//
//  Build 59: the player chrome, unchanged in UI and behaviour from the
//  KSPlayer-era KSChromePlayer (itself ported from AVDB build 351/332),
//  re-bound to the restored MPlayKit engine (libmpv + FFmpeg 8) via
//  MPlayChromeCoordinator (MPlayEngine.swift). No kernel switch: MPlayKit
//  is the only engine. Deviations vs the KSPlayer era (PiP above all) are
//  listed in Build59-MPlayKit.md. LUT never had an effective path in AVFan
//  (the seek-preview card still says so) and still does not.
//

import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation

struct MPlayChromePlayer: View {
    let url: URL
    var title: String = ""
    var subtitle: String = ""
    var headers: [String: String] = [:]
    /// Online-session opt-in only. Nil leaves AVPlayerItem unconstrained, including 115 and catalog playback.
    var progressID: String? = nil
    var supportsFramePreview: Bool = true
    var onPlaybackFailure: (() -> Void)? = nil
    // A source child must not restore portrait while its owning playback route remains alive.
    var managesOrientation: Bool = true
    var onSelectSource: (() -> Void)? = nil
    var onSelectEpisode: (() -> Void)? = nil
    @State private var failureReported = false
    @State private var playbackDiagnostic: PlaybackDiagnostic?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = MPlayChromeCoordinator()
    @StateObject private var audio = PlaybackAudioLease()
    @StateObject private var seekPreview = SeekPreviewController()
    private let resumeScope = "avfan"
    var publicSubtitleQuery: String = "" // Explicit public metadata only; never infer from URL/title/path.
    var onVideoMetrics: ((URL, PlaybackVideoMetrics?, Bool) -> Void)? = nil
    /// Build 280 续播: 番号 + 来源 key (PlaybackResumeKey). Online session ids change, so the caller
    /// re-resolves the stream and the player seeks to the stored position once the new item is ready.
    var resumeKey: String? = nil
    /// 「从头播放」: ignore any stored position for this session (still records new progress).
    var startFromBeginning: Bool = false
    @State private var resumeHandledURL: URL?
    @State private var resumeToast: TimeInterval?
    @State private var resumeToastTask: Task<Void, Never>?
    @State private var lastVideoMetrics: PlaybackVideoMetrics?
    @State private var metricsSettled = false
    @State private var qualityGeneration = 0
    @StateObject private var onlineSubtitles = OnlineSubtitleModel()
    @State private var showOnlineSubtitles = false
    @State private var editingSubtitlePosition = false
    @State private var adjustSubtitleAfterDismiss = false
    @State private var playbackActive = false
    @State private var isPlaying = false
    @State private var isBuffering = true
    @State private var hasStarted = false
    @State private var showChrome = true
    @State private var hideTask: Task<Void, Never>?
    @State private var tickTask: Task<Void, Never>?

    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isSeeking = false
    @State private var seekValue: Double = 0

    @State private var overlay: OverlayKind?
    @State private var overlayValue: Double = 0
    @State private var adjustmentNotice: String?
    @State private var seekPending = false
    @State private var seekGeneration = 0
    @State private var horizontalDrag = false
    @State private var scrubStart: Double = 0
    @State private var skipHUD: SkipHUD?
    @State private var fillMode: FillMode = .fit
    /// Build 323 倍速: session choice, re-applied to a replaced item / reset player layer.
    @State private var playbackRate: Float = 1.0
    /// Build 59: true while the selected online subtitle is rendered by the
    /// engine (libass via sub-add of the downloaded file). The text overlay
    /// is then suppressed except in position-edit mode (its preview).
    @State private var engineSubtitleActive = false
    @AppStorage("subtitle.fontPoints") private var subtitleFontPoints = SubtitleStyleDefaults.size
    @AppStorage("subtitle.positionX") private var subtitlePositionX = SubtitleStyleDefaults.x
    @AppStorage("subtitle.positionY") private var subtitlePositionY = SubtitleStyleDefaults.y
    /// Build 323: measured network bytes/s (AVPlayerItem access log); nil = not measurable → hidden.
    @State private var downloadSpeed: Double?

    private enum OverlayKind { case brightness, volume, seek }
    private enum FillMode: String, CaseIterable {
        case fit = "适应屏幕"
        case fill = "填满屏幕"
        case stretch = "拉伸填满"
    }
    private struct SkipHUD: Equatable {
        var forward: Bool
        var seconds: Int
    }

    /// Build 59 subtitle wiring: when the model finishes loading a selection
    /// (cues set + downloaded bytes retained), hand the local file to the
    /// engine. mpv only ever sees a local path — the hardened download path
    /// in OnlineSubtitleModel stays the only network fetch, so no playback
    /// headers/cookies can leak to subtitle CDNs.
    private func syncEngineSubtitle() {
        guard engineSubtitleActive else { return }
        engine.setSubtitleDelay(onlineSubtitles.offset)
        engine.setSubtitleFontSize(points: subtitleFontPoints)
        engine.setSubtitlePosition(y: subtitlePositionY)
        engine.setSubtitleAlignmentX(x: subtitlePositionX)
    }

    private func activateEngineSubtitleIfPossible() {
        guard !onlineSubtitles.cues.isEmpty,
              let data = onlineSubtitles.selectedFileData,
              let ext = onlineSubtitles.selectedFileExt else {
            engineSubtitleActive = false
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("avfan-subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("selected.\(ext)")
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            // Fall back to the text overlay; cues are already parsed.
            engineSubtitleActive = false
            return
        }
        engine.removeExternalSubtitles()
        engine.addSubtitle(localFile: file, encodingHint: onlineSubtitles.encodingHint)
        engineSubtitleActive = true
        syncEngineSubtitle()
    }

    private func deactivateEngineSubtitle() {
        if engineSubtitleActive { engine.removeExternalSubtitles() }
        engineSubtitleActive = false
    }

    var body: some View {
        GeometryReader { geo in
            videoArea(height: geo.size.height, width: geo.size.width, safeArea: geo.safeAreaInsets)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .overlay(alignment: .top) {
            if let playbackDiagnostic {
                Text(playbackDiagnostic.display)
                    .font(.caption).foregroundStyle(.white)
                    .padding(10).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 54).padding(.horizontal)
                    .accessibilityIdentifier("player.safe-diagnostic")
                    .allowsHitTesting(false)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .statusBarHidden(true)
        .background { if managesOrientation { PlaybackOrientationHost().allowsHitTesting(false) } }
        .sheet(isPresented: $showOnlineSubtitles, onDismiss: {
            showChrome = true
            startTicker()
            scheduleHide()
            if adjustSubtitleAfterDismiss {
                adjustSubtitleAfterDismiss = false
                editingSubtitlePosition = true
                showChrome = false
                hideTask?.cancel()
            }
        }) { OnlineSubtitlePanel(model: onlineSubtitles, adjustPosition: {
            adjustSubtitleAfterDismiss = true
            showOnlineSubtitles = false
        }) }
        .onChange(of: showOnlineSubtitles) { _, presented in
            if presented { cancelPlayerDrag(); hideTask?.cancel(); showChrome = true }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            configureSeekPreview()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--subtitle-controls-fixture"), !ProcessInfo.processInfo.arguments.contains("--subtitle-no-cue") {
                onlineSubtitles.cues = [.init(start: 0, end: 120, text: "中性字幕样式测试\n第二行保留完整文本")]
            }
            #endif
            guard !playbackActive else {
                showChrome = true
                startTicker()
                return
            }
            playbackActive = true
            // Audio ownership starts in AudioOwnedMPlayVideoView.makeUIView, before MPlayPlayer creation.
            wireEngine()
            startTicker()
            scheduleHide()
        }
        .onChange(of: progressID) { _, _ in onlineSubtitles.clear() }
        .onChange(of: publicSubtitleQuery) { _, _ in onlineSubtitles.clear() }
        .onChange(of: onlineSubtitles.cues) { _, _ in activateEngineSubtitleIfPossible() }
        .onChange(of: onlineSubtitles.selected) { _, _ in
            if onlineSubtitles.selected == nil { deactivateEngineSubtitle() }
        }
        .onChange(of: onlineSubtitles.offset) { _, _ in syncEngineSubtitle() }
        .onChange(of: subtitleFontPoints) { _, _ in syncEngineSubtitle() }
        .onChange(of: subtitlePositionX) { _, _ in syncEngineSubtitle() }
        .onChange(of: subtitlePositionY) { _, _ in syncEngineSubtitle() }
        .onChange(of: url) { _, _ in
            qualityGeneration += 1
            playbackDiagnostic = nil
            failureReported = false
            editingSubtitlePosition = false
            deactivateEngineSubtitle()
            onlineSubtitles.clear()
            seekGeneration += 1
            seekPending = false
            downloadSpeed = nil
            cancelPlayerDrag()
            configureSeekPreview()
        }
        .onChange(of: headers) { _, _ in
            cancelPlayerDrag()
            configureSeekPreview()
        }
        .onChange(of: supportsFramePreview) { _, _ in
            cancelPlayerDrag()
            configureSeekPreview()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            flushHistory(force: true)
        }
        .onDisappear {
            flushHistory(force: true)
            seekPreview.close()
            // UIKit full-screen/adaptive sheet presentations may disappear the presenter.
            // They must not tear down playback or force the whole app to portrait.
            guard !showOnlineSubtitles else { return }
            // Visibility is not lifetime: background/PiP/covering presentations must keep playing.
            cancelPlayerDrag()
            hideTask?.cancel()
            tickTask?.cancel()
        }
    }

    private func configureSeekPreview() {
        seekPreview.configure(url: url, headers: headers, supported: supportsFramePreview)
    }


    private func stopPlayback() {
        deactivateEngineSubtitle()
        onlineSubtitles.clear()
        seekPreview.close()
        playbackActive = false
        seekGeneration += 1
        seekPending = false
        cancelPlayerDrag()
        hideTask?.cancel()
        tickTask?.cancel()
        engine.pause()
    }

    @ViewBuilder
    private func videoArea(height: CGFloat, width: CGFloat, safeArea: EdgeInsets) -> some View {
        ZStack {
            Color.black
            AudioOwnedMPlayVideoView(engine: engine, audio: audio, url: url, headers: headers, onStop: stopPlayback)
                .onAppear { applyFillMode() }
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let clock = engine.position
                let text = (engineSubtitleActive && !editingSubtitlePosition)
                    ? ""
                    : OnlineSubtitleParser.display(onlineSubtitles.cues, at: clock, offset: onlineSubtitles.offset)
                SubtitlePresentationOverlay(text: text, safeArea: safeArea, editing: editingSubtitlePosition) {
                    editingSubtitlePosition = false
                    showChrome = true
                    scheduleHide()
                }
            }.zIndex(editingSubtitlePosition ? 30 : 20) // Captions remain white above the chrome scrim; normal mode is noninteractive.
            if showChrome {
                chromeOverlay.zIndex(10) // Controls are above the transparent gesture receiver.
                    .padding(.top, safeArea.top)
                    .padding(.leading, safeArea.leading)
                    .padding(.trailing, safeArea.trailing)
                    .padding(.bottom, safeArea.bottom)
            }
            // MPlayVideoView renders only the video surface (no chrome of its own).
            // This transparent sibling owns the only pan output; chrome stays above it.
            PlayerGestureLayer(
                excludedTop: safeArea.top + 80,
                excludedBottom: safeArea.bottom + 116,
                blocked: editingSubtitlePosition || showOnlineSubtitles || seekPending || (isSeeking && !horizontalDrag),
                sourceID: url,
                onDoubleTap: { x, width in
                    AVDBDoubleTapPolicy.perform(x: x, width: width,
                        toggle: { toggleActualPlayback() }, seek: { skip(by: $0) })
                },
                onSingleTap: { toggleChrome() },
                onAdjustment: { side, value, notice in
                    hideTask?.cancel()
                    adjustmentNotice = notice
                    if let value {
                        overlay = side == .brightness ? .brightness : .volume
                        overlayValue = Double(value)
                    } else { overlay = nil }
                },
                onSeekChanged: { dx in handleHorizontalDrag(dx) },
                onEnded: { cancelled in
                    if horizontalDrag && !cancelled {
                        seek(to: seekValue)
                        currentTime = seekValue
                    }
                    cancelPlayerDrag()
                    if showChrome { scheduleHide() }
                }
            )
            if !hasStarted {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.15)
                    .allowsHitTesting(false)
            }
            if let resumeToast {
                // Only the capsule is hit-testable; the rest of the screen stays with the gesture layer.
                resumeToastView(resumeToast, safeArea: safeArea).zIndex(40)
            }
            if let overlay {
                overlayHUD(overlay)
                    .allowsHitTesting(false)
            }
            if let adjustmentNotice {
                Text(adjustmentNotice)
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
                    .allowsHitTesting(false)
            }
            if let skipHUD {
                skipOverlay(skipHUD)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .contentShape(Rectangle())
    }

    private func cancelPlayerDrag() {
        seekPreview.cancel()
        isSeeking = false
        horizontalDrag = false
        overlay = nil
        adjustmentNotice = nil
    }

    private func handleHorizontalDrag(_ dx: CGFloat) {
        guard !seekPending, duration.isFinite, duration > 0 else { return }
        if !horizontalDrag {
            horizontalDrag = true
            isSeeking = true
            scrubStart = currentTime
            seekValue = currentTime
            hideTask?.cancel()
        }
        // Preserve AVDB's duration-dependent horizontal seek scale and bounded preview.
        let secondsPerPoint = duration > 3600 ? 0.55 : 0.35
        seekValue = min(duration, max(0, scrubStart + Double(dx) * secondsPerPoint))
        overlayValue = seekValue
        seekPreview.request(time: seekValue, duration: duration)
        overlay = .seek
    }

    /// Read the engine now, not the asynchronously refreshed chrome state.
    private func toggleActualPlayback() {
        if engine.engineIsPlaying {
            engine.pause()
        } else {
            audio.begin()
            engine.play()
        }
        if showChrome { scheduleHide() }
    }

    private func skip(by seconds: Double) {
        let next = min(max(duration, 0), max(0, currentTime + seconds))
        seek(to: next)
        currentTime = next
        let forward = seconds > 0
        if skipHUD?.forward == forward {
            skipHUD?.seconds += Int(abs(seconds))
        } else {
            skipHUD = SkipHUD(forward: forward, seconds: Int(abs(seconds)))
        }
        hideTask?.cancel()
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            skipHUD = nil
            if showChrome { scheduleHide() }
        }
    }

    private func skipOverlay(_ hud: SkipHUD) -> some View {
        HStack {
            if hud.forward { Spacer() }
            VStack(spacing: 6) {
                Image(systemName: hud.forward ? "goforward.10" : "gobackward.10")
                    .font(.system(size: 28, weight: .semibold))
                Text("\(hud.seconds) 秒")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(16)
            .background(.black.opacity(0.45), in: Circle())
            .padding(.horizontal, 28)
            if !hud.forward { Spacer() }
        }
    }

    @ViewBuilder
    private func overlayHUD(_ kind: OverlayKind) -> some View {
        if kind == .seek {
            seekHUD
        } else {
            levelHUD(kind)
        }
    }

    private var seekHUD: some View {
        seekPreviewCard.frame(width: 192)
    }

    private var seekPreviewCard: some View {
        VStack(spacing: 4) {
            ZStack {
                Color.black.opacity(0.8)
                if let image = seekPreview.image {
                    Image(decorative: image, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                } else {
                    VStack(spacing: 5) {
                        if seekPreview.loading { ProgressView().tint(.white) }
                        Text(seekPreview.loading ? "正在提取画面…" : "此位置暂无预览")
                            .font(.caption2)
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            Text("\(formatTime(seekValue)) / \(formatTime(duration))")
                .font(.caption.monospacedDigit().weight(.semibold))
            Text("原始画面 · 不含 LUT")
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.65))
        }
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("player.seek.preview")
        .allowsHitTesting(false)
    }

    private func levelHUD(_ kind: OverlayKind) -> some View {
        VStack(spacing: 10) {
            Image(systemName: kind == .brightness
                  ? (overlayValue > 0.5 ? "sun.max.fill" : "sun.min.fill")
                  : (overlayValue > 0.01 ? "speaker.wave.2.fill" : "speaker.slash.fill"))
                .font(.system(size: 22, weight: .semibold))
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 6, height: 90)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(Color.white)
                        .frame(height: 90 * overlayValue)
                }
                .clipShape(Capsule())
            Text("\(Int(overlayValue * 100))%")
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Build 323 播放页样式: thin white line icons and plain white text over a light scrim — no capsules,
    /// glass or dark fills. Player chrome matches AVDB (no standalone AirPlay control).
    private var chromeOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                        .frame(width: 52, height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
                .zIndex(20)

                Text(title.isEmpty ? "正在播放" : title)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 420, alignment: .leading)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                Button {
                    if onlineSubtitles.query.isEmpty { onlineSubtitles.query = String(publicSubtitleQuery.prefix(200)) }
                    showOnlineSubtitles = true
                } label: {
                    Image(systemName: onlineSubtitles.cues.isEmpty ? "captions.bubble" : "captions.bubble.fill")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.white).frame(width: 48, height: 48)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .fixedSize().layoutPriority(2).zIndex(20)
                    .accessibilityLabel("在线字幕").accessibilityIdentifier("player.subtitle.settings")
                Spacer(minLength: 8).frame(maxWidth: 16) // keep the three icons grouped at the right

                Menu {
                    if !AdaptiveLayout.isPad {
                    Button("横屏全屏") {
                        OrientationLock.set(.landscapeRight, keepLocked: true)
                    }
                    Button("竖屏播放") {
                        OrientationLock.set(.portrait, keepLocked: true)
                    }
                    }
                    Divider()
                    ForEach(FillMode.allCases, id: \.self) { mode in
                        Button {
                            fillMode = mode
                            applyFillMode()
                        } label: {
                            if fillMode == mode {
                                Label(mode.rawValue, systemImage: "checkmark")
                            } else {
                                Text(mode.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("画面与方向")

                // Real network throughput only (mpv cache-speed); hidden when it cannot be measured.
                if let downloadSpeed {
                    Text(Self.throughputDisplay(downloadSpeed))
                        .font(.system(size: 13, weight: .regular).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                        .lineLimit(1).fixedSize()
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("player.download.speed")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.leading, 12)

            // The UIKit single/double recognizers own the empty video area even with chrome visible.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            progressBar
                .padding(.horizontal, 28)

            HStack(spacing: 18) {
                Button {
                    if isPlaying {
                        engine.pause()
                    } else {
                        audio.begin()
                        engine.play()
                    }
                } label: {
                    Group {
                        if isBuffering {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 26, weight: .regular))
                                .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "暂停" : "播放")
                .accessibilityIdentifier("player.play.toggle")

                Spacer(minLength: 8)


                if let onSelectSource {
                    Button(action: onSelectSource) {
                        chromeTextLabel(subtitle.isEmpty ? "播放源" : subtitle)
                            .frame(maxWidth: 180)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("选择播放源")
                        .accessibilityIdentifier("player.source.settings")
                } else if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 15, weight: .regular)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
                if let onSelectEpisode {
                    Button(action: onSelectEpisode) {
                        chromeTextLabel("选集")
                    }.buttonStyle(.plain)
                        .accessibilityLabel("选择集数")
                        .accessibilityIdentifier("player.episode.settings")
                }

                Menu {
                    ForEach(Self.playbackRates, id: \.self) { rate in
                        Button {
                            selectPlaybackRate(rate)
                        } label: {
                            if playbackRate == rate {
                                Label(Self.rateTitle(rate), systemImage: "checkmark")
                            } else {
                                Text(Self.rateTitle(rate))
                            }
                        }
                    }
                } label: {
                    chromeTextLabel(playbackRate == 1 ? "倍速" : Self.rateTitle(playbackRate))
                }
                .accessibilityLabel("倍速：\(Self.rateTitle(playbackRate))")
                .accessibilityIdentifier("player.playback.rate")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 10)
            .padding(.top, 2)
        }
        .background {
            LinearGradient(
                colors: [Color.black.opacity(0.45), .clear, .clear, Color.black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    /// Plain white text control label (1080P / 选集 / 倍速 style): no capsule, 48pt hit height.
    private func chromeTextLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
    }

    static let playbackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    static func throughputDisplay(_ bytesPerSecond: Double) -> String {
        let mb = 1024.0 * 1024.0
        if bytesPerSecond >= mb { return String(format: "%.1f MB/s", bytesPerSecond / mb) }
        return String(format: "%.0f KB/s", max(0, bytesPerSecond) / 1024.0)
    }

    static func rateTitle(_ rate: Float) -> String {
        let tenths = Double(rate) * 10
        return String(format: tenths == tenths.rounded() ? "%.1fx" : "%.2fx", Double(rate))
    }

    /// 倍速: mpv `speed` property via MPlayPlayer.setRate (applies while paused too; value is re-asserted on ready and every tick).
    private func selectPlaybackRate(_ rate: Float) {
        playbackRate = rate
        applyPlaybackRate()
        scheduleHide()
    }

    /// Re-applied when the engine reports ready and on every tick, so a
    /// replaced source in this session keeps the session's rate choice.
    private func applyPlaybackRate() {
        engine.setRate(Double(playbackRate))
    }

    private var progressBar: some View {
        HStack(spacing: 12) {
            Text(formatTime(isSeeking ? seekValue : currentTime))
                .font(.system(size: 14, weight: .regular).monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                .lineLimit(1)
                .frame(minWidth: 44, alignment: .leading)
                .fixedSize()
            GeometryReader { geo in
                let shown = isSeeking ? seekValue : currentTime
                let fraction = duration > 0 ? CGFloat(min(1, max(0, shown / duration))) : 0
                // Thin drawn track (no glass/capsule wrapper, no large thumb). The real Slider sits on top,
                // nearly transparent, so drag editing, accessibility and UI tests keep the native control.
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.32)).frame(height: 3)
                    Capsule().fill(Color.white).frame(width: max(0, geo.size.width * fraction), height: 3)
                    Circle().fill(Color.white)
                        .frame(width: isSeeking ? 12 : 7, height: isSeeking ? 12 : 7)
                        .offset(x: min(max(0, geo.size.width * fraction - (isSeeking ? 6 : 3.5)), max(0, geo.size.width - (isSeeking ? 12 : 7))))
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .allowsHitTesting(false)
                Slider(
                    value: Binding(
                        get: { isSeeking ? seekValue : currentTime },
                        set: { newValue in
                            guard !seekPending, duration.isFinite, duration > 0 else { return }
                            isSeeking = true
                            seekValue = min(duration, max(0, newValue))
                            seekPreview.request(time: seekValue, duration: duration)
                        }
                    ),
                    in: 0...max(duration, 0.1)
                ) { editing in
                    if editing {
                        guard !seekPending, duration.isFinite, duration > 0 else { return }
                        hideTask?.cancel()
                        if !isSeeking { seekValue = min(duration, max(0, currentTime)) }
                        isSeeking = true
                        seekPreview.request(time: seekValue, duration: duration)
                    } else if isSeeking && !horizontalDrag {
                        seek(to: seekValue)
                        currentTime = seekValue
                        isSeeking = false
                        seekPreview.cancel()
                        scheduleHide()
                    }
                }
                .disabled(seekPending || duration <= 0)
                .opacity(0.02)
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .tint(.white)
                .controlSize(.small)
                .accessibilityIdentifier("player.progress")
                // SwiftUI Slider only seeks via thumb drag; tap the track to jump (UISlider-style).
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { event in
                        tapSeekProgress(atX: event.location.x, width: geo.size.width)
                    }
                )
                .overlay {
                    GeometryReader { geometry in
                        if isSeeking && !horizontalDrag {
                            let cardWidth = min(192.0, max(0, geometry.size.width - 16))
                            let fraction = min(1, max(0, seekValue / max(duration, 0.1)))
                            let half = cardWidth / 2 + 8
                            seekPreviewCard
                                .frame(width: cardWidth)
                                .position(x: min(max(half, geometry.size.width * fraction), geometry.size.width - half), y: -82)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 34)
            Text(formatTime(duration))
                .font(.system(size: 14, weight: .regular).monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                .lineLimit(1)
                .frame(minWidth: 44, alignment: .trailing)
                .fixedSize()
        }
    }

    /// Map a tap on the progress track to an absolute seek. Drag continues to use Slider editing.
    private func tapSeekProgress(atX x: CGFloat, width: CGFloat) {
        guard !seekPending, !horizontalDrag, duration.isFinite, duration > 0, width > 0 else { return }
        let fraction = min(1, max(0, Double(x / width)))
        let target = duration * fraction
        hideTask?.cancel()
        seekValue = target
        seek(to: target)
        currentTime = target
        isSeeking = false
        seekPreview.cancel()
        scheduleHide()
    }

    private func applyFillMode() {
        switch fillMode {
        case .fit: engine.applyFillMode(.fit)
        case .fill: engine.applyFillMode(.fill)
        case .stretch: engine.applyFillMode(.stretch)
        }
    }

    /// Build 59: engine callbacks replace KSVideoPlayer.Coordinator's
    /// onFinish/onStateChanged. The load generation is the identity guard
    /// (the old `playerLayer === layer` check): events from a replaced
    /// source carry an older generation and are ignored.
    private func wireEngine() {
        engine.onReady = { generation in
            guard playbackActive, generation == engine.loadGeneration else { return }
            hasStarted = true
            isBuffering = false
            if resumeHandledURL != url {
                resumeHandledURL = url
                applyResume()
            }
            audio.begin()
            engine.play()
            applyFillMode()
            applyPlaybackRate()
            syncEngineSubtitle()
            syncTime()
        }
        engine.onFailure = { generation in
            guard playbackActive, generation == engine.loadGeneration else { return }
            // Typed diagnostic only; engine free-text errors never reach UI state or logs.
            if playbackDiagnostic == nil {
                playbackDiagnostic = PlaybackDiagnostic(stage: .decode, category: .unknown,
                    host: PlaybackDiagnostic.resourceHost(url))
            }
            audio.end()
            if !failureReported {
                failureReported = true
                onPlaybackFailure?()
            }
        }
        engine.onEnded = { generation in
            guard playbackActive, generation == engine.loadGeneration else { return }
            engine.pause()
            audio.end()
            isPlaying = false
            flushHistory(force: true, position: max(currentTime, duration))
        }
    }

    /// Per-tick engine state fold-in (called from startTicker's loop).
    private func pollEngine() {
        engine.poll()
        isPlaying = engine.isPlaying
        isBuffering = engine.phase == .preparing || engine.phase == .buffering
        if engine.phase == .ready || engine.phase == .buffering { hasStarted = true }
    }

    /// Build 280: 番号+来源 position first, then the legacy per-item PlaybackProgressStore (115 / 糖心).
    /// Items watched beyond 95 % (or within the last 15 s) start from the beginning.
    private func applyResume() {
        var saved: (Double, Double)?
        if let resumeKey, let entry = PlaybackResumeStore.shared.entry(resumeKey, scope: resumeScope) {
            saved = (entry.position, entry.length)
        } else if let progressID, let legacy = PlaybackProgressStore.progress(for: progressID) {
            saved = (legacy.time, legacy.duration)
        }
        let engineDuration = engine.duration
        guard let saved,
              let start = PlaybackResumePolicy.startPosition(position: saved.0, length: saved.1 > 1 ? saved.1 : engineDuration,
                                                             fromBeginning: startFromBeginning) else { return }
        seekGeneration += 1
        let token = seekGeneration
        seekPending = true
        engine.seek(to: start, autoPlay: true) {
            Task { @MainActor in
                guard seekGeneration == token else { return }
                seekPending = false
            }
        }
        currentTime = start
        showResumeToast(start)
    }

    private func showResumeToast(_ position: TimeInterval) {
        resumeToastTask?.cancel()
        resumeToast = position
        resumeToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { resumeToast = nil }
        }
    }

    /// Toast 「从头」: seek to zero and remember it, so the next session also starts from the beginning.
    private func restartFromBeginning() {
        resumeToastTask?.cancel()
        withAnimation { resumeToast = nil }
        seek(to: 0)
        currentTime = 0
        if let resumeKey { PlaybackResumeStore.shared.save(resumeKey, position: 0, length: duration, scope: resumeScope, force: true) }
    }

    /// Only after this item's resume decision and real start; never overwrite a stored point with the 0 s of a loading item.
    private func saveResume(force: Bool, position: TimeInterval? = nil) {
        guard let resumeKey, resumeHandledURL == url, hasStarted, !seekPending else { return }
        let value = position ?? currentTime
        guard value.isFinite, value >= 1 || force else { return }
        PlaybackResumeStore.shared.save(resumeKey, position: value, length: duration, scope: resumeScope, force: force)
    }

    private func resumeToastView(_ position: TimeInterval, safeArea: EdgeInsets) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                Text(PlaybackResumePolicy.toast(position))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Button("从头") { restartFromBeginning() }
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 12).frame(minHeight: 36)
                    .background(.white.opacity(0.22), in: Capsule())
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player.resume.restart")
            }
            .foregroundStyle(.white)
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
            .background(.black.opacity(0.72), in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player.resume.toast")
            .padding(.bottom, safeArea.bottom + 128)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { @MainActor in
            let start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                pollEngine()
                syncTime()
                applyPlaybackRate()
                sampleThroughput()
                publishVideoMetrics(timedOut: Date().timeIntervalSince(start) > 30)
                if !hasStarted, !failureReported, Date().timeIntervalSince(start) > 30, onPlaybackFailure != nil {
                    failureReported = true
                    onPlaybackFailure?()
                }
            }
        }
    }


    /// Build 59: mpv's cache-speed (demuxer cache fill rate, bytes/s) is the
    /// throughput source now; there is no AVPlayerItem access log under
    /// libmpv. Zero / negative readings hide the label, as before.
    @MainActor
    private func sampleThroughput() {
        let speed = engine.cacheSpeed
        let value: Double? = speed > 0 ? Double(speed) : nil
        if downloadSpeed != value { downloadSpeed = value }
    }


    @MainActor
    private func publishVideoMetrics(timedOut: Bool) {
        guard onVideoMetrics != nil, playbackActive else { return }
        var value: PlaybackVideoMetrics?
        if let size = engine.videoSize {
            // mpv width/height are the current video track's dimensions
            // (track-level evidence, like the old FFmpeg-core path).
            value = PlaybackVideoMetrics(width: size.width, height: size.height, evidence: .track)
        }
        let settled = hasStarted || timedOut || failureReported
        guard value != lastVideoMetrics || settled != metricsSettled else { return }
        lastVideoMetrics = value
        metricsSettled = settled
        onVideoMetrics?(url, value, settled)
    }

    private func syncTime() {
        guard !isSeeking, !seekPending else { return }
        currentTime = engine.position
        let d = engine.duration
        if d.isFinite, d > 0 { duration = d }
        if let progressID {
            PlaybackProgressStore.save(movieID: progressID, time: currentTime, duration: duration)
        }
        saveResume(force: false)
        flushHistory(force: false)
    }

    /// 观看历史 resume point. Only after the start gate recorded this session; ticks write every ≥10 s,
    /// pause / end / exit / background force a write.
    private func flushHistory(force: Bool, position: TimeInterval? = nil) {
        if force { saveResume(force: true, position: position) }
    }

    private func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        seekGeneration += 1
        let token = seekGeneration
        seekPending = true
        // Seek auto-plays (the old KSOptions.isSeekedAutoPlay == true behaviour).
        audio.begin()
        engine.seek(to: time, autoPlay: true) {
            guard seekGeneration == token else { return }
            seekPending = false
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "00:00" }
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private func toggleChrome() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
        if showChrome { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { showChrome = false }
        }
    }
}


/// Route lifetime, not source-item or sheet visibility, owns orientation.
struct PlaybackOrientationHost: UIViewControllerRepresentable {
    final class Controller: UIViewController {
        var entered = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !entered else { return }
            entered = true
            OrientationLock.set(.landscapeRight, keepLocked: true)
        }
    }
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        if controller.entered { OrientationLock.set(.portrait, keepLocked: true) }
    }
}

@MainActor
enum OrientationLock {
    /// Build 59: replaces KSOptions.supportedInterfaceOrientations (the app
    /// delegate reads this). Defaults to .all until a player locks it.
    static var supportedMask: UIInterfaceOrientationMask = .all
    private static var generation = 0
    static func set(_ mask: UIInterfaceOrientationMask, keepLocked: Bool = false) {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return }
        generation += 1
        let token = generation
        let target: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad && mask == .portrait ? .all : mask
        OrientationLock.supportedMask = target
        request(target, token: token, attempt: 0)
    }
    private static func request(_ mask: UIInterfaceOrientationMask, token: Int, attempt: Int) {
        guard token == generation else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var host = root
        while let presented = host.presentedViewController, !presented.isBeingDismissed { host = presented }
        // Refresh the entire presentation chain: SwiftUI's presenting controller also votes.
        root.setNeedsUpdateOfSupportedInterfaceOrientations()
        host.setNeedsUpdateOfSupportedInterfaceOrientations()
        if let parent = host.parent { parent.setNeedsUpdateOfSupportedInterfaceOrientations() }
        if mask != .all, host.viewIfLoaded?.window != nil, !host.isBeingDismissed, !host.isBeingPresented {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
        // Presentation may still be animating on entry. Bounded retries are cancelled by exit.
        guard attempt < 5, !mask.contains(UIInterfaceOrientationMask(rawValue: 1 << scene.interfaceOrientation.rawValue)) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            request(mask, token: token, attempt: attempt + 1)
        }
    }
}

/// Best-effort public UIKit adapter, not an Apple-guaranteed system-volume API.
/// Keep the real MPVolumeView nonhidden, alpha 1, in this player's live scene.
private final class PlayerVolumeView: MPVolumeView {
    init() {
        super.init(frame: CGRect(x: -120, y: 0, width: 100, height: 44))
        showsRouteButton = false
        showsVolumeSlider = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout(); layoutIfNeeded()
    }
    private func slider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        return view.subviews.lazy.compactMap { self.slider(in: $0) }.first
    }
    func submit(_ value: CGFloat) -> Bool {
        guard window != nil, !isHidden, alpha == 1 else { return false }
        setNeedsLayout(); layoutIfNeeded()
        guard let slider = slider(in: self), slider.window === window, slider.isEnabled else { return false }
        slider.setValue(Float(min(1, max(0, value))), animated: false)
        slider.sendActions(for: .valueChanged)
        return true // submitted request, not an independent hardware measurement
    }
}

struct PlayerGestureLayer: UIViewRepresentable {
    final class GestureView: UIView {
        fileprivate let volume = PlayerVolumeView()
        var cancelPan: (() -> Void)?
        var excludedTop: CGFloat = 80
        var excludedBottom: CGFloat = 116
        var blocked = false
        private var previousBounds = CGRect.zero
        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(volume) // mounted before the first touch; same UIWindowScene as player
            NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged), name: UIApplication.willResignActiveNotification, object: nil)
        }
        @objc private func environmentChanged() { cancelPan?() }
        deinit { NotificationCenter.default.removeObserver(self) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            if previousBounds != .zero, previousBounds != bounds { cancelPan?() }
            previousBounds = bounds
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { cancelPan?() }
        }
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard bounds.contains(point) else { return false }
            return !blocked && point.y >= excludedTop && point.y <= bounds.height - excludedBottom
        }
    }
    var excludedTop: CGFloat
    var excludedBottom: CGFloat
    var blocked: Bool
    var sourceID: URL
    var onDoubleTap: (CGFloat, CGFloat) -> Void
    var onSingleTap: () -> Void
    var onAdjustment: (AVDBAdjustmentPan.Side, CGFloat?, String?) -> Void
    var onSeekChanged: (CGFloat) -> Void
    var onEnded: (Bool) -> Void

    func makeUIView(context: Context) -> GestureView {
        let view = GestureView()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        context.coordinator.recognizer = pan
        view.cancelPan = { [weak coordinator = context.coordinator] in coordinator?.cancel() }
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap(_:)))
        singleTap.require(toFail: doubleTap)
        singleTap.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(singleTap)
        return view
    }
    func updateUIView(_ uiView: GestureView, context: Context) {
        let c = context.coordinator
        if sourceID != c.parent.sourceID || (blocked && !c.parent.blocked) { c.cancel() }
        c.parent = self
        uiView.excludedTop = excludedTop
        uiView.excludedBottom = excludedBottom
        uiView.blocked = blocked
    }
    static func dismantleUIView(_ uiView: GestureView, coordinator: Coordinator) {
        coordinator.cancel()
        uiView.cancelPan = nil
    }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerGestureLayer
        weak var recognizer: UIPanGestureRecognizer?
        var state = AVDBAdjustmentPan()
        var dragStart = CGPoint.zero
        init(parent: PlayerGestureLayer) { self.parent = parent }
        func cancel() {
            let active = state.active
            state.end()
            if active { parent.onEnded(true) }
            if let recognizer, recognizer.state == .began || recognizer.state == .changed {
                recognizer.isEnabled = false; recognizer.isEnabled = true
            }
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            !parent.blocked && gestureRecognizer.view?.window != nil
            // Do not test velocity/displacement here: UIKit does not retry a slow start.
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard !parent.blocked, let view = gestureRecognizer.view else { return false }
            var target = touch.view
            while let node = target {
                if node is UIControl { return false }
                if node === view { break }
                target = node.superview
            }
            let point = touch.location(in: view)
            guard point.y >= parent.excludedTop, point.y <= view.bounds.height - parent.excludedBottom else { return false }
            if gestureRecognizer === recognizer { dragStart = point } // original touchdown half
            return true
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? GestureView else { return }
            if gesture.state == .cancelled || gesture.state == .failed { cancel(); return }
            if gesture.state == .began {
                guard !parent.blocked else { cancel(); return }
                state.begin(origin: dragStart, size: view.bounds.size)
            }
            guard state.active else { return }
            guard !parent.blocked, state.size == view.bounds.size else { cancel(); return }
            let point = gesture.translation(in: view)
            if state.axis == nil {
                let initial = state.side == .brightness ? (view.window?.screen.brightness ?? UIScreen.main.brightness) : CGFloat(AVAudioSession.sharedInstance().outputVolume)
                _ = state.lock(translation: point, initial: initial)
            }
            if state.axis == .vertical {
                // Horizontal seek remains available in portrait; adjustments are landscape-only.
                guard view.bounds.width > view.bounds.height else { cancel(); return }
                if let value = state.update(translation: point, size: view.bounds.size) {
                    if state.side == .brightness {
                        guard let screen = view.window?.screen else { cancel(); return }
                        screen.brightness = value
                        parent.onAdjustment(.brightness, value, nil)
                    } else if view.volume.submit(value) {
                        parent.onAdjustment(.volume, value, nil)
                    } else {
                        parent.onAdjustment(.volume, nil, "当前音频路由无法调节音量，请使用硬件音量键")
                    }
                }
            } else if let dx = state.horizontal(translation: point, size: view.bounds.size) {
                parent.onSeekChanged(dx)
            }
            if gesture.state == .ended {
                state.end()
                parent.onEnded(false)
            }
        }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard !parent.blocked, let view = gesture.view else { return }
            let point = gesture.location(in: view)
            parent.onDoubleTap(point.x, view.bounds.width)
        }
        @objc func singleTap(_ gesture: UITapGestureRecognizer) { parent.onSingleTap() }
    }
}

