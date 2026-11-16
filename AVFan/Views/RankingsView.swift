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
    @State private var goSearch = false
    /// Auto-loading (build 13): pages append on scroll instead of the
    /// manual pager. currentPath stays the variant path (tab selection
    /// state); activePath is what actually gets fetched and carries any
    /// applied filter parameters. When a ranking page carries the
    /// site's filter form, it is offered behind the 筛选 button.
    @State private var loadedPage = 1
    @State private var nextPage: String?
    @State private var activePath: String = RankingKind.last24h.path
    @State private var filterForm: ListFilterForm?
    @State private var selections: [String: Set<String>] = [:]
    @State private var showFilters = false

    private var layoutColumns: Int? { filterForm?.layoutColumns(selections: selections) }

    private var peoplePrefetchID: String? {
        guard let people = page?.people, !people.isEmpty else { return nil }
        return people.dropFirst(max(0, people.count - 6)).first?.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RankingKind.allCases) { item in
                            Button {
                                kind = item
                                currentPath = item.path
                                activePath = item.path
                                tabs = []
                                filterForm = nil
                                selections = [:]
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
                }
                FetchStatusBanner(source: source, error: errorMessage, webURL: pageURL) { showWeb = true }
                if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 180) }
                if let page, !page.people.isEmpty && page.cards.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)], spacing: 14) {
                        ForEach(page.people) { person in
                            NavigationLink {
                                CastProfileView(name: person.name, path: person.href)
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
                            .onAppear {
                                if person.id == peoplePrefetchID {
                                    Task { await loadNext() }
                                }
                            }
                        }
                    }
                }
                if let page {
                    MovieGrid(cards: page.cards, columns: layoutColumns, onReachEnd: { Task { await loadNext() } })
                }
            }
            .padding(.horizontal, AdaptiveLayout.horizontalPadding)
            .padding(.vertical, 12)
        }
        .background(AVFanTheme.pageBackground)
        .navigationTitle("排行榜")
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
        .navigationDestination(for: MovieCard.self) { MovieDetailView(card: $0) }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showWeb) {
            if let pageURL { InAppWebView(url: pageURL, title: kind.title) }
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
        let url = SiteClient.shared.rankingURL(path: fetchPath, locale: settings.locale)
        pageURL = url
        let pageNo = append ? loadedPage + 1
            : (Int(HTMLParser.firstMatch("[?&]page=(\\d+)", in: fetchPath) ?? "") ?? 1)
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
                 form: HTMLParser.listFilterForm(in: html),
                 next: HTMLParser.autoNextPath(in: html, page: pageNo, path: fetchPath))
            }
            if append, let existing = page {
                let knownCards = Set(existing.cards.map(\.pathID))
                let freshCards = parsed.page.cards.filter { !knownCards.contains($0.pathID) }
                let knownPeople = Set(existing.people.map(\.id))
                let freshPeople = parsed.page.people.filter { !knownPeople.contains($0.id) }
                page = RankingPage(title: existing.title,
                                   cards: existing.cards + freshCards,
                                   people: existing.people + freshPeople)
                nextPage = (freshCards.isEmpty && freshPeople.isEmpty) ? nil : parsed.next
            } else {
                page = parsed.page
                tabs = parsed.tabs
                nextPage = parsed.next
                if filterForm == nil, let form = parsed.form {
                    filterForm = form
                    selections = form.defaultSelections
                }
                if parsed.page.cards.isEmpty && parsed.page.people.isEmpty {
                    errorMessage = "没有解析到排行条目，可改用应用内网页。"
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
