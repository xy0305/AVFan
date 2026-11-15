import AVKit
import SwiftUI

struct Pan115PlayerView: View {
    let detail: MovieDetail
    var magnetURL: String?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = Pan115PlayerViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = model.playURL, model.errorMessage == nil, !model.isLoading {
                VideoPlayer(player: model.player ?? AVPlayer(url: url))
                    .ignoresSafeArea()
                    .onAppear { model.player?.play() }
            } else if let error = model.errorMessage {
                VStack(spacing: 16) {
                    Text("无法播放")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("重试") {
                        Task { await model.start(detail: detail, magnetURL: magnetURL) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("关闭") { dismiss() }
                        .foregroundStyle(.white)
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView().tint(.white)
                    Text(model.status)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("取消") { dismiss() }
                        .foregroundStyle(.white)
                }
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .padding(10)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .foregroundStyle(.white)
                    Spacer()
                    if !model.streams.isEmpty {
                        Menu {
                            ForEach(Array(model.streams.enumerated()), id: \.offset) { _, stream in
                                Button(stream.name) {
                                    Task { await model.select(stream) }
                                }
                            }
                        } label: {
                            Text(model.qualityLabel.isEmpty ? "清晰度" : model.qualityLabel)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.45), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding()
                Spacer()
                Text(detail.displayCode)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.bottom, 18)
            }
        }
        .task { await model.start(detail: detail, magnetURL: magnetURL) }
        .onDisappear { model.player?.pause() }
    }
}

@MainActor
final class Pan115PlayerViewModel: ObservableObject {
    @Published var status = "正在连接 115…"
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var playURL: URL?
    @Published var streams: [Pan115Client.PlayStream] = []
    @Published var qualityLabel = ""
    var headers: [String: String] = [:]
    var player: AVPlayer?

    func start(detail: MovieDetail, magnetURL: String?) async {
        isLoading = true
        errorMessage = nil
        playURL = nil
        player = nil
        let settings = Pan115Settings.shared
        guard settings.isConfigured else {
            fail("请先在设置中配置 115 Cookie 和离线目录 CID")
            return
        }
        let magnet = magnetURL ?? Pan115PlaybackCache.magnet(for: detail.pathID)
        guard let magnet else {
            fail("没有可推送的磁力链接")
            return
        }
        Pan115PlaybackCache.save(movieID: detail.pathID, magnet: magnet)
        status = "正在推送到 115…"
        do {
            let result = try await Pan115Client.shared.addOfflineTask(
                url: magnet,
                cookie: settings.cookie,
                folderCID: settings.folderCID
            )
            status = result.message + "，等待转存完成…"
            let task = try await Pan115Client.shared.waitOfflineReady(
                keyword: detail.displayCode,
                cookie: settings.cookie
            )
            status = "正在匹配网盘文件…"
            let cid = task.dirID.isEmpty ? settings.folderCID : task.dirID
            let file = try await Pan115Client.shared.findMatchedVideo(
                keyword: detail.displayCode,
                cookie: settings.cookie,
                folderCID: cid,
                requireMatch: true
            )
            status = "正在获取播放地址…"
            let list = try await Pan115Client.shared.streamsForVideo(
                pickCode: file.pickCode,
                cookie: settings.cookie,
                filename: file.name
            )
            streams = list
            if let first = list.first, let url = URL(string: first.url) {
                activate(url: url, cookie: settings.cookie, label: first.name)
            } else {
                let url = try await Pan115Client.shared.originalPlayURL(
                    pickCode: file.pickCode,
                    cookie: settings.cookie,
                    filename: file.name
                )
                activate(url: url, cookie: settings.cookie, label: "原画")
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    func select(_ stream: Pan115Client.PlayStream) async {
        guard let url = URL(string: stream.url) else {
            fail("播放地址无效")
            return
        }
        activate(url: url, cookie: Pan115Settings.shared.cookie, label: stream.name)
    }

    private func activate(url: URL, cookie: String, label: String) {
        headers = Pan115Client.playHeaders(cookie: cookie)
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player
        playURL = url
        qualityLabel = label
        isLoading = false
        errorMessage = nil
        player.play()
    }

    private func fail(_ message: String) {
        errorMessage = message
        isLoading = false
    }
}

enum Pan115PlaybackCache {
    private static func key(_ movieID: String) -> String { "avfan.115.lastMagnet.\(movieID)" }

    static func save(movieID: String, magnet: String) {
        UserDefaults.standard.set(magnet, forKey: key(movieID))
    }

    static func magnet(for movieID: String) -> String? {
        UserDefaults.standard.string(forKey: key(movieID))
    }
}
