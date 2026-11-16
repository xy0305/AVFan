import SwiftUI

struct RankingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var kind: RankingKind = .last24h
    /// Path of the ranking variant currently shown: a RankingKind.path, or
    /// one of the sub-category hrefs the ranking page itself carries
    /// (FANZA/MGS tabs, TOP300 category/year, FC2 years — build 5).
    @State private var currentPath: String = RankingKind.last24h.path
    @State private var page: RankingPage?
    @State private var tabs: [NamedLink] = []
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
            VStack(alignment: .leading, spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RankingKind.allCases) { item in
                            Button {
                                kind = item
                                currentPath = item.path
                                tabs = []
                                pagePaths = [:]
                                totalPages = 1
                                Task { await load() }
                            } label: {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .liquidGlass(tint: kind == item ? AVFanTheme.accent : nil, interactive: true)
                        }
                    }
                }
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
                if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 180) }
                if let page, !page.people.isEmpty && page.cards.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)], spacing: 14) {
                        ForEach(page.people) { person in
                            NavigationLink {
                                CatalogListView(title: person.name, path: person.href)
                            } label: {
                                VStack(spacing: 6) {
                                    CoverImage(url: person.imageURL)
                                        .aspectRatio(3.0 / 4.0, contentMode: .fill)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    Text(person.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let page {
                    MovieGrid(cards: page.cards)
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
        .navigationTitle("排行榜")
        .navigationDestination(isPresented: $goSearch) { SearchView() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { goSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("搜索")
            }
        }
        .navigationDestination(for: MovieCard.self) { MovieDetailView(card: $0) }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showWeb) {
            if let pageURL { InAppWebView(url: pageURL, title: kind.title) }
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
        let url = SiteClient.shared.rankingURL(path: fetchPath, locale: settings.locale)
        pageURL = url
        currentPage = Int(HTMLParser.firstMatch("[?&]page=(\\d+)", in: fetchPath) ?? "") ?? 1
        do {
            let result = try await SiteClient.shared.html(
                for: url,
                locale: settings.locale,
                ageCookie: settings.legalAgeCookie,
                allowWebViewFallback: true,
                expectCatalog: true
            )
            let html = result.html
            let base = String(currentPath.split(separator: "?").first ?? "")
            let shown = currentPath
            let parsed = await HTMLParser.detached {
                (page: HTMLParser.ranking(from: html),
                 tabs: HTMLParser.rankingTabs(in: html, basePath: base, currentPath: shown),
                 pages: HTMLParser.pageMap(in: html))
            }
            page = parsed.page
            tabs = parsed.tabs
            for (number, href) in parsed.pages { pagePaths[number] = href }
            totalPages = max(totalPages, pagePaths.keys.max() ?? currentPage, currentPage)
            source = result.source
            if parsed.page.cards.isEmpty && parsed.page.people.isEmpty {
                errorMessage = "没有解析到排行条目，可改用应用内网页。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Ranking lists paginate on the site too; scrolling appends the next
    /// page of cards (people rankings are single lists and never paginate).
}
