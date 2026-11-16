import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var query = ""
    @State private var cards: [MovieCard] = []
    @State private var loading = false
    @State private var loadingMore = false
    @State private var errorMessage: String?
    @State private var source: FetchSource?
    @State private var showWeb = false
    @State private var pageURL: URL?
    @State private var lastQuery = ""
    /// Auto-loading (build 13): result pages append on scroll instead
    /// of the manual pager; when the results page carries the site's
    /// filter form, it is offered behind the 筛选 toolbar button.
    @State private var loadedPage = 1
    @State private var nextPage: String?
    @State private var activePath = ""
    @State private var filterForm: ListFilterForm?
    @State private var selections: [String: Set<String>] = [:]
    @State private var showFilters = false
    /// Self-hosted detail navigation (build 24): this view is itself
    /// PUSHED into each tab's stack, and value-based MovieCard links
    /// resolved against a tab-root registration popped the stack —
    /// the search page bounced back and forth and lost its query.
    /// Item-based state, the pattern every other pushed list uses.
    @State private var openCard: MovieCard?
    /// Search result types (build 24): the site's type dropdown —
    /// 全部/影片/演员/系列/制作商/导演. Starts from the known st
    /// values; once a results page is parsed, the page's own type
    /// links replace the set (including 影片 with its real href).
    @State private var activeST = "all"
    @State private var activeTypeLabel = "全部"
    @State private var typeLinks: [NamedLink] = [
        NamedLink(name: "全部", href: "st:all", kind: "search-type"),
        NamedLink(name: "演员", href: "st:cast", kind: "search-type"),
        NamedLink(name: "系列", href: "st:series", kind: "search-type"),
        NamedLink(name: "制作商", href: "st:maker", kind: "search-type"),
        NamedLink(name: "导演", href: "st:director", kind: "search-type"),
    ]
    @State private var castResults: [CastCard] = []
    @State private var linkResults: [NamedLink] = []
    /// Hot searches (build 30): the site's own 热门搜索 ranking,
    /// parsed from the search landing page and shown as chips in
    /// the idle state, mirroring the website's search home.
    @State private var hotTerms: [String] = []
    @State private var hotLoaded = false

    private enum ResultKind { case movies, casts, links }
    private var resultKind: ResultKind {
        switch activeTypeLabel {
        case "演员": return .casts
        case "系列", "制作商", "导演": return .links
        default: return .movies
        }
    }
    private var linkSection: String {
        switch activeTypeLabel {
        case "系列": return "series"
        case "制作商": return "makers"
        default: return "directors"
        }
    }

    private var layoutColumns: Int? { filterForm?.layoutColumns(selections: selections) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("搜索番号、标题、演员…", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                Button("搜索") { Task { await search() } }
                    .font(.subheadline.weight(.semibold))
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                    .glassChromeButton(prominent: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .liquidGlassRect(cornerRadius: 18, interactive: true)
            .padding(.horizontal, AdaptiveLayout.horizontalPadding)
            .padding(.top, 8)
            // Result-type chips: the site's search types.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(typeLinks) { type in
                        Button {
                            selectType(type)
                        } label: {
                            Text(type.name)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 6)
                                .background(type.name == activeTypeLabel ? AVFanTheme.accent : Color(.secondarySystemBackground), in: Capsule())
                                .foregroundStyle(type.name == activeTypeLabel ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AdaptiveLayout.horizontalPadding)
                .padding(.vertical, 6)
            }
            if loading {
                ProgressView("正在搜索…").padding()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    FetchStatusBanner(source: source, error: errorMessage, webURL: pageURL) { showWeb = true }
                    if lastQuery.isEmpty && cards.isEmpty && castResults.isEmpty && linkResults.isEmpty {
                        hotSearchSection
                    }
                    if !loading && cards.isEmpty && castResults.isEmpty && linkResults.isEmpty && errorMessage == nil && pageURL != nil {
                        Text("没有解析到结果。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    switch resultKind {
                    case .movies:
                        MovieGrid(cards: cards, columns: layoutColumns, onSelect: { openCard = $0 }, onReachEnd: { Task { await loadNext() } })
                    case .casts:
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 14) {
                            ForEach(castResults) { cast in
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
                                            .lineLimit(1)
                                        if let count = cast.countText {
                                            Text(count)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .onAppear {
                                    if cast.id == castResults.last?.id {
                                        Task { await loadNext() }
                                    }
                                }
                            }
                        }
                    case .links:
                        ForEach(linkResults) { link in
                            NavigationLink {
                                CatalogListView(title: link.name, path: link.href)
                            } label: {
                                HStack {
                                    Text(link.name).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if link.id == linkResults.last?.id {
                                    Task { await loadNext() }
                                }
                            }
                        }
                    }
                    if loadingMore {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, AdaptiveLayout.horizontalPadding)
                .padding(.vertical, 12)
            }
        }
        .background(AVFanTheme.pageBackground)
        .navigationTitle("搜索")
        .task { await loadHotSearches() }
        .navigationDestination(item: $openCard) { MovieDetailView(card: $0) }
        .toolbar {
            if filterForm != nil && resultKind == .movies {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("筛选")
                }
            }
        }
        .sheet(isPresented: $showWeb) {
            if let pageURL { InAppWebView(url: pageURL, title: "搜索") }
        }
        .sheet(isPresented: $showFilters) {
            if let filterForm {
                FilterSheet(form: filterForm, selections: selections) { newSelections in
                    selections = newSelections
                    let base = SiteClient.shared.searchURL(query: lastQuery, st: activeST).absoluteString
                    activePath = HTMLParser.applyingFilters(
                        activePath.isEmpty ? base : activePath,
                        form: filterForm, selections: newSelections)
                    Task { await loadFirstPage() }
                }
            }
        }
    }

    /// Hot-search chips, mirroring the website's search home:
    /// the site's ranking order, the top three tinted (red /
    /// orange / amber), the rest neutral. Tapping a chip runs
    /// that search.
    @ViewBuilder
    private var hotSearchSection: some View {
        if !hotTerms.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                GlassSectionHeader(title: "热门搜索", icon: "flame.fill", trailingTitle: nil)
                FlowLayout(spacing: 8) {
                    ForEach(Array(hotTerms.enumerated()), id: \.offset) { index, term in
                        Button {
                            query = term
                            Task { await search() }
                        } label: {
                            Text(term)
                                .font(.subheadline.weight(index < 3 ? .semibold : .regular))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(hotChipBackground(index), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .foregroundStyle(hotChipForeground(index))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func hotChipBackground(_ index: Int) -> Color {
        switch index {
        case 0: return Color.red.opacity(0.10)
        case 1: return Color.orange.opacity(0.12)
        case 2: return Color.yellow.opacity(0.16)
        default: return Color(.secondarySystemBackground)
        }
    }

    private func hotChipForeground(_ index: Int) -> Color {
        switch index {
        case 0: return .red
        case 1: return .orange
        case 2: return Color(red: 0.62, green: 0.42, blue: 0.0)
        default: return .primary
        }
    }

    /// Fetch the search landing page once and read its 热门搜索
    /// ranking. A failure just leaves the section hidden — the
    /// search box itself is unaffected.
    private func loadHotSearches() async {
        guard !hotLoaded else { return }
        hotLoaded = true
        let url = SiteClient.shared.searchURL(query: "")
        guard let result = try? await SiteClient.shared.html(
            for: url,
            locale: settings.locale,
            ageCookie: settings.legalAgeCookie,
            allowWebViewFallback: true,
            expectCatalog: false
        ) else { return }
        hotTerms = await HTMLParser.detached { HTMLParser.hotSearchTerms(in: result.html) }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastQuery = trimmed
        activePath = SiteClient.shared.searchURL(query: trimmed, st: activeST).absoluteString
        filterForm = nil
        selections = [:]
        await loadFirstPage()
    }

    /// Switch the result type: re-run the current query under the
    /// type's own st (from the page's dropdown link when available).
    private func selectType(_ type: NamedLink) {
        guard type.name != activeTypeLabel else { return }
        activeTypeLabel = type.name
        if type.href.hasPrefix("st:") {
            activeST = String(type.href.dropFirst(3))
        } else if let url = URL(string: type.href),
                  let st = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "st" })?.value {
            activeST = st
        }
        filterForm = nil
        selections = [:]
        guard !lastQuery.isEmpty else { return }
        if type.href.hasPrefix("http") || type.href.hasPrefix("/") {
            activePath = type.href
        } else {
            activePath = SiteClient.shared.searchURL(query: lastQuery, st: activeST).absoluteString
        }
        Task { await loadFirstPage() }
    }

    private func loadFirstPage() async {
        // Toolbar-applied filters come back as site paths, not the
        // absolute search URL this view starts from.
        guard let url = activePath.hasPrefix("http")
            ? URL(string: activePath)
            : SiteClient.shared.catalogURL(path: activePath) else { return }
        loading = true
        errorMessage = nil
        cards = []
        castResults = []
        linkResults = []
        loadedPage = 1
        nextPage = nil
        defer { loading = false }
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
            let path = activePath
            let kind = resultKind
            let section = linkSection
            let parsed = await HTMLParser.detached {
                (cards: HTMLParser.movieCards(in: html),
                 casts: HTMLParser.castCards(in: html),
                 links: HTMLParser.searchLinkRows(in: html, section: section),
                 types: HTMLParser.searchTypes(in: html),
                 form: HTMLParser.listFilterForm(in: html),
                 next: HTMLParser.autoNextPath(in: html, page: 1, path: path))
            }
            cards = parsed.cards
            castResults = parsed.casts
            linkResults = parsed.links
            if !parsed.types.isEmpty { typeLinks = parsed.types }
            nextPage = parsed.next
            if filterForm == nil, let form = parsed.form {
                filterForm = form
                selections = form.defaultSelections
            }
            source = result.source
            let empty: Bool
            switch kind {
            case .movies: empty = parsed.cards.isEmpty
            case .casts: empty = parsed.casts.isEmpty
            case .links: empty = parsed.links.isEmpty
            }
            if empty {
                errorMessage = "搜索页没有可解析的结果，可改用应用内网页。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Auto-load the next page of results (scrolling append); a failed
    /// fetch just ends paging, the loaded results stay on screen.
    private func loadNext() async {
        guard !loading, !loadingMore, let target = nextPage else { return }
        loadingMore = true
        defer { loadingMore = false }
        let url = SiteClient.shared.catalogURL(path: target)
        pageURL = url
        let pageNo = loadedPage + 1
        do {
            let result = try await SiteClient.shared.html(
                for: url,
                locale: settings.locale,
                ageCookie: settings.legalAgeCookie,
                allowWebViewFallback: true,
                expectCatalog: true
            )
            let html = result.html
            let section = linkSection
            let parsed = await HTMLParser.detached {
                (cards: HTMLParser.movieCards(in: html),
                 casts: HTMLParser.castCards(in: html),
                 links: HTMLParser.searchLinkRows(in: html, section: section),
                 next: HTMLParser.autoNextPath(in: html, page: pageNo, path: target))
            }
            let known = Set(cards.map(\.pathID))
            let fresh = parsed.cards.filter { !known.contains($0.pathID) }
            cards += fresh
            let knownCasts = Set(castResults.map(\.id))
            let freshCasts = parsed.casts.filter { !knownCasts.contains($0.id) }
            castResults += freshCasts
            let knownLinks = Set(linkResults.map(\.id))
            let freshLinks = parsed.links.filter { !knownLinks.contains($0.id) }
            linkResults += freshLinks
            loadedPage = pageNo
            let anyFresh = !fresh.isEmpty || !freshCasts.isEmpty || !freshLinks.isEmpty
            nextPage = anyFresh ? parsed.next : nil
            source = result.source
        } catch {
            nextPage = nil
        }
    }
}
