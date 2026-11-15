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
    @State private var activeMagnet: MagnetItem?
    @State private var toast: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CoverImage(url: model.detail?.coverURL ?? card.coverURL)
                    .aspectRatio(3/2, contentMode: .fill)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.detail?.displayCode ?? card.displayCode)
                        .font(.title2.bold())
                    Text(model.detail?.displayTitle ?? card.displayTitle)
                        .font(.body)
                    if let rating = model.detail?.rating {
                        let count = model.detail?.ratingCount.map { " · \($0)人评分" } ?? ""
                        Text(String(format: "%.1f 分%@", rating, count))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                FetchStatusBanner(source: model.source, error: model.errorMessage, webURL: model.pageURL) {
                    showWeb = true
                }

                if model.loading && model.detail == nil {
                    ProgressView("正在加载详情…")
                        .frame(maxWidth: .infinity)
                }

                if let detail = model.detail {
                    infoBlock("发行日期", detail.releaseDate)
                    infoBlock("片长", detail.duration)
                    linkBlock("制作商", detail.makers)
                    linkBlock("发行商", detail.publishers)
                    linkBlock("导演", detail.directors)
                    linkBlock("系列", detail.series)
                    linkBlock("演员", detail.casts)
                    linkBlock("标签", detail.tags)

                    if let summary = detail.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    magnetsSection(detail)
                }
            }
            .padding()
        }
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
        .task { await model.load(card: card, settings: settings) }
        .sheet(isPresented: $showWeb) {
            if let url = model.pageURL { InAppWebView(url: url, title: card.displayCode) }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let detail = model.detail, let magnet = activeMagnet {
                Pan115PlayerView(detail: detail, magnetURL: magnet.url)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding()
            }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("磁力列表")
                    .font(.headline)
                Text("\(detail.magnets.count)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
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
        .padding(.top, 8)
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
        VStack(alignment: .leading, spacing: 8) {
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
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
            HStack {
                Button("推送并播放", action: onPushPlay)
                    .buttonStyle(.borderedProminent)
                    .disabled(!configured)
                Button("仅推送", action: onPushOnly)
                    .buttonStyle(.bordered)
                    .disabled(!configured)
                ShareLink(item: magnet.url) {
                    Text("分享")
                }
                Button("复制", action: onCopy)
            }
            .font(.caption)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
