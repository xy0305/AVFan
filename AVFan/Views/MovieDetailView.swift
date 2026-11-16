import SwiftUI
import UIKit

struct MovieDetailView: View {
    let card: MovieCard
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var pan115: Pan115Settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.availableLayoutSize) private var layoutSize
    @StateObject private var model = MovieDetailViewModel()
    @ScaledMetric(relativeTo: .largeTitle) private var portraitTitleSize: CGFloat = 34
    @State private var showWeb = false
    @State private var showPlayer = false
    @State private var showWatchPlayer = false
    @State private var showMagnetList = false
    @State private var activeMagnet: MagnetItem?
    @State private var activeWatch: WatchStream?
    @State private var startFromBeginning = false
    @State private var toast: String?
    @State private var resume115: PlaybackResumeEntry?
    @State private var resumeOnline: PlaybackResumeEntry?
    @State private var sourceOverride: PlaySource?
    /// Measured height of the hero's text stack (title block + controls).
    /// A long title with its expand button outgrows the slot the geometry
    /// planned, pushing the play row past the artwork and the gradient —
    /// the pills' lower halves landed on the light sheet and looked cut.
    /// The gradient now stretches to the measured content height.
    @State private var heroContentHeight: CGFloat = 0

    private enum PlaySource { case online, pan115 }

    /// Default playback source: 115 (owner's call, build 5 — this reverses
    /// build 4's online-first default). Online stays one tap away via the
    /// source chips whenever the page offered a stream, and play115() still
    /// falls back to a stream when 115 is not configured. The play pill, the
    /// chips and the resource-card order all follow this value.
    private var effectiveSource: PlaySource {
        if let sourceOverride { return sourceOverride }
        return .pan115
    }

    private var activeResume: PlaybackResumeEntry? {
        effectiveSource == .online ? resumeOnline : resume115
    }

    private var display: MovieDetail {
        model.detail ?? MovieDetail(
            pathID: card.pathID,
            pageURL: HTMLParser.absoluteURL(card.href),
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
            magnets: [],
            watchStreams: []
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                detailContent(display, width: proxy.size.width, height: proxy.size.height)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(.container, edges: .top)
            .background(AVFanTheme.pageBackground)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await model.load(card: card, settings: settings)
            refreshResume()
        }
        .sheet(isPresented: $showWeb) {
            if let url = model.pageURL { InAppWebView(url: url, title: card.displayCode) }
        }
        .sheet(isPresented: $showMagnetList) {
            NavigationStack {
                ScrollView { magnetsSection(display).padding(16) }
                    .background(AVFanTheme.pageBackground)
                    .navigationTitle("磁力列表")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { showMagnetList = false } } }
            }
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
        .overlay(alignment: .topLeading) { detailChrome }
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

    private var detailChrome: some View {
        HStack {
            chromeButton("chevron.left") { dismiss() }
            Spacer()
            chromeButton(bookmarks.contains(display.pathID) ? "bookmark.fill" : "bookmark") {
                if let detail = model.detail { bookmarks.toggle(detail) }
            }
            ShareLink(item: shareText) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .background(.black.opacity(0.30), in: Circle())
                    .liquidGlassCircle(interactive: false)
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    // Mirrors AVDB's working detail chrome button: 44 pt hit target, explicit
    // content shape, and NON-interactive glass. The interactive glass effect
    // installs its own press handling inside the label and can swallow the
    // button's tap on iOS 26/27 — with interactive: true the back button
    // rendered fine but never fired.
    private func chromeButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            GlassHaptic.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .background(.black.opacity(0.30), in: Circle())
                .liquidGlassCircle(interactive: false)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }

    private func detailContent(_ detail: MovieDetail, width: CGFloat, height: CGFloat) -> some View {
        let geometry = DetailPortraitGeometry(availableSize: CGSize(width: width, height: height),
                                              isPad: AdaptiveLayout.isPad)
        return VStack(spacing: 0) {
            portraitHero(detail, geometry: geometry)
            LazyVStack(alignment: .leading, spacing: 20) {
                FetchStatusBanner(source: model.source, error: model.errorMessage, webURL: model.pageURL) {
                    showWeb = true
                }
                if model.loading && model.detail == nil {
                    ProgressView("正在加载详情…").frame(maxWidth: .infinity)
                }
                resourceCards(detail)
                movieInfoCard(detail)
                if !detail.tags.isEmpty { tagsSection(detail.tags) }
                if !detail.casts.isEmpty { linkSection("演员", detail.casts) }
                if let summary = detail.summary, !summary.isEmpty { summarySection(summary) }
                magnetsSection(detail)
            }
            .padding(.top, 26)
            .padding(.bottom, 40)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
        }
        .frame(maxWidth: AdaptiveLayout.isPad ? 900 : AdaptiveLayout.contentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private func portraitHero(_ detail: MovieDetail, geometry: DetailPortraitGeometry) -> some View {
        let width = geometry.width
        let imageHeight = geometry.imageHeight
        let titleTop = geometry.titleTop
        return ZStack(alignment: .top) {
            CoverImage(url: detail.coverURL ?? card.coverURL, code: detail.code ?? card.code, anchorY: 0.18, allowUpscale: true)
                .frame(width: width, height: imageHeight, alignment: .top)
                .clipped()
                .accessibilityHidden(true)
                .accessibilityIdentifier("detail-hero-artwork")
            LinearGradient(stops: [
                .init(color: .clear, location: 0.36),
                .init(color: Color.black.opacity(0.24), location: 0.57),
                .init(color: Color.black.opacity(0.78), location: 0.86),
                .init(color: Color.black.opacity(0.92), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: max(imageHeight + 30, heroContentHeight))
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    DetailReadableTitle(
                        title: detail.displayTitle,
                        identifier: "portrait-hero-title",
                        font: .system(size: portraitTitleSize * (AdaptiveLayout.isPad ? 1.24 : 1), weight: .bold),
                        collapsedLines: 2
                    )
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 8)
                    .padding(.horizontal, 32)
                    portraitMetadata(detail)
                        .padding(.horizontal, 18).padding(.top, 16)
                }
                .frame(minHeight: max(0, geometry.controlsTop - titleTop - 18), alignment: .bottom)
                portraitControls(detail)
                    .padding(.horizontal, 18).padding(.top, 18)
            }
            .padding(.top, titleTop)
            .padding(.bottom, 16)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                heroContentHeight = newHeight
            }
            .foregroundStyle(.white)
        }
        .frame(width: width)
        .frame(maxWidth: .infinity)
    }

    private func portraitMetadata(_ detail: MovieDetail) -> some View {
        let values = [detail.displayCode, detail.releaseDate, detail.duration].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return Text(values.joined(separator: " · "))
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("portrait-hero-metadata")
    }

    private func portraitControls(_ detail: MovieDetail) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                portraitPlayButton
                portraitActionGroup
            }
            VStack(spacing: 12) {
                portraitPlayButton.frame(maxWidth: .infinity)
                portraitActionGroup.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var playProgress: Double? {
        if let resume = activeResume, let length = optionalLength(resume), length > 0 {
            return min(max(resume.position / length, 0), 1)
        }
        return nil
    }

    private func optionalLength(_ entry: PlaybackResumeEntry) -> Double? {
        entry.length > 0 ? entry.length : nil
    }

    private var portraitPlayButton: some View {
        let compact = PlaybackResumePolicy.compactTitle(position: activeResume?.position,
                                                        length: activeResume?.length)
        return Button {
            GlassHaptic.tap()
            playPrimary()
        } label: {
            DetailPlayPill(title: compact ?? "播放", progress: playProgress)
        }
        .buttonStyle(.plain)
        .contextMenu { playMenu }
        .accessibilityLabel(compact ?? "播放")
        .accessibilityIdentifier("portrait-hero-play")
    }

    @ViewBuilder
    private var playMenu: some View {
        if PlaybackResumePolicy.compactTitle(position: resume115?.position, length: resume115?.length) != nil {
            Button {
                startFromBeginning = false
                showPlayer = true
            } label: { Label("续播 115", systemImage: "clock.arrow.circlepath") }
            Button {
                startFromBeginning = true
                showPlayer = true
            } label: { Label("从头播放 115", systemImage: "backward.end") }
        }
        if let first = display.watchStreams.first {
            Button {
                startFromBeginning = true
                activeWatch = first
                showWatchPlayer = true
            } label: { Label(first.label, systemImage: "play.rectangle") }
        }
        Button {
            startFromBeginning = false
            showPlayer = true
        } label: { Label("播放 115 原画", systemImage: "play.fill") }
    }

    private var portraitActionGroup: some View {
        HStack(spacing: 0) {
            posterAction("link", label: "磁力列表") { showMagnetList = true }
            posterAction(bookmarks.contains(display.pathID) ? "bookmark.fill" : "bookmark", label: "收藏") {
                if let detail = model.detail { bookmarks.toggle(detail) }
            }
            posterAction("safari", label: "网页") { showWeb = true }
            ShareLink(item: shareText) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 23, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("分享")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.clear, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.72), lineWidth: 1.5).allowsHitTesting(false))
        .accessibilityIdentifier("portrait-hero-actions")
    }

    private func posterAction(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            GlassHaptic.tap()
            action()
        } label: {
            Image(systemName: icon).font(.system(size: 23, weight: .regular))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // Lives in the light content sheet below the hero (it used to sit inside
    // the hero's white-text stack while extending past the artwork, which
    // rendered white-on-white and broke the layout).
    private func resourceCards(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("播放资源").font(.headline)
                Spacer()
                if !detail.watchStreams.isEmpty {
                    sourceChip(.online, title: "在线播放")
                }
                sourceChip(.pan115, title: "115 原画")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    if effectiveSource == .online, let first = detail.watchStreams.first {
                        onlineResourceCard(detail, first: first)
                        pan115ResourceCard(detail)
                    } else {
                        pan115ResourceCard(detail)
                        if let first = detail.watchStreams.first {
                            onlineResourceCard(detail, first: first)
                        }
                    }
                    resourceCard(title: "磁力与推送",
                                 caption: detail.magnets.isEmpty ? "这个页面还没有解析到磁力" : "查看可用链接后选择推送",
                                 action: "查看资源", icon: "link", emphasized: false) {
                        showMagnetList = true
                    }
                }
            }
        }
        .accessibilityIdentifier("detail.resource.cards")
    }

    private func sourceChip(_ source: PlaySource, title: String) -> some View {
        let selected = effectiveSource == source
        return Button {
            sourceOverride = source
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? AVFanTheme.accent : Color.secondary.opacity(0.14), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func pan115ResourceCard(_ detail: MovieDetail) -> some View {
        resourceCard(title: "115 原画",
                     caption: pan115.isConfigured ? "打开 115 匹配资源" : "需先在设置里配置 115",
                     action: "选择播放文件", icon: "play.circle", emphasized: effectiveSource == .pan115) {
            startFromBeginning = false
            showPlayer = true
        }
    }

    private func onlineResourceCard(_ detail: MovieDetail, first: WatchStream) -> some View {
        resourceCard(title: "在线播放",
                     caption: "来自当前公开页面的媒体地址",
                     action: first.label, icon: "play.rectangle", emphasized: effectiveSource == .online) {
            startFromBeginning = true
            activeWatch = first
            showWatchPlayer = true
        }
    }

    private func resourceCard(title: String, caption: String, action: String, icon: String, emphasized: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.bold()).foregroundStyle(.primary)
                Text(caption).font(.caption).foregroundStyle(.secondary)
                Label(action, systemImage: icon).font(.subheadline)
                    .foregroundStyle(emphasized ? AVFanTheme.accent : .secondary)
            }
            .padding(16).frame(minWidth: 220, alignment: .leading)
            .liquidGlassRect(cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }

    private func playPrimary() {
        if effectiveSource == .online, let first = display.watchStreams.first {
            startFromBeginning = PlaybackResumePolicy.compactTitle(position: resumeOnline?.position, length: resumeOnline?.length) == nil
            activeWatch = first
            showWatchPlayer = true
            return
        }
        play115()
    }

    private func play115() {
        if pan115.isConfigured || resume115 != nil {
            startFromBeginning = resume115 == nil
            showPlayer = true
            return
        }
        if let first = display.watchStreams.first {
            startFromBeginning = true
            activeWatch = first
            showWatchPlayer = true
        } else {
            toast = pan115.isConfigured ? "没有可播放的资源" : "请先在设置里填写 115 Cookie 和目录 CID，或使用页面里的在线地址。"
            hideToastLater()
        }
    }

    private func movieInfoCard(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow("番号", detail.displayCode)
            infoRow("发行日期", detail.releaseDate)
            infoRow("片长", detail.duration)
            if let rating = detail.rating {
                let count = detail.ratingCount.map { " · \($0)人评分" } ?? ""
                infoRow("评分", String(format: "%.1f 分%@", rating, count))
            }
            linkRow("制作商", detail.makers)
            linkRow("发行商", detail.publishers)
            linkRow("导演", detail.directors)
            // No series row (owner instruction, build 10): the parser's
            // series links are collected page-wide and surface unrelated
            // names (a TMA title showed "Blacked").
        }
        .padding(16)
        .liquidGlassRect(cornerRadius: 18)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
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
    private func linkRow(_ label: String, _ links: [NamedLink]) -> some View {
        if !links.isEmpty {
            HStack(alignment: .top) {
                Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                FlowLayout(spacing: 6) {
                    ForEach(links) { link in
                        NavigationLink {
                            CatalogListView(title: link.name, path: link.href)
                        } label: {
                            Text(link.name)
                                .foregroundStyle(AVFanTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
            }
            .font(.subheadline)
        }
    }

    private func tagsSection(_ tags: [NamedLink]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassSectionHeader(title: "标签", icon: "tag", trailingTitle: nil)
            LinkChips(links: tags)
        }
    }

    private func linkSection(_ title: String, _ links: [NamedLink]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassSectionHeader(title: title, icon: "person.2", trailingTitle: nil)
            LinkChips(links: links)
        }
    }

    private func summarySection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassSectionHeader(title: "简介", icon: "text.alignleft", trailingTitle: nil)
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func magnetsSection(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader(title: "磁力链接", icon: "link", badge: "\(detail.magnets.count)", trailingTitle: nil)
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

    private func refreshResume() {
        let code = model.detail?.displayCode ?? card.displayCode
        if let key = PlaybackResumeKey.make(number: code, source: "115") {
            resume115 = PlaybackResumeStore.shared.entry(key, scope: "avfan")
        }
        if let key = PlaybackResumeKey.make(number: code, source: "avfan") {
            resumeOnline = PlaybackResumeStore.shared.entry(key, scope: "avfan")
        }
    }

    private var shareText: String {
        let detail = model.detail
        let code = detail?.displayCode ?? card.displayCode
        let title = detail?.displayTitle ?? card.displayTitle
        let url = detail?.pageURL ?? HTMLParser.absoluteURL(card.href)
        return "\(code) \(title)\n\(url)"
    }
}

struct DetailPortraitGeometry {
    let width: CGFloat
    let imageHeight: CGFloat
    let titleTop: CGFloat
    let controlsTop: CGFloat

    init(availableSize: CGSize, isPad: Bool) {
        width = max(1, min(availableSize.width, isPad ? 900 : 600))
        imageHeight = min(width * 1.58, max(600, availableSize.height * 0.8))
        titleTop = min(width * 1.06, max(390, availableSize.height * 0.56))
        controlsTop = max(titleTop + 132, min(width * 1.42, availableSize.height * 0.64))
    }
}

private struct DetailTitleHeights: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct DetailReadableTitle: View {
    let title: String
    let identifier: String
    var font: Font = .title2.weight(.bold)
    var collapsedLines: Int = 3
    @State private var expanded = false
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleText.lineLimit(expanded ? nil : collapsedLines)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
                .background(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        titleText.lineLimit(collapsedLines).fixedSize(horizontal: false, vertical: true)
                            .background { GeometryReader { proxy in
                                Color.clear.preference(key: DetailTitleHeights.self, value: ["collapsed": proxy.size.height])
                            } }
                        titleText.fixedSize(horizontal: false, vertical: true)
                            .background { GeometryReader { proxy in
                                Color.clear.preference(key: DetailTitleHeights.self, value: ["full": proxy.size.height])
                            } }
                    }.hidden().accessibilityHidden(true).allowsHitTesting(false)
                }
            if truncated {
                Button { expanded.toggle() } label: {
                    Text(expanded ? "收起标题" : "展开全文")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("detail-title-toggle")
            }
        }
        .onPreferenceChange(DetailTitleHeights.self) { heights in
            truncated = (heights["full"] ?? 0) > (heights["collapsed"] ?? 0) + 1
        }
    }

    private var titleText: some View {
        Text(title).font(font).lineSpacing(4).multilineTextAlignment(.leading)
    }
}

/// Tappable chips for a detail page's casts / tags: each chip pushes the
/// matching catalog list (the cast's, tag's, maker's… own movie list).
struct LinkChips: View {
    let links: [NamedLink]
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(links) { link in
                NavigationLink {
                    CatalogListView(title: link.name, path: link.href)
                } label: {
                    Text(link.name)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AVFanTheme.accent.opacity(0.12), in: Capsule())
                        .foregroundStyle(AVFanTheme.accent)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        var width: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += row + spacing
                row = 0
            }
            row = max(row, size.height)
            x += size.width + spacing
            width = max(width, x - spacing)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var row: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
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
            let html = result.html
            var parsed = await HTMLParser.detached { HTMLParser.movieDetail(from: html, url: url) }
            if parsed.pathID.isEmpty { parsed.pathID = card.pathID }
            // Identity guard (build 11): the fetched page's own 番号 must
            // be the tapped card's. A mismatch means the page that came
            // back is a DIFFERENT movie — never display it as if it were
            // the tapped one; fall back to the card's own data and say so.
            if let cardCode = card.code, let parsedCode = parsed.code {
                let normalize: (String) -> String = {
                    $0.uppercased().filter { $0.isLetter || $0.isNumber }
                }
                if normalize(cardCode) != normalize(parsedCode) {
                    throw SiteClientError.transport("打开的影片与所点封面不一致，已停止打开错误影片")
                }
            }
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
