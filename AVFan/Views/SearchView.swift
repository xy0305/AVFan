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
            cards = HTMLParser.movieCards(in: result.html)
            source = result.source
            if cards.isEmpty {
                errorMessage = "搜索页没有可解析的影片，可改用应用内网页。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
