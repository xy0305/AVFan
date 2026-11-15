import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = HomeViewModel()
    @State private var scroll = HomeScrollState()
    @State private var goSearch = false
    @State private var openCard: MovieCard?
    @State private var openCatalog: CatalogDestination?

    var body: some View {
        GeometryReader { proxy in
            let metrics = HomeMetrics(width: proxy.size.width, safeTop: proxy.safeAreaInsets.top)
            homeRoot(metrics)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $goSearch) { SearchView() }
        .navigationDestination(item: $openCard) { MovieDetailView(card: $0) }
        .navigationDestination(item: $openCatalog) { dest in
            CatalogListView(title: dest.title, path: dest.path)
        }
        .task { await model.load(settings: settings, force: false) }
        .onChange(of: settings.locale) { _, _ in
            Task { await model.load(settings: settings, force: true) }
        }
        .sheet(isPresented: $model.showWeb) {
            if let url = model.pageURL { InAppWebView(url: url, title: "首页") }
        }
    }

    private func homeRoot(_ m: HomeMetrics) -> some View {
        ZStack(alignment: .top) {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroSection(m)
                    VStack(alignment: .leading, spacing: 0) {
                        quickActionRow(m)
                            .padding(.top, 18)
                        FetchStatusBanner(source: model.source, error: model.errorMessage, webURL: model.pageURL) {
                            model.showWeb = true
                        }
                        .padding(.horizontal, m.padding)
                        .padding(.top, 16)
                        ForEach(model.page.sections) { section in
                            homeSection(section, metrics: m)
                                .padding(.top, 22)
                        }
                    }
                    .background(Color(.systemBackground))
                    .frame(maxWidth: m.contentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.top, -HomeMetrics.heroContentOverlap)
                    .padding(.bottom, 28)
                }
                .background(alignment: .top) {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: HomeScrollOffsetKey.self,
                            value: -proxy.frame(in: .named(HomeScrollState.space)).minY
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(.named(HomeScrollState.space))
            .onPreferenceChange(HomeScrollOffsetKey.self) { scroll.update($0) }
            .ignoresSafeArea(.container, edges: .top)
            .refreshable { await model.load(settings: settings, force: true) }

            HomeSearchButton(scroll: scroll) {
                GlassHaptic.tap()
                goSearch = true
            }
            .padding(.top, 6)
            .padding(.trailing, m.padding)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(Color.primary)
    }

    @ViewBuilder
    private func heroSection(_ m: HomeMetrics) -> some View {
        let movies = model.heroCards
        Group {
            if movies.isEmpty {
                ZStack {
                    Color(.systemGray5)
                    if model.loading {
                        ProgressView()
                    }
                }
            } else {
                HomeHeroCarousel(movies: movies, metrics: m, scrollOffset: { scroll.raw }, onOpen: { openCard = $0 })
            }
        }
        .frame(width: m.width, height: m.heroHeight)
        .clipped()
    }

    private func quickActionRow(_ m: HomeMetrics) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: m.quickSpacing) {
                ForEach(CatalogShortcut.allCases) { item in
                    Button {
                        GlassHaptic.tap()
                        openCatalog = CatalogDestination(title: item.title, path: item.path(locale: settings.locale))
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: shortcutIcon(item))
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: m.quickCircle, height: m.quickCircle)
                                .homeGlass(in: Circle())
                                .foregroundStyle(Color.primary)
                            Text(item.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.secondary)
                        }
                        .frame(width: m.quickItem)
                    }
                    .buttonStyle(HomePressStyle(scale: 0.92))
                    .accessibilityLabel(item.title)
                }
            }
            .padding(.horizontal, m.padding)
        }
    }

    private func shortcutIcon(_ item: CatalogShortcut) -> String {
        switch item {
        case .censored: return "film"
        case .uncensored: return "film.stack"
        case .western: return "globe.europe.africa"
        case .anime: return "sparkles.tv"
        case .fc2: return "person.crop.rectangle"
        case .watch: return "play.rectangle"
        }
    }

    private func homeSection(_ section: HomeSection, metrics m: HomeMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeRailHeader(title: section.title, padding: m.padding, more: section.moreHref == nil ? nil : {
                if let more = section.moreHref {
                    openCatalog = CatalogDestination(title: section.title, path: more)
                }
            })
            HomePosterGrid(cards: section.cards, metrics: m) { openCard = $0 }
        }
    }
}

struct CatalogDestination: Identifiable, Hashable {
    var title: String
    var path: String
    var id: String { title + "|" + path }
}

