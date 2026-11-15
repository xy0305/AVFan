import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = HomeViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                FetchStatusBanner(source: model.source, error: model.errorMessage, webURL: model.pageURL) {
                    model.showWeb = true
                }
                if model.page.sections.isEmpty && model.loading {
                    ProgressView("正在加载首页…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
                ForEach(model.page.sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(section.title)
                                .font(.title3.bold())
                            Spacer()
                            if let more = section.moreHref {
                                NavigationLink("全部") {
                                    CatalogListView(title: section.title, path: more)
                                }
                                .font(.subheadline)
                            }
                        }
                        MovieGrid(cards: section.cards)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("AVFan")
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
            .padding()
        }
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
