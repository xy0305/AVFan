import SwiftUI
import UIKit

struct MovieDetailView: View {
    let card: MovieCard
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var pan115: Pan115Settings
    @StateObject private var model = MovieDetailViewModel()
    @State private var showWeb = false
    @State private var showPlayer = false
    @State private var showWatchPlayer = false
    @State private var activeMagnet: MagnetItem?
    @State private var activeWatch: WatchStream?
    @State private var startFromBeginning = false
    @State private var toast: String?
    @State private var resume115: PlaybackResumeEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CoverImage(url: model.detail?.coverURL ?? card.coverURL)
                    .aspectRatio(3/2, contentMode: .fill)
                    .clipped()
                    .liquidCover(cornerRadius: AVFanTheme.heroRadius)
                    .shadow(color: .black.opacity(0.14), radius: 16, y: 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.detail?.displayCode ?? card.displayCode)
                        .font(AVFanTheme.titleFont)
                    Text(model.detail?.displayTitle ?? card.displayTitle)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if let rating = model.detail?.rating {
                        let count = model.detail?.ratingCount.map { " · \($0)人评分" } ?? ""
                        Text(String(format: "%.1f 分%@", rating, count))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AVFanTheme.accent)
                    }
                }

                playPills

                FetchStatusBanner(source: model.source, error: model.errorMessage, webURL: model.pageURL) {
                    showWeb = true
                }

                if model.loading && model.detail == nil {
                    ProgressView("正在加载详情…")
                        .frame(maxWidth: .infinity)
                }

                if let detail = model.detail {
                    VStack(alignment: .leading, spacing: 8) {
                        infoBlock("发行日期", detail.releaseDate)
                        infoBlock("片长", detail.duration)
                        linkBlock("制作商", detail.makers)
                        linkBlock("发行商", detail.publishers)
                        linkBlock("导演", detail.directors)
                        linkBlock("系列", detail.series)
                        linkBlock("演员", detail.casts)
                        linkBlock("标签", detail.tags)
                    }
                    .padding(14)
                    .liquidGlassRect(cornerRadius: 18)

                    if let summary = detail.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .liquidGlassRect(cornerRadius: 16)
                    }

                    magnetsSection(detail)
                }
            }
            .padding(.horizontal, AdaptiveLayout.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(AVFanTheme.pageBackground)
        .navigationTitle(model.detail?.displayCode ?? card.displayCode)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    if let detail = model.detail {
                        bookmarks.toggle(detail)
                    }
                } label: {
                    Image(systemName: bookmarks.contains(model.detail?.pathID ?? card.pathID) ? "bookmark.fill" : "bookmark")
                }
                .disabled(model.detail == nil)
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .task {
            await model.load(card: card, settings: settings)
            refreshResume()
        }
        .sheet(isPresented: $showWeb) {
            if let url = model.pageURL { InAppWebView(url: url, title: card.displayCode) }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let detail = model.detail {
                Pan115PlayerView(
                    detail: detail,
                    magnetURL: activeMagnet?.url,
                    magnets: detail.magnets,
                    startFromBeginning: startFromBeginning
                )
            }
        }
        .fullScreenCover(isPresented: $showWatchPlayer) {
            if let stream = activeWatch, let url = URL(string: stream.url) {
                WatchOnlinePlayerView(
                    title: model.detail?.displayCode ?? card.displayCode,
                    url: url,
                    resumeKey: PlaybackResumeKey.make(number: model.detail?.displayCode ?? card.displayCode, source: "avfan"),
                    startFromBeginning: startFromBeginning
                )
            }
        }
        .onChange(of: showPlayer) { _, open in if !open { refreshResume() } }
        .onChange(of: showWatchPlayer) { _, open in if !open { refreshResume() } }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .liquidGlass()
                    .padding()
            }
        }
    }

    @ViewBuilder
    private var playPills: some View {
        let watch = model.detail?.watchStreams ?? []
        let resumeTitle = PlaybackResumePolicy.compactTitle(position: resume115?.position, length: resume115?.length)
        if !watch.isEmpty || resumeTitle != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let first = watch.first {
                    Button {
                        startFromBeginning = true
                        activeWatch = first
                        showWatchPlayer = true
                    } label: {
                        Label(first.label, systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .glassChromeButton(prominent: true)
                    if watch.count > 1 {
                        Menu("其他在线线路") {
                            ForEach(watch.dropFirst()) { stream in
                                Button(stream.label) {
                                    startFromBeginning = true
                                    activeWatch = stream
                                    showWatchPlayer = true
                                }
                            }
                        }
                    }
                    Text("来自当前公开页面的媒体地址。若无法播放，可改用应用内网页。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let resumeTitle {
                    Button {
                        startFromBeginning = false
                        if (model.detail?.watchStreams.isEmpty ?? true) || pan115.isConfigured {
                            showPlayer = true
                        } else if let first = model.detail?.watchStreams.first {
                            activeWatch = first
                            showWatchPlayer = true
                        }
                    } label: {
                        Label(resumeTitle + " · 115", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .glassChromeButton()
                }
            }
        }
    }

    private func refreshResume() {
        let code = model.detail?.displayCode ?? card.displayCode
        if let key = PlaybackResumeKey.make(number: code, source: "115") {
            resume115 = PlaybackResumeStore.shared.entry(key, scope: "avfan")
        }
    }

    private var shareText: String {
        let detail = model.detail
        let code = detail?.displayCode ?? card.displayCode
        let title = detail?.displayTitle ?? card.displayTitle
        let url = detail?.pageURL ?? HTMLParser.absoluteURL(card.href)
        return "\(code) \(title)\n\(url)"
    }

    @ViewBuilder
    private func infoBlock(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                Text(value)
                Spacer()
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private func linkBlock(_ label: String, _ links: [NamedLink]) -> some View {
        if !links.isEmpty {
            HStack(alignment: .top) {
                Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                Text(links.map(\.name).joined(separator: "、"))
                Spacer()
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private func magnetsSection(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("磁力列表")
                    .font(AVFanTheme.sectionFont)
                Text("\(detail.magnets.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .liquidGlass()
            }
            if detail.magnets.isEmpty {
                Text("这个页面没有解析到磁力链接。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(detail.magnets) { magnet in
                MagnetRow(
                    magnet: magnet,
                    configured: pan115.isConfigured,
                    onPushPlay: {
                        activeMagnet = magnet
                        startFromBeginning = false
                        if pan115.isConfigured {
                            showPlayer = true
                        } else {
                            toast = "请先在设置里填写 115 Cookie 和目录 CID"
                            hideToastLater()
                        }
                    },
                    onPushOnly: {
                        Task { await pushOnly(magnet, keyword: detail.displayCode) }
                    },
                    onCopy: {
                        UIPasteboard.general.string = magnet.url
                        toast = "已复制磁力链接"
                        hideToastLater()
                    }
                )
            }
        }
        .padding(.top, 4)
    }

    private func pushOnly(_ magnet: MagnetItem, keyword: String) async {
        guard pan115.isConfigured else {
            toast = "请先在设置里填写 115 Cookie 和目录 CID"
            hideToastLater()
            return
        }
        do {
            let result = try await Pan115Client.shared.addOfflineTask(
                url: magnet.url,
                cookie: pan115.cookie,
                folderCID: pan115.folderCID
            )
            toast = result.message
        } catch {
            toast = error.localizedDescription
        }
        hideToastLater()
    }

    private func hideToastLater() {
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            toast = nil
        }
    }
}

struct MagnetRow: View {
    let magnet: MagnetItem
    let configured: Bool
    var onPushPlay: () -> Void
    var onPushOnly: () -> Void
    var onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(magnet.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 8) {
                if !magnet.displayMeta.isEmpty {
                    Text(magnet.displayMeta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(magnet.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AVFanTheme.accent.opacity(0.14), in: Capsule())
                        .foregroundStyle(AVFanTheme.accent)
                }
            }
            HStack(spacing: 8) {
                Button("推送并播放", action: onPushPlay)
                    .glassChromeButton(prominent: true)
                    .disabled(!configured)
                Button("仅推送", action: onPushOnly)
                    .glassChromeButton()
                    .disabled(!configured)
                ShareLink(item: magnet.url) {
                    Text("分享")
                }
                Button("复制", action: onCopy)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(14)
        .liquidGlassRect(cornerRadius: 16)
        .contextMenu {
            Button("复制磁力", action: onCopy)
            Button("推送到 115", action: onPushOnly)
        }
    }
}

@MainActor
final class MovieDetailViewModel: ObservableObject {
    @Published var detail: MovieDetail?
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var source: FetchSource?
    var pageURL: URL?

    func load(card: MovieCard, settings: AppSettings) async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        let url = SiteClient.shared.movieURL(pathID: card.pathID, locale: settings.locale, href: card.href)
        pageURL = url
        do {
            let result = try await SiteClient.shared.html(
                for: url,
                locale: settings.locale,
                ageCookie: settings.legalAgeCookie,
                allowWebViewFallback: true,
                expectCatalog: true
            )
            var parsed = HTMLParser.movieDetail(from: result.html, url: url)
            if parsed.pathID.isEmpty { parsed.pathID = card.pathID }
            if parsed.code == nil { parsed.code = card.code }
            if parsed.title.isEmpty { parsed.title = card.title }
            if parsed.coverURL == nil { parsed.coverURL = card.coverURL }
            if parsed.pageURL.isEmpty { parsed.pageURL = url.absoluteString }
            detail = parsed
            source = result.source
        } catch {
            errorMessage = error.localizedDescription
            detail = MovieDetail(
                pathID: card.pathID,
                pageURL: url.absoluteString,
                code: card.code,
                title: card.title,
                coverURL: card.coverURL,
                summary: nil,
                releaseDate: card.date,
                duration: nil,
                rating: nil,
                ratingCount: nil,
                makers: [],
                publishers: [],
                directors: [],
                series: [],
                casts: [],
                tags: [],
                magnets: []
            )
        }
    }
}
