import SwiftUI

/// The site's 资讯 (news) section (build 6): a native list with the page's
/// own category filter chips and infinite scroll, plus a native article
/// reader (text / image blocks in document order, related movies, casts
/// and same-category news below). If a page doesn't parse, the views fall
/// back to the in-app web view like every other section.
struct NewsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var items: [NewsItem] = []
    @State private var tabs: [NamedLink] = []
    @State private var currentPath = "news"
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var source: FetchSource?
    @State private var showWeb = false
    @State private var pageURL: URL?
    @State private var pagePaths: [Int: String] = [:]
    @State private var totalPages = 1
    @State private var goSearch = false
    @State private var currentPage = 1

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if tabs.count >= 2 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(tabs) { tab in
                                Button {
                                    currentPath = tab.href
                                    pagePaths = [:]
                                    totalPages = 1
                                    Task { await load() }
                                } label: {
                                    Text(tab.name)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                .liquidGlass(tint: isSelected(tab) ? AVFanTheme.accent : nil, interactive: true)
                            }
                        }
                    }
                }
                FetchStatusBanner(source: source, error: errorMessage, webURL: pageURL) { showWeb = true }
                if loading && items.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                }
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        NewsRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
                PagerBar(currentPage: currentPage, totalPages: totalPages, isLoading: loading) { page in
                    Task { await goPage(page) }
                }
            }
            .padding(.horizontal, AdaptiveLayout.horizontalPadding)
            .padding(.vertical, 12)
        }
        .id(currentPage)
        .background(AVFanTheme.pageBackground)
        .navigationTitle("资讯")
        .navigationDestination(isPresented: $goSearch) { SearchView() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { goSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("搜索")
            }
        }
        .navigationDestination(for: NewsItem.self) { NewsArticleView(item: $0) }
        .task { if items.isEmpty { await load() } }
        .refreshable { await load() }
        .sheet(isPresented: $showWeb) {
            if let pageURL { InAppWebView(url: pageURL, title: "资讯") }
        }
        .onChange(of: settings.locale) { _, _ in
            Task { await load() }
        }
    }

    private func isSelected(_ tab: NamedLink) -> Bool {
        HTMLParser.stripLocale(tab.href) == HTMLParser.stripLocale(currentPath)
    }

    private func load() async {
        pagePaths = [:]
        totalPages = 1
        await load(path: currentPath)
    }

    private func goPage(_ page: Int) async {
        guard page != currentPage, page >= 1, !loading else { return }
        let target = pagePaths[page] ?? HTMLParser.withPage(currentPath, page: page)
        await load(path: target)
    }

    private func load(path fetchPath: String) async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        let url = SiteClient.shared.pageURL(path: fetchPath, locale: settings.locale)
        pageURL = url
        currentPage = Int(HTMLParser.firstMatch("[?&]page=(\\d+)", in: fetchPath) ?? "") ?? 1
        do {
            let result = try await SiteClient.shared.html(
                for: url,
                locale: settings.locale,
                ageCookie: settings.legalAgeCookie,
                allowWebViewFallback: true,
                expectCatalog: false
            )
            let html = result.html
            // The sentinel currentPath keeps the currently shown category
            // in the chip row too, so the selection can be highlighted.
            let parsed = await HTMLParser.detached {
                (items: HTMLParser.newsItems(in: html),
                 tabs: HTMLParser.rankingTabs(in: html, basePath: "news", currentPath: "news?__none"),
                 pages: HTMLParser.pageMap(in: html))
            }
            items = parsed.items
            tabs = parsed.tabs
            for (number, href) in parsed.pages { pagePaths[number] = href }
            totalPages = max(totalPages, pagePaths.keys.max() ?? currentPage, currentPage)
            source = result.source
            if items.isEmpty {
                errorMessage = "没有解析到资讯条目，可改用应用内网页。"
                showWeb = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct NewsRow: View {
    let item: NewsItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: item.coverURL)
                .frame(width: 112, height: 84)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    if let category = item.category {
                        Text(category)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AVFanTheme.accent)
                    }
                    if let date = item.date {
                        Text(date)
                    }
                    if let comments = item.commentCount {
                        Label("\(comments)", systemImage: "bubble.right")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Plain remote image on the app's own loader (which sends the UA and
/// Referer the CDN expects). Unlike CoverImage it applies no cover crop
/// policy — news thumbnails and article images show as-is.
struct RemoteImage: View {
    let url: String?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.14))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
        }
        .task(id: url) {
            image = await ImageLoader.shared.load(url, maxPixelSize: 1200)
        }
    }
}

struct NewsArticleView: View {
    let item: NewsItem
    @EnvironmentObject private var settings: AppSettings
    @State private var article: NewsArticle?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var source: FetchSource?
    @State private var showWeb = false
    @State private var pageURL: URL?
    /// Self-hosted item navigation for the related sections — this view
    /// is pushed, and value links resolved at the tab root pop past it
    /// (see MovieGrid.onSelect).
    @State private var openCard: MovieCard?
    @State private var openNews: NewsItem?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    if let category = article?.category ?? item.category {
                        Text(category)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AVFanTheme.accent)
                    }
                    Text(article?.title ?? item.title)
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if let author = article?.author ?? item.author {
                            Text(author)
                        }
                        if let date = article?.date ?? item.date {
                            Text(date)
                        }
                        if let comments = item.commentCount {
                            Label("\(comments) 评论", systemImage: "bubble.right")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                FetchStatusBanner(source: source, error: errorMessage, webURL: pageURL) { showWeb = true }
                if loading && article == nil {
                    ProgressView("正在加载正文…").frame(maxWidth: .infinity)
                }
                if let article {
                    ForEach(Array(article.blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .text(let text):
                            Text(text)
                                .font(.body)
                                .lineSpacing(6)
                                .fixedSize(horizontal: false, vertical: true)
                        case .image(let url):
                            RemoteImage(url: url, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    if !article.relatedMovies.isEmpty {
                        Text("相关影片").font(.headline).padding(.top, 8)
                        MovieGrid(cards: article.relatedMovies, onSelect: { openCard = $0 })
                    }
                    if !article.relatedCasts.isEmpty {
                        Text("相关女优").font(.headline).padding(.top, 8)
                        LinkChips(links: article.relatedCasts)
                    }
                    if !article.relatedNews.isEmpty {
                        Text("同分类资讯").font(.headline).padding(.top, 8)
                        ForEach(article.relatedNews) { news in
                            Button { openNews = news } label: {
                                NewsRow(item: news)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AVFanTheme.pageBackground)
        .navigationTitle(item.category ?? "资讯")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openCard) { MovieDetailView(card: $0) }
        .navigationDestination(item: $openNews) { NewsArticleView(item: $0) }
        .task { await load() }
        .sheet(isPresented: $showWeb) {
            if let pageURL { InAppWebView(url: pageURL, title: item.title) }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let url = SiteClient.shared.catalogURL(path: item.href)
        pageURL = url
        do {
            let result = try await SiteClient.shared.html(
                for: url,
                locale: settings.locale,
                ageCookie: settings.legalAgeCookie,
                allowWebViewFallback: true,
                expectCatalog: false
            )
            let html = result.html
            let parsed = await HTMLParser.detached { HTMLParser.newsArticle(from: html, url: url) }
            article = parsed
            source = result.source
            if parsed.blocks.isEmpty {
                errorMessage = "正文没有解析出来，可改用应用内网页。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
