import SwiftUI

/// The site's 演员 (casts) section (build 11): avatar grid split into
/// 推荐 / 亚洲 / 欧美 like the site's own drawer, each cast opening its
/// movie list as a standard catalog page. Chips prefer the tabs the
/// page itself carries; the three drawer entries observed on the site
/// are the fallback. Build 13: pages auto-load on scroll (no manual
/// pager), and the page's own filter form is honored when present. A
/// page that doesn't parse falls back to the in-app web view like
/// every other section.
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
    @State private var goSearch = false
    @State private var loadedPage = 1
    @State private var nextPage: String?
    @State private var activePath = "casts?t=asian"
    @State private var filterForm: ListFilterForm?
    @State private var selections: [String: Set<String>] = [:]
    @State private var showFilters = false

    private static let fallbackTabs: [NamedLink] = [
        NamedLink(name: "推荐", href: "/casts/new_and_recommendations", kind: "casttab"),
        NamedLink(name: "亚洲", href: "/casts?t=asian", kind: "casttab"),
        NamedLink(name: "欧美", href: "/casts?t=western", kind: "casttab"),
    ]

    private var shownTabs: [NamedLink] {
        tabs.count >= 2 ? tabs : Self.fallbackTabs
    }

    private var prefetchID: String? {
        casts.dropFirst(max(0, casts.count - 6)).first?.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shownTabs) { tab in
                            Button {
                                currentPath = tab.href
                                activePath = tab.href
                                filterForm = nil
                                selections = [:]
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
                            CastProfileView(name: cast.name, path: cast.href)
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
                        .onAppear {
                            if cast.id == prefetchID {
                                Task { await loadNext() }
                            }
                        }
                    }
                }
                if loading && !casts.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
            .padding(.horizontal, AdaptiveLayout.horizontalPadding)
            .padding(.vertical, 12)
        }
        .background(AVFanTheme.pageBackground)
        .navigationTitle("演员")
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
        .task { if casts.isEmpty { await load() } }
        .refreshable { await load() }
        .sheet(isPresented: $showWeb) {
            if let pageURL { InAppWebView(url: pageURL, title: "演员") }
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
        HTMLParser.stripLocale(tab.href) == HTMLParser.stripLocale(currentPath)
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
                (casts: HTMLParser.castCards(in: html),
                 tabs: HTMLParser.rankingTabs(in: html, basePath: "casts", currentPath: "casts?__none"),
                 form: HTMLParser.listFilterForm(in: html),
                 next: HTMLParser.autoNextPath(in: html, page: pageNo, path: fetchPath))
            }
            if append {
                let known = Set(casts.map(\.id))
                let fresh = parsed.casts.filter { !known.contains($0.id) }
                casts += fresh
                nextPage = fresh.isEmpty ? nil : parsed.next
            } else {
                casts = parsed.casts
                if parsed.tabs.count >= 2 { tabs = parsed.tabs }
                nextPage = parsed.next
                if filterForm == nil, let form = parsed.form {
                    filterForm = form
                    selections = form.defaultSelections
                }
                if casts.isEmpty {
                    errorMessage = "没有解析到演员条目，可改用应用内网页。"
                    showWeb = true
                }
            }
            loadedPage = pageNo
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
