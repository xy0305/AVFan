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
    @State private var nextPath: String?
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
                    MovieGrid(cards: cards) { Task { await loadMore() } }
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
        nextPath = nil
        currentPage = 1
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
                 next: HTMLParser.nextPagePath(in: html, currentPage: 1))
            }
            cards = parsed.cards
            nextPath = parsed.next
            source = result.source
            if cards.isEmpty {
                errorMessage = "搜索页没有可解析的影片，可改用应用内网页。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Search results paginate on the site; scrolling appends the next page.
    private func loadMore() async {
        guard let nextPath, !loading, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let url = SiteClient.shared.catalogURL(path: nextPath)
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
                (cards: HTMLParser.movieCards(in: html),
                 next: HTMLParser.nextPagePath(in: html, currentPage: targetPage))
            }
            let known = Set(cards.map(\.pathID))
            let fresh = parsed.cards.filter { !known.contains($0.pathID) }
            if fresh.isEmpty {
                self.nextPath = nil
                return
            }
            cards.append(contentsOf: fresh)
            currentPage = targetPage
            self.nextPath = parsed.next
            source = result.source
        } catch {
            // Keep nextPath for a later retry.
        }
    }
}