// MARK: - Home chrome

enum HomeTheme {
    static let accent = Color(red: 1.0, green: 138.0 / 255.0, blue: 61.0 / 255.0)
    static let glassFill = Color(red: 20.0 / 255.0, green: 16.0 / 255.0, blue: 13.0 / 255.0).opacity(0.32)
}

struct HomeMetrics {
    let width: CGFloat
    let safeTop: CGFloat

    var isPadWidth: Bool { width >= 768 }
    var padding: CGFloat { isPadWidth ? 24 : (width < 380 ? 16 : 20) }
    var heroHeight: CGFloat { isPadWidth ? 600 : min(max(width * 1.15, 430), 560) }
    /// Build 332: light rails overlap the hero bottom by 32 pt.
    static let heroContentOverlap: CGFloat = 32
    var contentWidth: CGFloat { min(width, AdaptiveLayout.contentMaxWidth) }
    var cardWidth: CGFloat {
        let usable = contentWidth - 2 * padding - 24
        return max(usable / 3, 1)
    }
    var cardHeight: CGFloat { (cardWidth * 1.5).rounded() }
    var quickItem: CGFloat { width <= 375 ? 56 : 60 }
    var quickCircle: CGFloat { width <= 375 ? 48 : 52 }
    var quickSpacing: CGFloat {
        if isPadWidth { return 22 }
        let free = contentWidth - padding - quickItem * 5.4
        return max(8, (free / 5).rounded(.down))
    }
}

extension View {
    func homeGlass<S: InsettableShape>(in shape: S) -> some View {
        background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(HomeTheme.glassFill)
                shape.fill(HomeTheme.accent.opacity(0.10))
            }
            .environment(\.colorScheme, .dark)
        }
        .overlay {
            shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
        }
    }
}

struct HomePressStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    var spring = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(spring ? .spring(response: 0.28, dampingFraction: 0.78) : .easeOut(duration: 0.12),
                       value: configuration.isPressed)
    }
}

struct HomeScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

final class HomeScrollState: ObservableObject {
    static let space = "avfan.home.scroll"
    @Published var up: CGFloat = 0
    var raw: CGFloat = 0
    func update(_ value: CGFloat) {
        raw = value
        let next = max(0, value)
        if abs(up - next) > 0.5 { up = next }
    }
}

private struct HomeSearchButton: View {
    @ObservedObject var scroll: HomeScrollState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 44, height: 44)
                .liquidGlassCircle()
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                .contentShape(Circle())
        }
        .buttonStyle(HomePressStyle(scale: 0.92))
        .opacity(1 - 0.22 * min(scroll.up, 120) / 120)
        .accessibilityLabel("搜索")
        .accessibilityIdentifier("home-search")
    }
}

private struct HomeRailHeader: View {
    let title: String
    let padding: CGFloat
    var more: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let more {
                Button {
                    GlassHaptic.tap()
                    more()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.06), in: Circle())
                        .contentShape(Rectangle().inset(by: -9))
                }
                .buttonStyle(HomePressStyle(scale: 0.9))
                .accessibilityLabel("\(title) 全部")
            }
        }
        .padding(.horizontal, padding)
        .frame(minHeight: 26)
    }
}

private struct HomePosterGrid: View {
    let cards: [MovieCard]
    let metrics: HomeMetrics
    let open: (MovieCard) -> Void
    private static let columns = 3
    private static let cap = 9

    var body: some View {
        let items = Array(cards.prefix(Self.cap))
        let cols = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12), count: Self.columns)
        LazyVGrid(columns: cols, spacing: 16) {
            ForEach(items) { card in
                Button { open(card) } label: {
                    MoviePosterCard(card: card)
                }
                .buttonStyle(HomePressStyle(scale: 0.97, spring: true))
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, metrics.padding)
    }
}

// MARK: - Hero

private struct HomeHeroCarousel: View {
    let movies: [MovieCard]
    let metrics: HomeMetrics
    let scrollOffset: () -> CGFloat
    let onOpen: (MovieCard) -> Void

    @State private var index = 0
    @State private var dragX: CGFloat = 0
    @State private var dragY: CGFloat = 0
    @State private var lastDragAt = Date.distantPast
    @State private var lastPageCommitAt = Date.distantPast

