import SwiftUI

struct RankingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var kind: RankingKind = .last24h
    @State private var page: RankingPage?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var source: FetchSource?
    @State private var showWeb = false
    @State private var pageURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RankingKind.allCases) { item in
                            Button(item.title) {
                                kind = item
                                Task { await load() }
                            }
                            .buttonStyle(.bordered)
                            .tint(kind == item ? AVFanTheme.accent : .secondary)
                        }
                    }
                }
                FetchStatusBanner(source: source, error: errorMessage, webURL: pageURL) { showWeb = true }
                if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 180) }
                if let page, !page.people.isEmpty && page.cards.isEmpty {
                    ForEach(page.people) { person in
                        Text(person.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                }
                if let page {
                    MovieGrid(cards: page.cards)
                }
            }
            .padding()
        }
        .navigationTitle("排行榜")
        .navigationDestination(for: MovieCard.self) { MovieDetailView(card: $0) }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showWeb) {
            if let pageURL { InAppWebView(url: pageURL, title: kind.title) }
        }
        .onChange(of: settings.locale) { _, _ in
            Task { await load() }
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        let url = SiteClient.shared.rankingURL(kind, locale: settings.locale)
        pageURL = url
        do {
            let result = try await SiteClient.shared.html(
                for: url,
                locale: settings.locale,
                ageCookie: settings.legalAgeCookie,
                allowWebViewFallback: true,
                expectCatalog: true
            )
            page = HTMLParser.ranking(from: result.html)
            source = result.source
            if (page?.cards.isEmpty ?? true) && (page?.people.isEmpty ?? true) {
                errorMessage = "没有解析到排行条目，可改用应用内网页。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
