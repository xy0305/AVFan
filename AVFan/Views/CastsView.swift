import SwiftUI

/// The site's 演员 (casts) section (build 11): avatar grid split into
/// 推荐 / 亚洲 / 欧美 like the site's own drawer, website-style paging,
/// each cast opening its movie list as a standard catalog page. Chips
/// prefer the tabs the page itself carries; the three drawer entries
/// observed on the site are the fallback. A page that doesn't parse
/// falls back to the in-app web view like every other section.
struct CastsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var casts: [CastCard] = []
    @State private var tabs: [NamedLink] = []
    @State private var currentPath = "casts?t=asian"
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var source: FetchSource?
    @State private var showWeb = false
    @State private var pageURL: URL?
    @State private var currentPage = 1
    @State private var pagePaths: [Int: String] = [:]
    @State private var totalPages = 1
    @State private var goSearch = false

    private static let fallbackTabs: [NamedLink] = [
        NamedLink(name: "推荐", href: "/casts/new_and_recommendations", kind: "casttab"),
        NamedLink(name: "亚洲", href: "/casts?t=asian", kind: "casttab"),
        NamedLink(name: "欧美", href: "/casts?t=western", kind: "casttab"),
    ]

    private var shownTabs: [NamedLink] {
        tabs.count >= 2 ? tabs : Self.fallbackTabs
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shownTabs) { tab in
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
                FetchStatusBanner(source: source, error: errorMessage, webURL: pageURL) { showWeb = true }
                if loading && casts.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)], spacing: 14) {
                    ForEach(casts) { cast in
                        NavigationLink {
                            CatalogListView(title: cast.name, path: cast.href)
                        } label: {
                            VStack(spacing: 6) {
                                CoverImage(url: cast.avatarURL)
                                    .aspectRatio(3.0 / 4.0, contentMode: .fill)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(cast.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if let count = cast.countText {
                                    Text(count)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if loading && !casts.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
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
        .navigationTitle("演员")
        .navigationDestination(isPresented: $goSearch) { SearchView() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { goSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("搜索")
            }
        }
        .task { if casts.isEmpty { await load() } }
        .refreshable { await load() }
        .sheet(isPresented: $showWeb) {
            if let pageURL { InAppWebView(url: pageURL, title: "演员") }
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
            let parsed = await HTMLParser.detached {
                (casts: HTMLParser.castCards(in: html),
                 tabs: HTMLParser.rankingTabs(in: html, basePath: "casts", currentPath: "casts?__none"),
                 pages: HTMLParser.pageMap(in: html))
            }
            casts = parsed.casts
            if parsed.tabs.count >= 2 { tabs = parsed.tabs }
            for (number, href) in parsed.pages { pagePaths[number] = href }
            totalPages = max(totalPages, pagePaths.keys.max() ?? currentPage, currentPage)
            source = result.source
            if casts.isEmpty {
                errorMessage = "没有解析到演员条目，可改用应用内网页。"
                showWeb = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
