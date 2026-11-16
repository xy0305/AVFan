import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var query = ""
    @State private var cards: [MovieCard] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var source: FetchSource?
    @State private var showWeb = false
    @State private var pageURL: URL?
    @State private var pagePaths: [Int: String] = [:]
    @State private var totalPages = 1
    @State private var lastQuery = ""
    @State private var currentPage = 1

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
                    MovieGrid(cards: cards)
                    PagerBar(currentPage: currentPage, totalPages: totalPages, isLoading: loading) { page in
                        Task { await goPage(page) }
                    }
                }
                .padding(.horizontal, AdaptiveLayout.horizontalPadding)
                .padding(.vertical, 12)
            }
        }
        .background(AVFanTheme.pageBackground)
        .navigationTitle("搜索")
        .navigationDestination(for: MovieCard.self) { MovieDetailView(card: $0) }
        .sheet(isPresented: $showWeb) {
            if let pageURL { InAppWebView(url: pageURL, title: "搜索") }
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        loading = true
        errorMessage = nil
        cards = []
        pagePaths = [:]
        totalPages = 1
        currentPage = 1
        lastQuery = trimmed
        defer { loading = false }
        let url = SiteClient.shared.searchURL(query: trimmed)
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
            let parsed = await HTMLParser.detached {
                (cards: HTMLParser.movieCards(in: html),
                 pages: HTMLParser.pageMap(in: html))
            }
            cards = parsed.cards
            pagePaths = parsed.pages
            totalPages = max(1, parsed.pages.keys.max() ?? 1)
            source = result.source
            if cards.isEmpty {
                errorMessage = "搜索页没有可解析的影片，可改用应用内网页。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Website-style paging (build 11): jump to a numbered page of the
    /// current search instead of appending endlessly.
    private func goPage(_ page: Int) async {
        guard page != currentPage, page >= 1, !loading, !lastQuery.isEmpty else { return }
        loading = true
        defer { loading = false }
        let url: URL
        if let path = pagePaths[page] {
            url = SiteClient.shared.catalogURL(path: path)
        } else if let built = URL(string: HTMLParser.withPage(
            SiteClient.shared.searchURL(query: lastQuery).absoluteString, page: page)) {
            url = built
        } else { return }
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
            let parsed = await HTMLParser.detached {
                (cards: HTMLParser.movieCards(in: html),
                 pages: HTMLParser.pageMap(in: html))
            }
            cards = parsed.cards
            currentPage = page
            for (number, href) in parsed.pages { pagePaths[number] = href }
            totalPages = max(totalPages, pagePaths.keys.max() ?? page, page)
            source = result.source
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