    var body: some View {
        let current = movies[safe: index] ?? movies.first
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(movies.enumerated()), id: \.element.id) { idx, card in
                if shouldRender(idx) {
                    HomeHeroPage(card: card, metrics: metrics, active: idx == index)
                        .offset(x: offsetX(for: idx), y: offsetY(for: idx))
                        .zIndex(idx == index ? 2 : 1)
                        .opacity(opacity(for: idx))
                }
            }

            HeroSwipeOverlay(
                scrollOffset: scrollOffset,
                index: { index },
                count: { movies.count },
                onTrackHorizontal: { dragX = $0 },
                onTrackVertical: { dragY = $0 },
                onPageHorizontal: { delta in page(by: delta, horizontal: true) },
                onPageVertical: { delta in page(by: delta, horizontal: false) },
                onSpringHorizontal: {
                    withAnimation(.spring(response: HeroSwipePolicy.pageSpringResponse,
                                          dampingFraction: HeroSwipePolicy.pageSpringDamping)) { dragX = 0 }
                },
                onSpringVertical: {
                    withAnimation(.spring(response: HeroSwipePolicy.pageSpringResponse,
                                          dampingFraction: HeroSwipePolicy.pageSpringDamping)) { dragY = 0 }
                },
                onTouch: { _ in },
                onTap: {
                    guard Date().timeIntervalSince(lastDragAt) > HeroTapPolicy.trailingSuppress else { return }
                    if let current { onOpen(current) }
                },
                lastPageCommitAt: { lastPageCommitAt }
            )
            .zIndex(10)

            VStack(alignment: .leading, spacing: 10) {
                if let current {
                    if current.canPlay {
                        Text("可播放")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(AVFanTheme.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Text(current.displayCode)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 8)
                    Text(current.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.3), radius: 6)
                }
                HomeHeroDots(count: movies.count, index: min(index, max(movies.count - 1, 0)))
            }
            .padding(.horizontal, metrics.padding)
            .padding(.bottom, HomeMetrics.heroContentOverlap + 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
        }
        .clipped()
    }

    private func shouldRender(_ idx: Int) -> Bool {
        abs(idx - index) <= 1 || (dragX != 0 && abs(idx - index) <= 2) || (dragY != 0 && abs(idx - index) <= 2)
    }

    private func offsetX(for idx: Int) -> CGFloat {
        CGFloat(idx - index) * metrics.width + (index == idx || abs(idx - index) == 1 ? dragX : 0)
    }

    private func offsetY(for idx: Int) -> CGFloat {
        // Horizontal paging uses offsetX; vertical paging slides the current card with rubber-banded dragY.
        if dragX != 0 { return 0 }
        if idx == index { return dragY }
        if dragY < 0, idx == index + 1 { return metrics.heroHeight + dragY }
        if dragY > 0, idx == index - 1 { return -metrics.heroHeight + dragY }
        return CGFloat(idx - index) * metrics.heroHeight
    }

    private func opacity(for idx: Int) -> Double {
        idx == index ? 1 : (abs(idx - index) == 1 && (dragX != 0 || dragY != 0) ? 1 : 0)
    }

    private func page(by delta: Int, horizontal: Bool) {
        lastDragAt = Date()
        lastPageCommitAt = Date()
        let next = min(max(index + delta, 0), movies.count - 1)
        withAnimation(.spring(response: HeroSwipePolicy.pageSpringResponse,
                              dampingFraction: HeroSwipePolicy.pageSpringDamping)) {
            index = next
            dragX = 0
            dragY = 0
        }
    }
}

private struct HomeHeroPage: View {
    let card: MovieCard
    let metrics: HomeMetrics
    var active: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            CoverImage(url: card.coverURL, anchorY: 0.22, allowUpscale: true)
                .frame(width: metrics.width, height: metrics.heroHeight)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.42),
                    .init(color: .black.opacity(0.28), location: 0.62),
                    .init(color: .black.opacity(0.72), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .frame(width: metrics.width, height: metrics.heroHeight)
        .clipped()
    }
}

private struct HomeHeroDots: View {
    let count: Int
    let index: Int

    var body: some View {
        let visible = min(count, 9)
        let start = count <= 9 ? 0 : min(max(index - 4, 0), count - 9)
        HStack(spacing: 5) {
            ForEach(start..<(start + visible), id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i == index ? 1 : 0.45))
                    .frame(width: i == index ? 18 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: index)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

// MARK: - Model

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var page = HomePage(sections: [])
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var source: FetchSource?
    @Published var showWeb = false
    var pageURL: URL?

    var heroCards: [MovieCard] {
        let all = page.allCards
        if all.isEmpty { return [] }
        return Array(all.prefix(12))
    }

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
