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
    @State private var prefixes: [NamedLink] = []
    @State private var goSearch = false
    /// Auto-loading (build 13): pages append on scroll instead of the
    /// manual pager; activePath carries any applied filter parameters
    /// on top of the tab path in currentPath.
    @State private var loadedPage = 1
    @State private var nextPage: String?
    @State private var activePath = "series"
    @State private var filterForm: ListFilterForm?
    @State private var selections: [String: Set<String>] = [:]
    @State private var showFilters = false

    private var prefetchID: String? {
        items.dropFirst(max(0, items.count - 4)).first?.id
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if tabs.count >= 2 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(tabs) { tab in
                                Button {
                                    // No animation on a tab switch
                                    // (build 17): the identity rebuild
                                    // below otherwise cross-fades the
                                    // old rows into the new ones, which
                                    // reads as garbled overlapping text.
                                    var txn = Transaction()
                                    txn.disablesAnimations = true
                                    withTransaction(txn) {
                                        currentPath = tab.href
                                        activePath = tab.href
                                        filterForm = nil
                                        selections = [:]
                                        // Drop the old tab's rows at
                                        // once: leaving them in place
                                        // while the new list loads
                                        // painted both lists over each
                                        // other mid-switch.
                                        items = []
                                        nextPage = nil
                                    }
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
                        Text("快捷分类")
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
                    .onAppear {
                        if link.id == prefetchID {
                            Task { await loadNext() }
                        }
                    }
                    Divider().padding(.leading, AdaptiveLayout.horizontalPadding)
                }
                if loading && !items.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding(.vertical, 6)
            // A tab switch rebuilds the stack instead of diffing two
            // unrelated lists into the same cells, and never animates
            // the swap (build 17: the cross-fade looked like garbled
            // overlapping rows).
            .id(currentPath)
            .animation(nil, value: currentPath)
        }
        .background(AVFanTheme.pageBackground)
        .navigationTitle("系列")
        .navigationDestination(isPresented: $goSearch) { SearchView() }
        .toolbar {
            if filterForm != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("筛选")
                }
            }
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
        .sheet(isPresented: $showFilters) {
            if let filterForm {
                FilterSheet(form: filterForm, selections: selections) { newSelections in
                    selections = newSelections
                    activePath = HTMLParser.applyingFilters(
                        activePath, form: filterForm, selections: newSelections)
                    Task { await load() }
                }
            }
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
        await load(path: activePath, append: false)
    }

    private func loadNext() async {
        guard !loading, let target = nextPage else { return }
        await load(path: target, append: true)
    }

    private func load(path fetchPath: String, append: Bool) async {
        loading = true
        if !append { errorMessage = nil }
        defer { loading = false }
        let url = SiteClient.shared.pageURL(path: fetchPath, locale: settings.locale)
        pageURL = url
        let pageNo = append ? loadedPage + 1
            : (Int(HTMLParser.firstMatch("[?&]page=(\\d+)", in: fetchPath) ?? "") ?? 1)
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
                 form: HTMLParser.listFilterForm(in: html),
                 prefixes: HTMLParser.prefixLinks(in: html),
                 drawer: HTMLParser.drawerSeriesLinks(in: html),
                 next: HTMLParser.autoNextPath(in: html, page: pageNo, path: fetchPath))
            }
            if append {
                let known = Set(items.map(\.id))
                let fresh = parsed.items.filter { !known.contains($0.id) }
                items += fresh
                nextPage = fresh.isEmpty ? nil : parsed.next
            } else {
                items = parsed.items
                tabs = parsed.tabs
                nextPage = parsed.next
                if filterForm == nil, let form = parsed.form {
                    filterForm = form
                    selections = form.defaultSelections
                }
                if items.isEmpty {
                    errorMessage = "没有解析到系列条目，可改用应用内网页。"
                    showWeb = true
                }
            }
            loadedPage = pageNo
            if prefixes.isEmpty {
                // The drawer's own series-group shortcuts first (they
                // include Blacked and the 麻豆傳媒映畫 maker page,
                // which are not number-letter prefixes); the plain
                // prefix scan remains the fallback.
                prefixes = parsed.drawer.isEmpty ? parsed.prefixes : parsed.drawer
            }
            source = result.source
        } catch {
            if append {
                nextPage = nil
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

}
