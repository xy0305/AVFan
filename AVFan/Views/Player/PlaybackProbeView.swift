import SwiftUI

/// Playback probe panel (Build 59 diagnostic round): a live,
/// screenshottable readout of the frame path — decoder state and
/// stream colour metadata from the player, frame counters and
/// colour tagging from the frame store / scheduler / display
/// layer, and the post chain's live settings.  Every row is read
/// off the object that owns the value on the real path; the panel
/// exists so a black/crushed picture can be pinned to one stage
/// from a single screenshot instead of another round of guessing.
///
/// Reached from the player chrome's 画面与方向 menu while playing.
struct PlaybackProbeView: View {
    @ObservedObject var engine: MPlayChromeCoordinator
    @State private var probe: MPlayPlaybackProbe?
    @State private var mpvRows: [(String, String)] = []
    @State private var seekRows: [(String, String)] = []

    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section("解码（播放器）") {
                    ForEach(mpvRows, id: \.0) { row in
                        probeRow(row.0, row.1)
                    }
                }
                Section("帧流（vo → 显示层）") {
                    probeRow("vo 收帧（视频）", probe.map { "\($0.storeVideoFrames)" } ?? "—")
                    probeRow("已 enqueue", probe.map { "\($0.enqueuedFrames)" } ?? "—")
                    probeRow("未就绪丢弃", probe.map { "\($0.notReadyDrops)" } ?? "—")
                    probeRow("格式描述失败", probe.map { "\($0.formatFailures)" } ?? "—")
                    probeRow("样本创建失败", probe.map { "\($0.sampleFailures)" } ?? "—")
                    probeRow("最近帧", probe.map {
                        "\($0.lastFrameFormat) \($0.lastFrameWidth)×\($0.lastFrameHeight)"
                    } ?? "—")
                    probeRow("最近帧 PTS", probe.map { Self.seconds($0.lastFramePTS) } ?? "—")
                    probeRow("最近帧 ID", probe.map { "\($0.lastFrameID)" } ?? "—")
                }
                Section("色彩 · 帧缓冲附件") {
                    probeRow("primaries", probe?.bufferPrimaries ?? "—")
                    probeRow("transfer", probe?.bufferTransfer ?? "—")
                    probeRow("matrix", probe?.bufferMatrix ?? "—")
                }
                Section("色彩 · 格式描述") {
                    probeRow("primaries", probe?.formatPrimaries ?? "—")
                    probeRow("transfer", probe?.formatTransfer ?? "—")
                    probeRow("matrix", probe?.formatMatrix ?? "—")
                }
                Section("Seek") {
                    probeRow("最近 seek 目标", probe?.seekTarget.map(Self.seconds) ?? "—")
                    probeRow("seek 后收帧", probe.map { "\($0.framesSinceSeek)" } ?? "—")
                    ForEach(seekRows, id: \.0) { row in
                        probeRow(row.0, row.1)
                    }
                }
                Section("显示层") {
                    probeRow("status", probe?.layerStatus ?? "—")
                    probeRow("error", probe?.layerError ?? "无")
                    probeRow("timebase 时间", probe?.timebaseTime.map(Self.seconds) ?? "—")
                    probeRow("timebase 速率", probe?.timebaseRate.map { Self.seconds($0) } ?? "—")
                }
                Section("后链（实时状态）") {
                    probeRow("启用", probe.map { $0.chainEnabled ? "是" : "否" } ?? "—")
                    probeRow("SDR→HDR 级别", probe.map { "\($0.chainSDRToHDR)" } ?? "—")
                    probeRow("超分级别", probe.map { "\($0.chainUpscaling)" } ?? "—")
                    probeRow("插帧", probe.map { $0.chainInterpolation ? "开" : "关" } ?? "—")
                    probeRow("DV profile", probe.map { "\($0.chainDolbyProfile)" } ?? "—")
                    probeRow("已处理帧", probe.map { "\($0.chainProcessed)" } ?? "—")
                    probeRow("忙丢弃", probe.map { "\($0.chainDroppedBusy)" } ?? "—")
                }
            }
            .navigationTitle("播放探针")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { refresh() }
        .onReceive(timer) { _ in refresh() }
    }

    private func probeRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private static func seconds(_ value: Double) -> String {
        value.isFinite ? String(format: "%.3f", value) : "—"
    }

    private func refresh() {
        probe = engine.frameProbeView?.probeSnapshot()
        guard let player = engine.player else {
            mpvRows = [("hwdec-current", "无播放器")]
            seekRows = []
            return
        }
        let seek = player.seekProbe()
        seekRows = [
            ("待完成 seek", "\(seek.pending)"),
            ("restart 次数", "\(seek.restarts)"),
            ("core time-pos", seek.timePos.map(Self.seconds) ?? "—"),
            ("paused-for-cache", seek.pausedForCache ? "是" : "否"),
            ("demuxer-cache-duration", Self.seconds(seek.cacheDuration)),
        ]
        func prop(_ name: String) -> String {
            player.stringProperty(name) ?? "—"
        }
        mpvRows = [
            ("hwdec-current", prop("hwdec-current")),
            ("current-vo", prop("current-vo")),
            ("video-codec", prop("video-codec")),
            ("params/pixelformat", prop("video-params/pixelformat")),
            ("params/primaries", prop("video-params/primaries")),
            ("params/gamma", prop("video-params/gamma")),
            ("params/colormatrix", prop("video-params/colormatrix")),
            ("params/colorlevels", prop("video-params/colorlevels")),
            ("time-pos", player.doubleProperty("time-pos").map(Self.seconds) ?? "—"),
        ]
    }
}
