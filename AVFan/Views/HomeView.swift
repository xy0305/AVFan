import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = HomeViewModel()
    @State private var scroll = HomeScrollState()
    @State private var goSearch = false
    @State private var openCard: MovieCard?
    @State private var openCatalog: CatalogDestination?
    @State private var showFilters = false

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
        .sheet(isPresented: $showFilters) {
            if let form = model.filterForm {
                FilterSheet(form: form, selections: model.selections) { newSelections in
                    model.selections = newSelections
                    Task { await model.applyFilters(settings: settings) }
                }
            }
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
                        ForEach(model.railSections) { section in
                            homeSection(section, metrics: m)
                                .padding(.top, 22)
                        }
                        homeListSection(m)
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
                        // Liquid-glass boxes (build 16, owner's call):
                        // the whole shortcut — icon and title — sits in
                        // one rounded glass card instead of a glass
                        // circle with a bare label under it.
                        VStack(spacing: 6) {
                            Image(systemName: shortcutIcon(item))
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(AVFanTheme.accent)
                            Text(item.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.primary)
                        }
                        .frame(width: m.quickItem + 10)
                        .padding(.vertical, 11)
                        .liquidGlassRect(cornerRadius: 18, interactive: true)
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

    /// The homepage's main list （最新磁链）: the full grid under the
    /// rails — auto-loads the next page on scroll, and the site
    /// homepage's own filter panel （影片类型 / 筛选 / 排序 / 布局）
    /// sits behind its 筛选 button (build 13).
    @ViewBuilder
    private func homeListSection(_ m: HomeMetrics) -> some View {
        if model.filterForm != nil || !model.listCards.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(model.listTitle)
                        .font(.system(size: 17, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if model.filterForm != nil {
                        Button {
                            GlassHaptic.tap()
                            showFilters = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(model.activeFilterCount > 0 ? "筛选 \(model.activeFilterCount)" : "筛选")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .contentShape(Rectangle().inset(by: -6))
                        }
                        .buttonStyle(HomePressStyle(scale: 0.94))
                        .accessibilityLabel("筛选")
                    }
                }
                .padding(.horizontal, m.padding)
                if model.listCards.isEmpty {
                    Text("没有符合条件的影片，换个筛选试试。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, m.padding)
                } else {
                    MovieGrid(cards: model.listCards, columns: model.layoutColumns,
                              onSelect: { openCard = $0 },
                              onReachEnd: { Task { await model.loadNext(settings: settings) } })
                        .padding(.horizontal, m.padding)
                }
                if model.listLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
            }
            .padding(.top, 22)
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
    /// Same hero geometry as the detail page (build 36, owner:
    /// home hero in the detail page's style):
    /// DetailPortraitGeometry.imageHeight.
    var heroHeight: CGFloat {
        min(width * 1.58, max(600, UIScreen.main.bounds.height * 0.8))
    }
    /// Build 332 / 54: light rails overlap the hero bottom by 32 pt.
    /// Build 53 temporarily raised this to 52 to hide the hard seam;
    /// 54 keeps 53's page-color dissolve and restores the 32 pt overlap.
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
            // Build 54: the overlap band belongs to the shortcuts / rails,
            // not the hero. Shrink the hit view and pin it to the top so
            // taps in the bottom overlap do not open the poster.
            .frame(width: metrics.width, height: max(0, metrics.heroHeight - HomeMetrics.heroContentOverlap))
            .frame(width: metrics.width, height: metrics.heroHeight, alignment: .top)
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

    /// Prefetch the next two hero covers' bytes (build 35) so a
    /// swipe lands on a local image instead of a download.
    private func warmNeighbours() {
        let upcoming = (1...2).compactMap { movies[safe: index + $0] }
        CoverPrefetch.warm(cards: upcoming)
    }

    private func page(by delta: Int, horizontal: Bool) {
        lastDragAt = Date()
        lastPageCommitAt = Date()
        let next = min(max(index + delta, 0), movies.count - 1)
        defer { warmNeighbours() }
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
            Rectangle().fill(Color.secondary.opacity(0.14))
            // The detail page's hero, literally (build 36): the
            // same CoverImage with the same parameters — anchored
            // fill for jackets and croppable covers, whole-image
            // for plain landscape originals — in the detail
            // geometry's frame. Builds 32/33's home-only
            // treatments (zoom fill, then complete-fit over a
            // blurred blow-up) are retired.
            CoverImage(url: card.coverURL, code: card.hqCoverCode,
                       anchorY: 0.18, allowUpscale: true, fitWholeImage: true,
                       usesOriginalCover: card.usesOriginalAvfanCover, registryPathID: card.pathID)
                .frame(width: metrics.width, height: metrics.heroHeight)
                .clipped()
                .allowsHitTesting(false)
            // Build 54: typography scrim only — peak around 0.35–0.45
            // in the text band, then fade to clear from 0.82 so the
            // overlap zone has no near-black bar. The detail page
            // keeps its own (darker) hero gradient.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.40),
                    .init(color: .black.opacity(0.18), location: 0.62),
                    .init(color: .black.opacity(0.42), location: 0.75),
                    .init(color: .black.opacity(0.40), location: 0.82),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
            // Build 53 page-color dissolve, kept in 54: starts around
            // 0.76 and is fully opaque at the bottom so the poster
            // melts into the same color as the rails.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.76),
                    .init(color: Color(.systemBackground).opacity(0.45), location: 0.90),
                    .init(color: Color(.systemBackground), location: 1),
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
                    // Build 53 darkened the dots for the fade zone.
                    // Build 54 does not retune them; accept after install.
                    .fill(Color.black.opacity(i == index ? 0.8 : 0.3))
                    .frame(width: i == index ? 18 : 6, height: 6)
                    .shadow(color: .white.opacity(0.35), radius: 1)
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

    /// The homepage main list and its filter state (build 13): the
    /// list auto-loads on scroll and is filtered by the homepage's own
    /// form; hero and rails always come from the unfiltered load.
    @Published var listCards: [MovieCard] = []
    @Published var listLoading = false
    @Published var filterForm: ListFilterForm?
    @Published var selections: [String: Set<String>] = [:]
    private var nextListPage: String?
    private var loadedListPage = 1
    private var activeListPath: String?

    var railSections: [HomeSection] { page.sections.filter { !$0.isMainList } }
    var listTitle: String { page.sections.first(where: \.isMainList)?.title ?? "最新磁链" }
    var layoutColumns: Int? { filterForm?.layoutColumns(selections: selections) }
    var activeFilterCount: Int {
        guard let form = filterForm else { return 0 }
        let defaults = form.defaultSelections
        return form.groups.filter { (selections[$0.name] ?? []) != (defaults[$0.name] ?? []) }.count
    }

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
            let html = result.html
            let homePath = url.absoluteString
            let parsed = await HTMLParser.detached {
                (page: HTMLParser.home(from: html),
                 form: HTMLParser.listFilterForm(in: html),
                 next: HTMLParser.autoNextPath(in: html, page: 1, path: homePath))
            }
            page = parsed.page
            listCards = parsed.page.listCards
            // Warm the disk cache with the home feed's covers
            // (build 35): rails and the main list then decode
            // from local bytes as they scroll into view.
            CoverPrefetch.warm(cards: parsed.page.allCards)
            filterForm = parsed.form
            selections = parsed.form?.defaultSelections ?? [:]
            activeListPath = nil
            loadedListPage = 1
            nextListPage = parsed.next
            source = result.source
            if page.sections.isEmpty {
                errorMessage = "首页没有解析到影片，可以改用应用内网页查看。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Auto-load the homepage list's next page (scrolling append). A
    /// failed fetch just ends paging; the loaded pages stay on screen.
    func loadNext(settings: AppSettings) async {
        guard !listLoading, !loading, let target = nextListPage else { return }
        listLoading = true
        defer { listLoading = false }
        let url = SiteClient.shared.catalogURL(path: target)
        let pageNo = loadedListPage + 1
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
                (cards: HTMLParser.resolvedCards(HTMLParser.home(from: html).listCards, fromPath: target),
                 next: HTMLParser.autoNextPath(in: html, page: pageNo, path: target))
            }
            let known = Set(listCards.map(\.pathID))
            let fresh = parsed.cards.filter { !known.contains($0.pathID) }
            listCards += fresh
            loadedListPage = pageNo
            nextListPage = fresh.isEmpty ? nil : parsed.next
        } catch {
            nextListPage = nil
        }
    }

    /// Apply the homepage filter panel: rebuild the homepage URL with
    /// the chosen values and reload the main list from page 1.
    func applyFilters(settings: AppSettings) async {
        guard let form = filterForm, !listLoading else { return }
        listLoading = true
        defer { listLoading = false }
        let base = SiteClient.shared.homeURL(locale: settings.locale).absoluteString
        let filtered = HTMLParser.applyingFilters(activeListPath ?? base, form: form, selections: selections)
        activeListPath = filtered
        let url = SiteClient.shared.catalogURL(path: filtered)
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
                (cards: HTMLParser.resolvedCards(HTMLParser.home(from: html).listCards, fromPath: filtered),
                 next: HTMLParser.autoNextPath(in: html, page: 1, path: filtered))
            }
            listCards = parsed.cards
            loadedListPage = 1
            nextListPage = parsed.next
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
    /// Auto-loading pages (build 13): scrolling appends the next page,
    /// currentPage counts the pages loaded so far. (Build 11's manual
    /// pager and build 12's watch-only auto-paging are both superseded:
    /// the owner asked for auto-loading everywhere.)
    @State private var currentPage = 1
    @State private var nextPage: String?
    /// Column count from the filter form's 布局 group, when chosen.
    private var layoutColumns: Int? { filterForm?.layoutColumns(selections: selections) }
    /// The path with any applied filters; starts as the given path.
    @State private var activePath = ""
    /// The site's own filter/sort form, parsed from the page (build 11).
    @State private var filterForm: ListFilterForm?
    @State private var selections: [String: Set<String>] = [:]
    @State private var showFilters = false
    /// This list is always a PUSHED view, so it hosts its own detail
    /// navigation as item-based state (the pattern HomeView uses for its
    /// hero, which pops correctly). Value links resolved by a tab-root
    /// registration popped straight to the root, skipping this list.
    @State private var openCard: MovieCard?
    /// Bumped after a filter reload so the list scrolls back to its top
    /// (the ScrollViewReader's proxy is not in scope inside the sheet).
    @State private var topScrollTick = 0
    /// List pages: the 收藏 wiring for the list itself, parsed from
    /// the page (build 25 — the site shows a 收藏 button on list
    /// pages; collecting syncs to the account like cast collects).
    @State private var collectState: ListCollectState?
    @State private var collectedOverride: Bool?
    @State private var collectBusy = false
    @State private var showLogin = false
    @State private var toast: String?
    private var isListPage: Bool { path.contains("/lists/") }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    FetchStatusBanner(source: source, error: errorMessage, webURL: pageURL) { showWeb = true }
                        .id("catalogTop")
                    if isListPage, let collectState {
                        let isOn = collectedOverride ?? collectState.isCollected
                        Button {
                            Task { await toggleCollect(collectState) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isOn ? "bookmark.fill" : "bookmark")
                                Text(isOn ? "已收藏" : "收藏清单")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(isOn ? Color(.secondarySystemBackground) : AVFanTheme.accent,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(isOn ? Color.primary : Color.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(collectBusy)
                    }
                    if loading && cards.isEmpty { ProgressView().frame(maxWidth: .infinity, minHeight: 180) }
                    MovieGrid(cards: cards, columns: layoutColumns, onSelect: { openCard = $0 }, onReachEnd: { Task { await loadNext() } })
                    if loading && !cards.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, AdaptiveLayout.horizontalPadding)
                .padding(.vertical, 12)
            }
            .onChange(of: topScrollTick) { _, _ in
                withAnimation(.none) { proxy.scrollTo("catalogTop", anchor: .top) }
            }
        }
        .background(AVFanTheme.pageBackground)
        .navigationTitle(title)
        .navigationDestination(item: $openCard) { MovieDetailView(card: $0) }
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
        .task { await load() }
        .sheet(isPresented: $showWeb) {
            if let pageURL { InAppWebView(url: pageURL, title: title) }
        }
        .sheet(isPresented: $showLogin, onDismiss: {
            Task { await loadPage(activePath.isEmpty ? path : activePath, page: 1) }
        }) { SiteLoginView() }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.82), in: Capsule())
                    .foregroundStyle(.white)
                    // Above the floating tab bar (build 37).
                    .padding(.bottom, 108)
            }
        }
        .sheet(isPresented: $showFilters) {
            if let filterForm {
                FilterSheet(form: filterForm, selections: selections) { newSelections in
                    selections = newSelections
                    let filtered = HTMLParser.applyingFilters(
                        activePath.isEmpty ? path : activePath,
                        form: filterForm, selections: newSelections)
                    activePath = filtered
                    Task {
                        await loadPage(filtered, page: 1)
                        topScrollTick += 1
                    }
                }
            }
        }
    }

    private func load() async {
        let start = activePath.isEmpty ? path : activePath
        let page = Int(HTMLParser.firstMatch("[?&]page=(\\d+)", in: start) ?? "") ?? 1
        await loadPage(start, page: page)
    }

    private func loadNext() async {
        guard !loading, let target = nextPage else { return }
        await loadPage(target, page: currentPage + 1, append: true)
    }

    /// Collect / uncollect this list on the account (the site list
    /// page's own 收藏 button contract). Guest pages carry no
    /// wiring — like the site, tapping asks for login first.
    private func toggleCollect(_ state: ListCollectState) async {
        let isOn = collectedOverride ?? state.isCollected
        if !state.signedIn {
            showLogin = true
            return
        }
        guard !collectBusy else { return }
        collectBusy = true
        defer { collectBusy = false }
        let outcome: LibrarySync.Outcome
        if isOn {
            guard let url = state.uncollectURL else { showToast("页面没有给出取消收藏的接线"); return }
            outcome = await LibrarySync.modelUndo(url: url, csrf: state.csrfToken)
        } else {
            guard let url = state.collectURL else { showToast("页面没有给出收藏的接线"); return }
            outcome = await LibrarySync.modelAction(url: url, model: state.modelName, modelID: state.modelID, csrf: state.csrfToken)
        }
        if outcome.success {
            // Verify against the server before claiming anything
            // (build 34): reload the list page and adopt ITS
            // collect state. A write the account did not record
            // must not toast success or flip the button.
            let target = !isOn
            await loadPage(activePath.isEmpty ? path : activePath, page: 1, bypassCache: true)
            if let now = collectState, now.isCollected == target {
                showToast(target ? "已收藏到账号" : "已取消收藏")
            } else {
                showToast("未同步到账号，请稍后再试")
            }
        } else if outcome.needsLogin {
            showLogin = true
        } else {
            showToast(outcome.message ?? "操作失败，请稍后再试")
        }
    }

    private func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == message { toast = nil }
        }
    }

    private func loadPage(_ fetchPath: String, page: Int, append: Bool = false, bypassCache: Bool = false) async {
        loading = true
        defer { loading = false }
        let url = SiteClient.shared.catalogURL(path: fetchPath)
        pageURL = url
        do {
            let result = try await SiteClient.shared.html(
                for: url,
                locale: settings.locale,
                ageCookie: settings.legalAgeCookie,
                allowWebViewFallback: true,
                expectCatalog: true,
                bypassCache: bypassCache
            )
            let html = result.html
            let parsed = await HTMLParser.detached {
                (cards: HTMLParser.movieCards(in: html, fromPath: fetchPath),
                 form: HTMLParser.listFilterForm(in: html),
                 next: HTMLParser.autoNextPath(in: html, page: page, path: fetchPath),
                 collect: HTMLParser.listCollectState(in: html))
            }
            CoverPrefetch.warm(cards: parsed.cards)
            if append {
                let known = Set(cards.map(\.pathID))
                let fresh = parsed.cards.filter { !known.contains($0.pathID) }
                cards += fresh
                nextPage = fresh.isEmpty ? nil : parsed.next
            } else {
                cards = parsed.cards
                nextPage = parsed.next
                if isListPage {
                    collectState = parsed.collect
                    collectedOverride = nil
                }
            }
            currentPage = page
            if filterForm == nil, let form = parsed.form {
                filterForm = form
                selections = form.defaultSelections
            }
            source = result.source
            errorMessage = nil
            if cards.isEmpty { showWeb = true }
        } catch {
            if append {
                // A failed auto-append just ends paging; the pages
                // already on screen stay usable, no error banner.
                nextPage = nil
            } else {
                errorMessage = error.localizedDescription
                if cards.isEmpty { showWeb = true }
            }
        }
    }
}

