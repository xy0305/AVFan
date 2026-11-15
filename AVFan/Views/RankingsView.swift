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
            VStack(alignment: .leading, spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RankingKind.allCases) { item in
                            Button {
                                kind = item
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
                FetchStatusBanner(source: source, error: errorMessage, webURL: pageURL) { showWeb = true }
                if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 180) }
                if let page, !page.people.isEmpty && page.cards.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)], spacing: 14) {
                        ForEach(page.people) { person in
                            NavigationLink {
                                CatalogListView(title: person.name, path: person.href)
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
                        }
                    }
                }
                if let page {
                    MovieGrid(cards: page.cards)
                }
            }
            .padding(.horizontal, AdaptiveLayout.horizontalPadding)
            .padding(.vertical, 12)
        }
        .background(AVFanTheme.pageBackground)
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
