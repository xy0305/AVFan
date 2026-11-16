import SwiftUI

/// The site's 系列 (series) section (build 6): the index is a plain text
/// list on the site (name only, no covers), split into 亚洲 / 欧美 / 动漫
/// by the page's own t= tabs; each series opens its movie list, which is
/// a standard catalog page and reuses CatalogListView (with its infinite
/// scroll).
struct SeriesView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var items: [NamedLink] = []
    @State private var tabs: [NamedLink] = []
    @State private var currentPath = "series"
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var source: FetchSource?
    @State private var showWeb = false
    @State private var pageURL: URL?
    @State private var pagePaths: [Int: String] = [:]
    @State private var totalPages = 1
    @State private var prefixes: [NamedLink] = []
    @State private var goSearch = false
    @State private var currentPage = 1

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
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
                    .padding(.horizontal, AdaptiveLayout.horizontalPadding)
                    .padding(.vertical, 10)
                }
                FetchStatusBanner(source: source, error: errorMessage, webURL: pageURL) { showWeb = true }
                    .padding(.horizontal, AdaptiveLayout.horizontalPadding)
                if !prefixes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("番号前缀")
                            .font(.subheadline.weight(.bold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(prefixes) { prefix in
                                NavigationLink {
                                    CatalogListView(title: prefix.name, path: prefix.href)
                                } label: {
                                    Text(prefix.name)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.plain)
                                .liquidGlass(interactive: true)
                            }
                        }
                    }
                    .padding(.horizontal, AdaptiveLayout.horizontalPadding)
                    .padding(.vertical, 10)
                }
                if loading && items.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                }
                ForEach(items) { link in
                    NavigationLink {
                        CatalogListView(title: link.name, path: link.href)
                    } label: {
                        HStack(spacing: 8) {
                            Text(link.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, AdaptiveLayout.horizontalPadding)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, AdaptiveLayout.horizontalPadding)
                }
                PagerBar(currentPage: currentPage, totalPages: totalPages, isLoading: loading) { page in
                    Task { await goPage(page) }
                }
                .padding(.horizontal, AdaptiveLayout.horizontalPadding)
            }
            .padding(.vertical, 6)
        }
        .id(currentPage)
        .background(AVFanTheme.pageBackground)
        .navigationTitle("系列")
        .navigationDestination(isPresented: $goSearch) { SearchView() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { goSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("搜索")
            }
        }
        .task { if items.isEmpty { await load() } }
        .refreshable { await load() }
        .sheet(isPresented: $showWeb) {
            if let pageURL { InAppWebView(url: pageURL, title: "系列") }
        }
        .onChange(of: settings.locale) { _, _ in
            Task { await load() }
        }
    }

    private func isSelected(_ tab: NamedLink) -> Bool {
        let current = HTMLParser.stripLocale(currentPath)
        if HTMLParser.stripLocale(tab.href) == current { return true }
        // The bare /series page IS the asian list; its tab carries ?t=asian.
        return current == "series" && tab.href.contains("t=asian")
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
                (items: HTMLParser.seriesItems(in: html),
                 tabs: HTMLParser.rankingTabs(in: html, basePath: "series", currentPath: "series?__none"),
                 pages: HTMLParser.pageMap(in: html),
                 prefixes: HTMLParser.prefixLinks(in: html))
            }
            items = parsed.items
            tabs = parsed.tabs
            for (number, href) in parsed.pages { pagePaths[number] = href }
            totalPages = max(totalPages, pagePaths.keys.max() ?? currentPage, currentPage)
            if prefixes.isEmpty { prefixes = parsed.prefixes }
            source = result.source
            if items.isEmpty {
                errorMessage = "没有解析到系列条目，可改用应用内网页。"
                showWeb = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
