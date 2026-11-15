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
    @State private var loadingMore = false
    @State private var errorMessage: String?
    @State private var source: FetchSource?
    @State private var showWeb = false
    @State private var pageURL: URL?
    @State private var nextPath: String?
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
                                    nextPath = nil
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
                    .onAppear {
                        if link.href == prefetchHref { Task { await loadMore() } }
                    }
                    Divider().padding(.leading, AdaptiveLayout.horizontalPadding)
                }
                if loadingMore {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 10)
                }
            }
            .padding(.vertical, 6)
        }
        .background(AVFanTheme.pageBackground)
        .navigationTitle("系列")
        .task { if items.isEmpty { await load() } }
        .refreshable { await load() }
        .sheet(isPresented: $showWeb) {
            if let pageURL { InAppWebView(url: pageURL, title: "系列") }
        }
        .onChange(of: settings.locale) { _, _ in
            Task { await load() }
        }
    }

    private var prefetchHref: String? {
        items.dropFirst(max(0, items.count - 6)).first?.href
    }

    private func isSelected(_ tab: NamedLink) -> Bool {
        let current = HTMLParser.stripLocale(currentPath)
        if HTMLParser.stripLocale(tab.href) == current { return true }
        // The bare /series page IS the asian list; its tab carries ?t=asian.
        return current == "series" && tab.href.contains("t=asian")
    }

    private func load() async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        let url = SiteClient.shared.pageURL(path: currentPath, locale: settings.locale)
        pageURL = url
        currentPage = Int(HTMLParser.firstMatch("[?&]page=(\\d+)", in: currentPath) ?? "") ?? 1
        do {
            let result = try await SiteClient.shared.html(
                for: url,
                locale: settings.locale,
                ageCookie: settings.legalAgeCookie,
                allowWebViewFallback: true,
                expectCatalog: false
            )
            let html = result.html
            let page = currentPage
            let parsed = await HTMLParser.detached {
                (items: HTMLParser.seriesItems(in: html),
                 tabs: HTMLParser.rankingTabs(in: html, basePath: "series", currentPath: "series?__none"),
                 next: HTMLParser.nextPagePath(in: html, currentPage: page))
            }
            items = parsed.items
            tabs = parsed.tabs
            nextPath = parsed.next
            source = result.source
            if items.isEmpty {
                errorMessage = "没有解析到系列条目，可改用应用内网页。"
                showWeb = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let nextPath, !loading, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let url = SiteClient.shared.pageURL(path: nextPath, locale: settings.locale)
        let targetPage = Int(HTMLParser.firstMatch("[?&]page=(\\d+)", in: nextPath) ?? "") ?? (currentPage + 1)
        do {
            let result = try await SiteClient.shared.html(
                for: url,
                locale: settings.locale,
                ageCookie: settings.legalAgeCookie,
                allowWebViewFallback: true,
                expectCatalog: true
            )
            let html = result.html
            let parsed = await HTMLParser.detached {
                (items: HTMLParser.seriesItems(in: html),
                 next: HTMLParser.nextPagePath(in: html, currentPage: targetPage))
            }
            let known = Set(items.map(\.href))
            let fresh = parsed.items.filter { !known.contains($0.href) }
            if fresh.isEmpty {
                self.nextPath = nil
                return
            }
            items.append(contentsOf: fresh)
            currentPage = targetPage
            self.nextPath = parsed.next
            source = result.source
        } catch {
            // Keep nextPath for a later retry.
        }
    }
}