/// The site's filter/sort panel as a sheet (build 11): checkbox groups
/// toggle freely (the group's 全部 option is mutually exclusive with the
/// rest, as on the site), radio groups pick one. Edits a draft; 应用
/// hands the committed selections back.
struct FilterSheet: View {
    let form: ListFilterForm
    let onApply: ([String: Set<String>]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [String: Set<String>]

    init(form: ListFilterForm, selections: [String: Set<String>], onApply: @escaping ([String: Set<String>]) -> Void) {
        self.form = form
        self.onApply = onApply
        _draft = State(initialValue: selections)
    }

    @Environment(\.horizontalSizeClass) private var sizeClass

    /// The toolbar form carries two layout groups (desktop 3–6 列 and
    /// mobile 1–2 列）; like the site, show only the one for this
    /// device class.
    private var shownGroups: [ListFilterGroup] {
        let layouts = form.groups.filter(\.isLayoutGroup)
        guard layouts.count > 1 else { return form.groups }
        func maxColumns(_ group: ListFilterGroup) -> Int {
            group.options.map { Int($0.label.filter(\.isNumber)) ?? 0 }.max() ?? 0
        }
        let mobile = layouts.first { maxColumns($0) <= 2 }
        let desktop = layouts.first { maxColumns($0) >= 3 }
        let keep = sizeClass == .regular ? (desktop ?? mobile) : (mobile ?? desktop)
        return form.groups.filter { !$0.isLayoutGroup || $0.name == keep?.name }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(shownGroups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.secondary)
                            FlowLayout(spacing: 8) {
                                ForEach(group.options) { option in
                                    chip(group: group, option: option)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(AVFanTheme.pageBackground)
            .navigationTitle("筛选 · 排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        onApply(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func chip(group: ListFilterGroup, option: ListFilterOption) -> some View {
        let selected = (draft[group.name] ?? []).contains(option.value)
        return Button {
            toggle(group: group, option: option)
        } label: {
            Text(option.label)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(selected ? AVFanTheme.accent : Color.primary.opacity(0.07), in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func toggle(group: ListFilterGroup, option: ListFilterOption) {
        var set = draft[group.name] ?? []
        if group.isRadio {
            set = [option.value]
        } else if set.contains(option.value) {
            set.remove(option.value)
        } else {
            let isAll = option.value.isEmpty || option.label.hasPrefix("全部")
            if isAll {
                set = [option.value]
            } else {
                set = set.filter { value in
                    guard let other = group.options.first(where: { $0.value == value }) else { return true }
                    return !(other.value.isEmpty || other.label.hasPrefix("全部"))
                }
                set.insert(option.value)
            }
        }
        draft[group.name] = set
    }
}
