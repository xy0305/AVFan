import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = HomeViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AVFanTheme.sectionSpacing) {
                FetchStatusBanner(source: model.source, error: model.errorMessage, webURL: model.pageURL) {
                    model.showWeb = true
                }
                if model.page.sections.isEmpty && model.loading {
                    ProgressView("正在加载首页…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
                ForEach(Array(model.page.sections.enumerated()), id: \.element.id) { index, section in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(section.title)
                                .font(AVFanTheme.sectionFont)
                            Spacer()
                            if let more = section.moreHref {
                                NavigationLink {
                                    CatalogListView(title: section.title, path: more)
                                } label: {
                                    Text("全部")
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                }
                                .liquidGlass(tint: nil, interactive: true)
                                .buttonStyle(.plain)
                            }
                        }
                        if index == 0, let featured = section.cards.first {
                            NavigationLink(value: featured) {
                                FeaturedHero(card: featured)
                            }
                            .buttonStyle(.plain)
                            MovieGrid(cards: Array(section.cards.dropFirst()))
                        } else {
                            MovieGrid(cards: section.cards)
                        }
                    }
                }
            }
            .padding(.horizontal, AdaptiveLayout.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: AdaptiveLayout.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(AVFanTheme.pageBackground)
        .navigationTitle("AVFan")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: MovieCard.self) { card in
            MovieDetailView(card: card)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.load(settings: settings, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.loading)
                .liquidGlassCircle(interactive: true)
            }
        }
        .task { await model.load(settings: settings, force: false) }
        .refreshable { await model.load(settings: settings, force: true) }
        .sheet(isPresented: $model.showWeb) {
            if let url = model.pageURL {
                InAppWebView(url: url, title: "首页")
            }
        }
        .onChange(of: settings.locale) { _, _ in
            Task { await model.load(settings: settings, force: true) }
        }
    }
}

struct FeaturedHero: View {
    let card: MovieCard

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CoverImage(url: card.coverURL)
                .aspectRatio(16/9, contentMode: .fill)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                if card.canPlay {
                    Text("可播放")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(AVFanTheme.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
                Text(card.displayCode)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(card.displayTitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: AVFanTheme.heroRadius, style: .continuous))
        .liquidCover(cornerRadius: AVFanTheme.heroRadius)
        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var page = HomePage(sections: [])
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var source: FetchSource?
    @Published var showWeb = false
    var pageURL: URL?

    func load(settings: AppSettings, force: Bool) async {
        if loading { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        let url = SiteClient.shared.homeURL(locale: settings.locale)
        pageURL = url
        if force { await SiteClient.shared.clearCache() }
        do {
            let result = try await SiteClient.shared.html(
                for: url,
                locale: settings.locale,
                ageCookie: settings.legalAgeCookie,
                allowWebViewFallback: true,
                expectCatalog: true
            )
            page = HTMLParser.home(from: result.html)
            source = result.source
            if page.sections.isEmpty {
                errorMessage = "首页没有解析到影片，可以改用应用内网页查看。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CatalogListView: View {
    let title: String
    let path: String
    @EnvironmentObject private var settings: AppSettings
    @State private var cards: [MovieCard] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var source: FetchSource?
    @State private var showWeb = false
    @State private var pageURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FetchStatusBanner(source: source, error: errorMessage, webURL: pageURL) { showWeb = true }
                if loading && cards.isEmpty { ProgressView().frame(maxWidth: .infinity, minHeight: 180) }
                MovieGrid(cards: cards)
            }
            .padding(.horizontal, AdaptiveLayout.horizontalPadding)
            .padding(.vertical, 12)
        }
        .background(AVFanTheme.pageBackground)
        .navigationTitle(title)
        .navigationDestination(for: MovieCard.self) { MovieDetailView(card: $0) }
        .task { await load() }
        .sheet(isPresented: $showWeb) {
            if let pageURL { InAppWebView(url: pageURL, title: title) }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let url = SiteClient.shared.catalogURL(path: path)
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
            if cards.isEmpty { showWeb = true }
        } catch {
            errorMessage = error.localizedDescription
            showWeb = true
        }
    }
}
