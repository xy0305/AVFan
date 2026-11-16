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
            if loading {
                ProgressView("正在搜索…").padding()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    FetchStatusBanner(source: source, error: errorMessage, webURL: pageURL) { showWeb = true }
                    if !loading && cards.isEmpty && errorMessage == nil && pageURL != nil {
                        Text("没有解析到结果。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    MovieGrid(cards: cards, columns: layoutColumns, onReachEnd: { Task { await loadNext() } })
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
        .navigationDestination(for: MovieCard.self) { MovieDetailView(card: $0) }
        .toolbar {
            if filterForm != nil {
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
                    let base = SiteClient.shared.searchURL(query: lastQuery).absoluteString
                    activePath = HTMLParser.applyingFilters(
                        activePath.isEmpty ? base : activePath,
                        form: filterForm, selections: newSelections)
                    Task { await loadFirstPage() }
                }
            }
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastQuery = trimmed
        activePath = SiteClient.shared.searchURL(query: trimmed).absoluteString
        filterForm = nil
        selections = [:]
        await loadFirstPage()
    }

    private func loadFirstPage() async {
        guard let url = URL(string: activePath) else { return }
        loading = true
        errorMessage = nil
        cards = []
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
            let parsed = await HTMLParser.detached {
                (cards: HTMLParser.movieCards(in: html),
                 form: HTMLParser.listFilterForm(in: html),
                 next: HTMLParser.autoNextPath(in: html, page: 1, path: path))
            }
            cards = parsed.cards
            nextPage = parsed.next
            if filterForm == nil, let form = parsed.form {
                filterForm = form
                selections = form.defaultSelections
            }
            source = result.source
            if cards.isEmpty {
                errorMessage = "搜索页没有可解析的影片，可改用应用内网页。"
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
            let parsed = await HTMLParser.detached {
                (cards: HTMLParser.movieCards(in: html),
                 next: HTMLParser.autoNextPath(in: html, page: pageNo, path: target))
            }
            let known = Set(cards.map(\.pathID))
            let fresh = parsed.cards.filter { !known.contains($0.pathID) }
            cards += fresh
            loadedPage = pageNo
            nextPage = fresh.isEmpty ? nil : parsed.next
            source = result.source
        } catch {
            nextPage = nil
        }
    }
}
