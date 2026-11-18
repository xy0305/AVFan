import SwiftUI
import UIKit
import AVFoundation
import AVKit
import Combine
import WebKit

/// Navigation target for the detail page's also-starred /
/// related-works strips (build 47, LOCK-1.3-build47 B): the tapped
/// card plus the cover snapshot the strip cell itself was
/// displaying at tap time. This path never consults
/// DisplayedCoverRegistry — the snapshot travels with the tap.
struct StripTarget: Identifiable, Hashable {
    let card: MovieCard
    let snapshot: DisplayedCoverSnapshot?
    var id: String { card.pathID }
}

/// One cell of the also-starred / related-works strips (build 47,
/// LOCK-1.3-build47 B). The cell keeps the cover snapshot IT
/// displayed — written by CoverImage's onDisplayed callback when
/// a bitmap actually lands on this cell — and a tap hands that
/// snapshot, frozen, to the detail page along with the card. The
/// shared registry plays no part on this path.
private struct FilmographyStripCell: View {
    let card: MovieCard
    let onOpen: (StripTarget) -> Void
    @State private var displayed: DisplayedCoverSnapshot?

    var body: some View {
        Button {
            onOpen(StripTarget(card: card, snapshot: displayed ?? Self.unlandedSnapshot(for: card)))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverImage(
                    url: card.coverURL,
                    code: card.hqCoverCode,
                    usesOriginalCover: card.usesOriginalAvfanCover,
                    probeDisplaysWinner: false,
                    onDisplayed: { displayed = $0 }
                )
                    .frame(width: 110, height: 165)
                    .clipped()
                    .contentShape(Rectangle())
                    .liquidCover(cornerRadius: AVFanTheme.cardRadius)
                Text(card.displayCode)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: 110, alignment: .leading)
            }
            .frame(width: 110, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 110)
        .contentShape(Rectangle())
        // Front-crop overflow is clipped visually but not for
        // hits; without a tight contentShape, the next tile's
        // jacket (later in the HStack, therefore on top) steals
        // taps on this tile (build 49).
    }

    /// Nothing has landed on this cell yet: the snapshot is the
    /// card's own cover with the cell's own presentation — front
    /// window at the anchor the cell renders with (it passes no
    /// anchorY, so CoverImage's default 0.22) — and nothing else
    /// (LOCK-1.3-build47 B11).
    private static func unlandedSnapshot(for card: MovieCard) -> DisplayedCoverSnapshot? {
        card.coverURL.map { DisplayedCoverSnapshot(url: $0, wholeImage: card.usesOriginalAvfanCover, anchorY: 0.22) }
    }
}

struct MovieDetailView: View {
    let card: MovieCard
    /// True when this view was opened from an also-starred /
    /// related-works strip with an explicit snapshot (build 47).
    /// That path never consults DisplayedCoverRegistry.
    let isStripEntry: Bool

    init(card: MovieCard) {
        self.card = card
        self.isStripEntry = false
        let pin: DisplayedCoverSnapshot?
        if let hit = DisplayedCoverRegistry.shared.snapshot(pathID: card.pathID, code: card.code) {
            pin = hit
        } else if let cover = card.coverURL, !cover.isEmpty {
            pin = DisplayedCoverSnapshot(url: cover, wholeImage: card.usesOriginalAvfanCover, anchorY: 0.18)
        } else {
            pin = nil
        }
        // Freeze the init-time pin in @State so a destination
        // rebuild cannot re-read the registry mid-visit.
        _frozenPin = State(initialValue: pin)
    }

    /// Strip entry (build 47/48, LOCK-1.3-build47 B12/B13): the
    /// registry is never consulted on this path — not by pathID,
    /// not by code. The tapped cell's snapshot is frozen into
    /// @State here, once, and the whole visit honors only it.
    init(stripTarget: StripTarget) {
        self.card = stripTarget.card
        self.isStripEntry = true
        _frozenPin = State(initialValue: stripTarget.snapshot)
    }

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var pan115: Pan115Settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.availableLayoutSize) private var layoutSize
    @StateObject private var model = MovieDetailViewModel()
    @ScaledMetric(relativeTo: .largeTitle) private var portraitTitleSize: CGFloat = 34
    @State private var showWeb = false
    @State private var showPlayer = false
    @State private var showWatchPlayer = false
    @State private var showMagnetList = false
    @State private var activeMagnet: MagnetItem?
    @State private var activeWatch: WatchStream?
    @State private var startFromBeginning = false
    @State private var toast: String?
    @ObservedObject private var externalSettings = ExternalLibrarySettings.shared
    /// External-database links for this movie (build 38).
    @State private var magnetsExpanded = false
    @State private var externalExpanded = false
    @State private var externalMagnets: [MagnetItem] = []
    @State private var externalStatus: String?
    @State private var externalCode: String?
    @State private var resume115: PlaybackResumeEntry?
    @State private var resumeOnline: PlaybackResumeEntry?
    @State private var showListPicker = false
    @State private var showLogin = false
    @State private var reviewOverride: ReviewStatus?
    @State private var removeURLOverride: String?
    @State private var syncBusy = false
    @State private var playTrailer = false
    @State private var stillBox: IndexBox?
    @State private var mediaExpanded = false
    @State private var sourceOverride: PlaySource?
    /// Detail extras (build 24): the page's comments and related
    /// lists, lazy-loaded from the fragments the page itself declares,
    /// auto-appending as the user scrolls — plus card navigation for
    /// the also-starred / related-works strips (build 47: strips
    /// navigate via StripTarget, carrying the tapped cell's own
    /// displayed-cover snapshot).
    @State private var stripTarget: StripTarget?
    /// Cover pin frozen at creation for the whole stay. Strip
    /// entries use the cell snapshot; other entries use the
    /// registry (or the card cover) captured once at init.
    @State private var frozenPin: DisplayedCoverSnapshot?
    @State private var comments: [MovieComment] = []
    @State private var commentsFallback: String?
    /// Cursor for the comments load-more (sort_by/last_value/last_id),
    /// the site's own scheme — not page numbers (build 25).
    @State private var commentsCursor: (sortBy: String, lastValue: String, lastId: String)?
    @State private var commentsBusy = false
    @State private var commentsLoaded = false
    @State private var commentsLoginNote = false
    /// The fragment came back as a login gate even after one
    /// session refresh (lock 1.3): prompt for login instead of
    /// showing guest content or garbage.
    @State private var commentsNeedLogin = false
    @State private var relatedRows: [RelatedListRow] = []
    @State private var listsNext: Int?
    @State private var listsBusy = false
    @State private var listsLoaded = false
    @State private var listsNeedLogin = false
    @State private var listsFailed = false
    /// Identity of the lists load (card.pathID + relatedListsURL),
    /// build 47: the first load is driven by the parent view after
    /// the detail lands; a changed identity resets the section.
    @State private var listsIdentity: String?
    /// Measured height of the hero's text stack (title block + controls).
    /// A long title with its expand button outgrows the slot the geometry
    /// planned, pushing the play row past the artwork and the gradient —
    /// the pills' lower halves landed on the light sheet and looked cut.
    /// The gradient now stretches to the measured content height.


    private enum PlaySource { case online, pan115 }

    /// Default playback source: 115 (owner's call, build 5 — this reverses
    /// build 4's online-first default). Online stays one tap away via the
    /// source chips whenever the page offered a stream, and play115() still
    /// falls back to a stream when 115 is not configured. The play pill, the
    /// chips and the resource-card order all follow this value.
    private var effectiveSource: PlaySource {
        if let sourceOverride { return sourceOverride }
        return .pan115
    }

    private var activeResume: PlaybackResumeEntry? {
        effectiveSource == .online ? resumeOnline : resume115
    }

    private var display: MovieDetail {
        model.detail ?? MovieDetail(
            pathID: card.pathID,
            pageURL: HTMLParser.absoluteURL(card.href),
            code: card.code,
            title: card.titleWithoutCodePrefix,
            coverURL: card.coverURL,
            summary: nil,
            releaseDate: card.date,
            duration: nil,
            rating: nil,
            ratingCount: nil,
            makers: [],
            publishers: [],
            directors: [],
            series: [],
            casts: [],
            tags: [],
            magnets: [],
            watchStreams: [],
            catalogType: card.catalogType
        )
    }

    /// Layout size for the hero geometry, frozen at first
    /// measure (build 40). The live GeometryReader size jitters
    /// by tens of points while a drag that starts on the cover
    /// scrolls (safe-area re-measurement on iOS 27), and the
    /// hero height derives from it — the cover visibly flashed
    /// up and down mid-scroll. Only a real resize (rotation,
    /// split view) may re-measure.
    @State private var pageSize: CGSize?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                detailContent(display, width: (pageSize ?? proxy.size).width, height: (pageSize ?? proxy.size).height)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(.container, edges: .top)
            .background(AVFanTheme.pageBackground)
            .onAppear {
                if pageSize == nil { pageSize = proxy.size }
            }
            .onChange(of: proxy.size) { _, newSize in
                guard let current = pageSize else {
                    pageSize = newSize
                    return
                }
                if abs(newSize.width - current.width) > 120 || abs(newSize.height - current.height) > 120 {
                    pageSize = newSize
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: card.pathID) {
            await model.load(card: card, settings: settings)
            refreshResume()
            // Related lists' primary load path (build 47): driven
            // from here, once the detail has landed — not by the
            // section's .task inside the LazyVStack.
            if let detail = model.detail { ensureListsLoaded(detail) }
        }
        .onChange(of: session.isSignedIn) { _, signedIn in
            if signedIn {
                // Reload the detail for its library state, but
                // only reset sections that are actually gated or
                // not yet loaded. The session signal can flap
                // false -> true mid-browse (a guest-parsed fetch
                // followed by the self-check refetch), and the old
                // unconditional clear wiped already-paged content:
                // related lists loaded via 加载更多 visibly
                // collapsed back to page one (build 32).
                if commentsNeedLogin || !commentsLoaded {
                    commentsLoaded = false
                    comments = []
                    commentsNeedLogin = false
                }
                // While a lists load is in flight, skip the reset
                // entirely (build 47): clearing state here used to
                // ride along with the reload and cancel/poison the
                // very load the section was waiting on.
                if !listsBusy, listsNeedLogin || listsFailed || !listsLoaded {
                    listsLoaded = false
                    relatedRows = []
                    listsNeedLogin = false
                    listsFailed = false
                }
                Task {
                    await model.load(card: card, settings: settings)
                    refreshResume()
                    if let detail = model.detail { ensureListsLoaded(detail) }
                }
            }
        }
        .navigationDestination(item: $stripTarget) { MovieDetailView(stripTarget: $0) }
        .sheet(isPresented: $showWeb) {
            if let url = model.pageURL { InAppWebView(url: url, title: card.displayCode) }
        }
        .sheet(isPresented: $showMagnetList) {
            NavigationStack {
                ScrollView { magnetsSection(display).padding(16) }
                    .background(AVFanTheme.pageBackground)
                    .navigationTitle("磁力列表")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { showMagnetList = false } } }
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let detail = model.detail {
                Pan115PlayerView(
                    detail: detail,
                    magnetURL: activeMagnet?.url,
                    magnets: detail.magnets,
                    startFromBeginning: startFromBeginning
                )
            }
        }
        .fullScreenCover(isPresented: $showWatchPlayer) {
            if let stream = activeWatch, let url = URL(string: stream.url) {
                WatchOnlinePlayerView(
                    title: model.detail?.displayCode ?? card.displayCode,
                    url: url,
                    resumeKey: PlaybackResumeKey.make(number: model.detail?.displayCode ?? card.displayCode, source: "avfan"),
                    startFromBeginning: startFromBeginning
                )
            }
        }
        .onChange(of: showPlayer) { _, open in if !open { refreshResume() } }
        .onChange(of: showWatchPlayer) { _, open in if !open { refreshResume() } }
        .fullScreenCover(isPresented: $playTrailer) {
            TrailerPlayerView(
                url: display.trailerURL.flatMap { URL(string: $0) },
                pageURL: model.pageURL,
                title: (display.displayCode) + " 预告片",
                poster: display.coverURL ?? card.coverURL
            )
        }
        .sheet(isPresented: $showListPicker) {
            if let library = display.library {
                ListPickerSheet(state: library)
            }
        }
        .sheet(isPresented: $showLogin) {
            SiteLoginView()
        }
        .fullScreenCover(item: $stillBox) { box in
            StillViewer(images: galleryImages(display), index: box.value)
        }
        .overlay(alignment: .topLeading) { detailChrome }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .liquidGlass()
                    .padding()
                    // Clear the floating tab bar (build 37).
                    .padding(.bottom, 92)
            }
        }
    }

    private var detailChrome: some View {
        HStack {
            chromeButton("chevron.left") { dismiss() }
            Spacer()
            chromeButton(bookmarks.contains(display.pathID) ? "bookmark.fill" : "bookmark") {
                if let detail = model.detail { bookmarks.toggle(detail) }
            }
            ShareLink(item: shareText) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .background(.black.opacity(0.30), in: Circle())
                    .liquidGlassCircle(interactive: false)
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    // Mirrors AVDB's working detail chrome button: 44 pt hit target, explicit
    // content shape, and NON-interactive glass. The interactive glass effect
    // installs its own press handling inside the label and can swallow the
    // button's tap on iOS 26/27 — with interactive: true the back button
    // rendered fine but never fired.
    private func chromeButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            GlassHaptic.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .background(.black.opacity(0.30), in: Circle())
                .liquidGlassCircle(interactive: false)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }

    private func detailContent(_ detail: MovieDetail, width: CGFloat, height: CGFloat) -> some View {
        let geometry = DetailPortraitGeometry(availableSize: CGSize(width: width, height: height),
                                              isPad: AdaptiveLayout.isPad)
        return VStack(spacing: 0) {
            portraitHero(detail, geometry: geometry)
            LazyVStack(alignment: .leading, spacing: 20) {
                FetchStatusBanner(source: model.source, error: model.errorMessage, webURL: model.pageURL) {
                    showWeb = true
                }
                if model.loading && model.detail == nil {
                    ProgressView("正在加载详情…").frame(maxWidth: .infinity)
                }
                resourceCards(detail)
                libraryActions(detail)
                movieInfoCard(detail)
                mediaSection(detail)
                if !detail.tags.isEmpty { tagsSection(detail.tags) }
                if !detail.casts.isEmpty { linkSection("演员", detail.casts) }
                if let summary = detail.summary, !summary.isEmpty { summarySection(summary) }
                magnetsSection(detail)
                if detail.commentsURL != nil { commentsSection(detail) }
                if detail.relatedListsURL != nil { relatedListsSection(detail) }
                if !detail.alsoStarred.isEmpty { cardStripSection("她/他还出演过", detail.alsoStarred) }
                if !detail.relatedWorks.isEmpty { cardStripSection("相关作品", detail.relatedWorks) }
            }
            .padding(.top, 26)
            .padding(.bottom, 40)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
        }
        .frame(maxWidth: AdaptiveLayout.isPad ? 900 : AdaptiveLayout.contentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    /// The hero's cover, by entry path (build 47, LOCK-1.3-build47
    /// B14). Non-strip entries keep the build-45 behavior verbatim.
    /// Strip entries show ONLY the frozen snapshot: same file,
    /// same presentation — no HQ substitution, no og:image swap,
    /// no unconditional whole-image. In pinned mode the `url`
    /// argument is the failure fallback, so it is the card's cover
    /// only when that IS the pinned file; otherwise the pinned URL
    /// itself (a failed pin leaves the placeholder, never another
    /// movie's or another source's image). A strip entry whose
    /// snapshot is missing shows the card's own cover, front
    /// window, and nothing else.
    private func resolvedOriginalCover(_ detail: MovieDetail) -> Bool {
        CatalogCoverPolicy.usesOriginalAvfanCover(
            explicit: detail.catalogType ?? card.catalogType,
            code: detail.code ?? card.code,
            makers: detail.makers.map(\.name)
        )
    }

    private func heroCover(_ detail: MovieDetail) -> CoverImage {
        let original = resolvedOriginalCover(detail)
        if isStripEntry {
            if let pin = frozenPin {
                // Failure fallback is only the same-file card cover
                // (build 45 isSameFile). A different file must not
                // replace the pin; ImageLoader also enforces this.
                let fallback: String?
                if CoverURLPolicy.isSameFile(pin.url, card.coverURL) {
                    fallback = card.coverURL
                } else {
                    fallback = pin.url
                }
                return CoverImage(
                    url: fallback,
                    code: nil,
                    anchorY: pin.anchorY,
                    allowUpscale: true,
                    fitWholeImage: original || pin.wholeImage,
                    actors: [],
                    pinned: pin,
                    paintOnce: true,
                    usesOriginalCover: original
                )
            }
            return CoverImage(url: card.coverURL, code: nil, anchorY: 0.18, allowUpscale: true, fitWholeImage: original, actors: [], paintOnce: true, usesOriginalCover: original)
        }
        return CoverImage(url: detail.coverURL ?? card.coverURL, code: original ? nil : (detail.code ?? card.code), anchorY: 0.18, allowUpscale: true, fitWholeImage: true, actors: detail.casts.map(\.name), pinned: frozenPin, paintOnce: true, usesOriginalCover: original)
    }

    private func portraitHero(_ detail: MovieDetail, geometry: DetailPortraitGeometry) -> some View {
        let width = geometry.width
        let imageHeight = geometry.imageHeight
        let titleTop = geometry.titleTop
        return ZStack(alignment: .top) {
            heroCover(detail)
                .frame(width: width, height: imageHeight, alignment: .top)
                .clipped()
                .accessibilityHidden(true)
                .accessibilityIdentifier("detail-hero-artwork")
            // Backdrop: the gradient belongs to the image alone; the
            // text zone below the cover sits on solid dark.
            VStack(spacing: 0) {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.36),
                    .init(color: Color.black.opacity(0.24), location: 0.57),
                    .init(color: Color.black.opacity(0.78), location: 0.86),
                    .init(color: Color.black.opacity(0.92), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: imageHeight)
                Color.black.opacity(0.92)
            }
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    DetailReadableTitle(
                        title: detail.displayTitle,
                        identifier: "portrait-hero-title",
                        font: .system(size: portraitTitleSize * (AdaptiveLayout.isPad ? 1.24 : 1), weight: .bold),
                        collapsedLines: 2
                    )
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 8)
                    .padding(.horizontal, 32)
                    portraitMetadata(detail)
                        .padding(.horizontal, 18).padding(.top, 16)
                }
                // Top-pinned (build 29): the block's height is
                // reserved by minHeight, and the truncation toggle
                // arrives a beat after first render — bottom
                // anchoring moved the title on every height change
                // (the visible flicker); top anchoring keeps the
                // title's first line fixed and lets growth extend
                // into the reserved zone.
                .frame(minHeight: max(0, geometry.controlsTop - titleTop - 18), alignment: .top)
                portraitControls(detail)
                    .padding(.horizontal, 18).padding(.top, 18)
            }
            .padding(.top, titleTop)
            .padding(.bottom, 16)
            .foregroundStyle(.white)
        }
        .frame(width: width)
        .frame(maxWidth: .infinity)
    }

    private func portraitMetadata(_ detail: MovieDetail) -> some View {
        let values = [detail.displayCode, detail.releaseDate, detail.duration].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return Text(values.joined(separator: " · "))
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("portrait-hero-metadata")
    }

    private func portraitControls(_ detail: MovieDetail) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                portraitPlayButton
                portraitActionGroup
            }
            VStack(spacing: 12) {
                portraitPlayButton.frame(maxWidth: .infinity)
                portraitActionGroup.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var playProgress: Double? {
        if let resume = activeResume, let length = optionalLength(resume), length > 0 {
            return min(max(resume.position / length, 0), 1)
        }
        return nil
    }

    private func optionalLength(_ entry: PlaybackResumeEntry) -> Double? {
        entry.length > 0 ? entry.length : nil
    }

    private var portraitPlayButton: some View {
        let compact = PlaybackResumePolicy.compactTitle(position: activeResume?.position,
                                                        length: activeResume?.length)
        return Button {
            GlassHaptic.tap()
            playPrimary()
        } label: {
            DetailPlayPill(title: compact ?? "播放", progress: playProgress)
        }
        .buttonStyle(.plain)
        .contextMenu { playMenu }
        .accessibilityLabel(compact ?? "播放")
        .accessibilityIdentifier("portrait-hero-play")
    }

    @ViewBuilder
    private var playMenu: some View {
        if PlaybackResumePolicy.compactTitle(position: resume115?.position, length: resume115?.length) != nil {
            Button {
                startFromBeginning = false
                showPlayer = true
            } label: { Label("续播 115", systemImage: "clock.arrow.circlepath") }
            Button {
                startFromBeginning = true
                showPlayer = true
            } label: { Label("从头播放 115", systemImage: "backward.end") }
        }
        if let first = display.watchStreams.first {
            Button {
                startFromBeginning = true
                activeWatch = first
                showWatchPlayer = true
            } label: { Label(first.label, systemImage: "play.rectangle") }
        }
        Button {
            startFromBeginning = false
            showPlayer = true
        } label: { Label("播放 115 原画", systemImage: "play.fill") }
    }

    private var portraitActionGroup: some View {
        HStack(spacing: 0) {
            posterAction("link", label: "磁力列表") { showMagnetList = true }
            posterAction(bookmarks.contains(display.pathID) ? "bookmark.fill" : "bookmark", label: "收藏") {
                if let detail = model.detail { bookmarks.toggle(detail) }
            }
            posterAction("safari", label: "网页") { showWeb = true }
            ShareLink(item: shareText) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 23, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("分享")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.clear, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.72), lineWidth: 1.5).allowsHitTesting(false))
        .accessibilityIdentifier("portrait-hero-actions")
    }

    private func posterAction(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            GlassHaptic.tap()
            action()
        } label: {
            Image(systemName: icon).font(.system(size: 23, weight: .regular))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // Lives in the light content sheet below the hero (it used to sit inside
    // the hero's white-text stack while extending past the artwork, which
    // rendered white-on-white and broke the layout).
    private func resourceCards(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("播放资源").font(.headline)
                Spacer()
                if !detail.watchStreams.isEmpty {
                    sourceChip(.online, title: "在线播放")
                }
                sourceChip(.pan115, title: "115 原画")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    if effectiveSource == .online, let first = detail.watchStreams.first {
                        onlineResourceCard(detail, first: first)
                        pan115ResourceCard(detail)
                    } else {
                        pan115ResourceCard(detail)
                        if let first = detail.watchStreams.first {
                            onlineResourceCard(detail, first: first)
                        }
                    }
                    resourceCard(title: "磁力与推送",
                                 caption: detail.magnets.isEmpty ? "这个页面还没有解析到磁力" : "查看可用链接后选择推送",
                                 action: "查看资源", icon: "link", emphasized: false) {
                        showMagnetList = true
                    }
                }
            }
        }
        .accessibilityIdentifier("detail.resource.cards")
    }

    private func sourceChip(_ source: PlaySource, title: String) -> some View {
        let selected = effectiveSource == source
        return Button {
            sourceOverride = source
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? AVFanTheme.accent : Color.secondary.opacity(0.14), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func pan115ResourceCard(_ detail: MovieDetail) -> some View {
        resourceCard(title: "115 原画",
                     caption: pan115.isConfigured ? "打开 115 匹配资源" : "需先在设置里配置 115",
                     action: "选择播放文件", icon: "play.circle", emphasized: effectiveSource == .pan115) {
            startFromBeginning = false
            showPlayer = true
        }
    }

    private func onlineResourceCard(_ detail: MovieDetail, first: WatchStream) -> some View {
        resourceCard(title: "在线播放",
                     caption: "来自当前公开页面的媒体地址",
                     action: first.label, icon: "play.rectangle", emphasized: effectiveSource == .online) {
            startFromBeginning = true
            activeWatch = first
            showWatchPlayer = true
        }
    }

    private func resourceCard(title: String, caption: String, action: String, icon: String, emphasized: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.bold()).foregroundStyle(.primary)
                Text(caption).font(.caption).foregroundStyle(.secondary)
                Label(action, systemImage: icon).font(.subheadline)
                    .foregroundStyle(emphasized ? AVFanTheme.accent : .secondary)
            }
            .padding(16).frame(minWidth: 220, alignment: .leading)
            .liquidGlassRect(cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }

    private func playPrimary() {
        if effectiveSource == .online, let first = display.watchStreams.first {
            startFromBeginning = PlaybackResumePolicy.compactTitle(position: resumeOnline?.position, length: resumeOnline?.length) == nil
            activeWatch = first
            showWatchPlayer = true
            return
        }
        play115()
    }

    private func play115() {
        if pan115.isConfigured || resume115 != nil {
            startFromBeginning = resume115 == nil
            showPlayer = true
            return
        }
        if let first = display.watchStreams.first {
            startFromBeginning = true
            activeWatch = first
            showWatchPlayer = true
        } else {
            toast = pan115.isConfigured ? "没有可播放的资源" : "请先在设置里填写 115 Cookie 和目录 CID，或使用页面里的在线地址。"
            hideToastLater()
        }
    }

    private func movieInfoCard(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            codeRow(detail)
            infoRow("发行日期", detail.releaseDate)
            infoRow("片长", detail.duration)
            if let rating = detail.rating {
                let count = detail.ratingCount.map { " · \($0)人评分" } ?? ""
                infoRow("评分", String(format: "%.1f 分%@", rating, count))
            }
            linkRow("制作商", detail.makers)
            linkRow("发行商", detail.publishers)
            linkRow("导演", detail.directors)
            // No series row (owner instruction, build 10): the parser's
            // series links are collected page-wide and surface unrelated
            // names (a TMA title showed "Blacked").
        }
        .padding(16)
        .liquidGlassRect(cornerRadius: 18)
    }

    /// 番号: the page's own prefix link is tappable; the numeric
    /// suffix stays plain text. No prefix URL is invented.
    @ViewBuilder
    private func codeRow(_ detail: MovieDetail) -> some View {
        let value = detail.displayCode
        if !value.isEmpty {
            HStack(alignment: .top) {
                Text("番号").foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                if let prefix = detail.prefixLink {
                    let name = prefix.name
                    let suffix: String = {
                        if let range = value.range(of: name, options: [.anchored, .caseInsensitive]) {
                            return String(value[range.upperBound...])
                        }
                        if value.uppercased().hasPrefix(name.uppercased()) {
                            return String(value.dropFirst(name.count))
                        }
                        return ""
                    }()
                    HStack(spacing: 0) {
                        NavigationLink {
                            CatalogListView(title: name, path: prefix.href)
                        } label: {
                            Text(name)
                                .foregroundStyle(AVFanTheme.accent)
                        }
                        .buttonStyle(.plain)
                        if !suffix.isEmpty {
                            Text(suffix)
                        } else if value.uppercased() != name.uppercased() {
                            Text(value)
                        }
                    }
                } else {
                    Text(value)
                }
                Spacer()
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                Text(value)
                Spacer()
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private func linkRow(_ label: String, _ links: [NamedLink]) -> some View {
        if !links.isEmpty {
            HStack(alignment: .top) {
                Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                FlowLayout(spacing: 6) {
                    ForEach(links) { link in
                        NavigationLink {
                            CatalogListView(title: link.name, path: link.href)
                        } label: {
                            Text(link.name)
                                .foregroundStyle(AVFanTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
            }
            .font(.subheadline)
        }
    }

    private func tagsSection(_ tags: [NamedLink]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassSectionHeader(title: "标签", icon: "tag", trailingTitle: nil)
            LinkChips(links: tags)
        }
    }

    private func linkSection(_ title: String, _ links: [NamedLink]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassSectionHeader(title: title, icon: "person.2", trailingTitle: nil)
            LinkChips(links: links)
        }
    }

    /// 想看 / 看过 / 保存至清单 — synced to the user's avfan account
    /// through the site's own calls (endpoints and state parsed from
    /// this page). Tapping the active state removes the review, like
    /// the site's remove action. When the page carries no library
    /// block, the row is hidden.
    @ViewBuilder
    private func libraryActions(_ detail: MovieDetail) -> some View {
        if let library = detail.library {
            let status = reviewOverride ?? library.reviewStatus
            HStack(spacing: 10) {
                libraryButton(
                    icon: status == .watchlist ? "eye.fill" : "eye",
                    title: "想看",
                    active: status == .watchlist
                ) {
                    Task { await syncReview(library: library, target: .watchlist) }
                }
                libraryButton(
                    icon: status == .watched ? "checkmark.circle.fill" : "checkmark.circle",
                    title: "看过",
                    active: status == .watched
                ) {
                    Task { await syncReview(library: library, target: .watched) }
                }
                libraryButton(
                    icon: "list.bullet.rectangle",
                    title: "保存至清单",
                    active: false
                ) {
                    showListPicker = true
                }
            }
            .opacity(syncBusy ? 0.55 : 1)
            .disabled(syncBusy)
        }
    }

    private func syncReview(library: LibraryPageState, target: ReviewStatus) async {
        let current = reviewOverride ?? library.reviewStatus
        syncBusy = true
        defer { syncBusy = false }
        if current == target {
            guard let removeURL = removeURLOverride ?? library.removeURL else {
                toast = "页面没有给出取消地址"
                hideToastLater()
                return
            }
            let outcome = await LibrarySync.removeReview(url: removeURL, csrf: library.csrfToken)
            if outcome.success {
                reviewOverride = .none
                removeURLOverride = nil
                toast = "已取消"
            } else {
                handleSyncFailure(outcome)
            }
        } else {
            let isWatchlist = target == .watchlist
            guard let url = isWatchlist ? library.watchlistURL : library.watchedURL else {
                toast = "页面没有给出同步地址"
                hideToastLater()
                return
            }
            let outcome = await LibrarySync.setReview(
                url: url,
                actionType: isWatchlist ? library.watchlistActionType : library.watchedActionType,
                csrf: library.csrfToken
            )
            if outcome.success {
                reviewOverride = target
                if let remove = outcome.removeURL { removeURLOverride = remove }
                toast = isWatchlist ? "已加入想看" : "已标记看过"
            } else {
                handleSyncFailure(outcome)
            }
        }
        hideToastLater()
    }

    private func handleSyncFailure(_ outcome: LibrarySync.Outcome) {
        if outcome.needsLogin {
            showLogin = true
        } else {
            toast = outcome.message ?? "同步失败"
            hideToastLater()
        }
    }

    private func libraryButton(icon: String, title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            GlassHaptic.tap()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(title).font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(active ? Color.white : AVFanTheme.accent)
            .background(active ? AVFanTheme.accent : AVFanTheme.accent.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 预告与预览图: trailer tile first with a play control, then
    /// preview stills only. Fixed-aspect equal-height grid — no
    /// masonry, no overlap, no ad banners.
    @ViewBuilder
    private func mediaSection(_ detail: MovieDetail) -> some View {
        let gallery = galleryImages(detail)
        let showTrailer = detail.trailerURL != nil || detail.hasTrailerAffordance
        if showTrailer || !gallery.isEmpty {
            let items: [MediaGridItem] = {
                var list: [MediaGridItem] = []
                if showTrailer { list.append(.trailer) }
                list.append(contentsOf: gallery.map { MediaGridItem.still($0) })
                return list
            }()
            let shown = mediaExpanded ? items : Array(items.prefix(8))
            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeader(title: "预告与预览图", icon: "photo.on.rectangle.angled", trailingTitle: nil)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                        switch item {
                        case .trailer:
                            Button {
                                GlassHaptic.tap()
                                if detail.trailerURL == nil && !session.isSignedIn {
                                    showLogin = true
                                } else {
                                    playTrailer = true
                                }
                            } label: {
                                mediaCell(url: detail.coverURL ?? gallery.first, badge: "预告片", play: true)
                            }
                            .buttonStyle(.plain)
                        case .still(let url):
                            Button {
                                GlassHaptic.tap()
                                if let stillIndex = gallery.firstIndex(of: url) {
                                    stillBox = IndexBox(value: stillIndex)
                                }
                            } label: {
                                mediaCell(url: url, badge: nil, play: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if items.count > 8 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { mediaExpanded.toggle() }
                    } label: {
                        Image(systemName: mediaExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private enum MediaGridItem {
        case trailer
        case still(String)
    }

    /// Samples / preview sources only. The cover is not mixed into
    /// the stills grid; the trailer is a separate first tile.
    private func galleryImages(_ detail: MovieDetail) -> [String] {
        detail.previewImages
    }

    private func mediaCell(url: String?, badge: String?, play: Bool) -> some View {
        Color.clear
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                ZStack {
                    RemoteImage(url: url, contentMode: .fill)
                    if play {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white, .black.opacity(0.35))
                    }
                    if let badge {
                        VStack {
                            Spacer()
                            HStack {
                                Text(badge)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.55), in: Capsule())
                                Spacer()
                            }
                        }
                        .padding(5)
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func summarySection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassSectionHeader(title: "简介", icon: "text.alignleft", trailingTitle: nil)
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    // MARK: Detail extras （评论 / 相关清单 / 还出演过 / 相关作品）

    private func commentsSection(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassSectionHeader(title: "评论", icon: "text.bubble", badge: detail.commentsCount.map { "\($0)" }, trailingTitle: nil)
            if commentsBusy && comments.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if comments.isEmpty && commentsNeedLogin {
                Button("登录后查看评论") { showLogin = true }
                    .font(.footnote.weight(.semibold))
            } else if comments.isEmpty {
                Text(commentsFallback ?? "暂无评论。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(comment.author).font(.subheadline.weight(.semibold))
                        Spacer()
                        if let date = comment.dateText {
                            Text(date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(comment.body).font(.subheadline)
                }
                .padding(.vertical, 4)
                .onAppear {
                    if comment.id == comments.last?.id && commentsCursor != nil {
                        Task { await loadComments(detail, cursor: commentsCursor) }
                    }
                }
            }
            if commentsLoginNote {
                Text("登录后可查看更多评论。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if commentsCursor != nil && !comments.isEmpty {
                Button("加载更多") {
                    Task { await loadComments(detail, cursor: commentsCursor) }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .disabled(commentsBusy)
            }
            if commentsBusy && !comments.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: detail.commentsURL) {
            if !commentsLoaded { await loadComments(detail, cursor: nil) }
        }
    }

    private func relatedListsSection(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassSectionHeader(title: "相关清单", icon: "list.bullet.rectangle", trailingTitle: nil)
            if listsBusy && relatedRows.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if relatedRows.isEmpty && listsFailed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("加载失败，请稍后再试。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("重试") {
                        listsLoaded = false
                        listsFailed = false
                        Task { await loadRelatedLists(detail, page: nil) }
                    }
                    .font(.footnote.weight(.semibold))
                }
            } else if relatedRows.isEmpty && listsLoaded && listsNeedLogin && !session.isSignedIn {
                Button("登录后查看相关清单") { showLogin = true }
                    .font(.footnote.weight(.semibold))
            } else if relatedRows.isEmpty && listsLoaded {
                Text("暂无相关清单。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(relatedRows) { row in
                NavigationLink {
                    CatalogListView(title: row.name, path: row.href)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AVFanTheme.accent)
                            .multilineTextAlignment(.leading)
                        Text(listRowMeta(row))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if listsNext != nil && !relatedRows.isEmpty {
                Button("加载更多") {
                    Task { await loadRelatedLists(detail, page: listsNext) }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .disabled(listsBusy)
            }
            if listsBusy && !relatedRows.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .animation(nil, value: relatedRows)
        // Fallback only (build 47): the primary load is driven by
        // the parent view after the detail lands. This fires when
        // the section appears and the load has neither completed
        // nor is in flight — including after a cancelled attempt,
        // which no longer poisons the loaded/failed flags.
        .task(id: detail.relatedListsURL) {
            ensureListsLoaded(detail)
        }
    }

    private func listRowMeta(_ row: RelatedListRow) -> String {
        var parts: [String] = []
        if let movies = row.moviesCount { parts.append("\(movies)部作品") }
        if let views = row.viewsCount { parts.append("被查看\(views)次") }
        return parts.joined(separator: "，")
    }

    private func cardStripSection(_ title: String, _ cards: [MovieCard]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassSectionHeader(title: title, icon: "film.stack", trailingTitle: nil)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(cards) { card in
                        FilmographyStripCell(card: card) { stripTarget = $0 }
                    }
                }
            }
        }
    }

    /// Whether a fragment is really a login gate (sign-in markers,
    /// no usable content) rather than content.
    private func fragmentIsLoginGate(_ fragment: String) -> Bool {
        fragment.contains("请登录") || fragment.contains("sign_in")
    }

    /// Comments: first fetch uses the fragment URL the page itself
    /// declared; further batches follow the fragment's own cursor
    /// (sort_by/last_value/last_id — the comment controller's
    /// loadMore). Lock 1.3: a gated fragment triggers ONE session
    /// re-bridge + refetch; still gated → prompt login, never show
    /// the gate's text or markup debris as comments.
    private func loadComments(_ detail: MovieDetail, cursor: (sortBy: String, lastValue: String, lastId: String)?) async {
        guard let base = detail.commentsURL, !commentsBusy else { return }
        commentsBusy = true
        defer { commentsBusy = false }
        var path = base
        if let cursor {
            let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }
            path += (base.contains("?") ? "&" : "?")
                + "sort_by=\(enc(cursor.sortBy))&last_value=\(enc(cursor.lastValue))&last_id=\(enc(cursor.lastId))"
        }
        do {
            var fragment = try await SiteClient.shared.fragment(
                for: SiteClient.shared.catalogURL(path: path),
                csrf: detail.library?.csrfToken,
                referer: model.pageURL,
                ageCookie: settings.legalAgeCookie
            )
            var parsed = await HTMLParser.detached { HTMLParser.movieComments(in: fragment) }
            if cursor == nil, parsed.isEmpty, fragmentIsLoginGate(fragment) {
                await CookieBridge.exportWebKitToShared()
                fragment = try await SiteClient.shared.fragment(
                    for: SiteClient.shared.catalogURL(path: path),
                    csrf: detail.library?.csrfToken,
                    referer: model.pageURL,
                    ageCookie: settings.legalAgeCookie
                )
                parsed = await HTMLParser.detached { HTMLParser.movieComments(in: fragment) }
            }
            if cursor == nil {
                commentsNeedLogin = parsed.isEmpty && fragmentIsLoginGate(fragment)
                comments = parsed
                if parsed.isEmpty && !commentsNeedLogin {
                    let text = HTMLParser.stripTagsQuoteAware(fragment)
                    commentsFallback = (text.isEmpty || text.contains("data-") || text.contains("comment#")) ? nil : text
                } else if !parsed.isEmpty {
                    commentsFallback = nil
                }
                commentsLoginNote = fragment.contains("请登录") && !commentsNeedLogin
            } else {
                let known = Set(comments.map(\.id))
                comments += parsed.filter { !known.contains($0.id) }
            }
            commentsCursor = await HTMLParser.detached { HTMLParser.commentsCursor(in: fragment) }
            commentsLoaded = true
        } catch {
            // A cancelled load is not a completed one (build 47):
            // leave commentsLoaded false so the section's .task
            // can pull again when the section reappears.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            commentsCursor = nil
            commentsLoaded = true
        }
    }

    /// Drives the related-lists first load (build 47,
    /// LOCK-1.3-build47 A): called by the parent view right after
    /// the detail lands (and by the section's .task as a fallback).
    /// The load's identity is the card plus the lists URL the page
    /// declared; a new identity resets the section first.
    private func ensureListsLoaded(_ detail: MovieDetail) {
        guard let listsURL = detail.relatedListsURL else { return }
        let identity = card.pathID + "|" + listsURL
        if listsIdentity != identity {
            listsIdentity = identity
            relatedRows = []
            listsNext = nil
            listsLoaded = false
            listsFailed = false
            listsNeedLogin = false
        }
        if !listsLoaded && !listsBusy {
            Task { await loadRelatedLists(detail, page: nil) }
        }
    }

    private func loadRelatedLists(_ detail: MovieDetail, page: Int?, attempt: Int = 0) async {
        guard let base = detail.relatedListsURL, !listsBusy else { return }
        listsBusy = true
        defer { listsBusy = false }
        var path = base
        if let page {
            path += (base.contains("?") ? "&" : "?") + "page=\(page)"
        }
        do {
            await CookieBridge.exportWebKitToShared()
            var fragment = try await SiteClient.shared.fragment(
                for: SiteClient.shared.catalogURL(path: path),
                csrf: detail.library?.csrfToken,
                referer: model.pageURL,
                ageCookie: settings.legalAgeCookie
            )
            var parsed = await HTMLParser.detached { HTMLParser.relatedListRows(in: fragment) }
            // An empty/gated first fragment gets ONE session
            // re-bridge + refetch before anyone concludes there
            // are no lists or that login is required.
            if page == nil, parsed.isEmpty, fragmentIsLoginGate(fragment) {
                await CookieBridge.exportWebKitToShared()
                fragment = try await SiteClient.shared.fragment(
                    for: SiteClient.shared.catalogURL(path: path),
                    csrf: detail.library?.csrfToken,
                    referer: model.pageURL,
                    ageCookie: settings.legalAgeCookie
                )
                parsed = await HTMLParser.detached { HTMLParser.relatedListRows(in: fragment) }
            }
            let gated = parsed.isEmpty && fragmentIsLoginGate(fragment)
            // Already signed in: a login-shaped failure is a
            // fetch/parse problem, not a prompt to log in again.
            if page == nil {
                listsNeedLogin = gated && !session.isSignedIn
                listsFailed = gated && session.isSignedIn
                relatedRows = parsed
            } else {
                let known = Set(relatedRows.map(\.id))
                relatedRows += parsed.filter { !known.contains($0.id) }
            }
            let nextPage = await HTMLParser.detached { HTMLParser.fragmentNextPage(in: fragment) }
            // Pagination must move forward: a fragment can carry
            // a stale data-next-page (the same value on every
            // page), which would refetch the page just loaded.
            if let page, let nextPage, nextPage <= page {
                listsNext = nil
            } else {
                listsNext = nextPage
            }
            listsLoaded = true
            if page == nil, !gated {
                listsFailed = false
            }
        } catch {
            // Cancellation is not a failure (build 47,
            // LOCK-1.3-build47 A5): the LazyVStack churn cancels
            // first runs routinely. Leave every flag untouched so
            // the load can simply be pulled again later.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            // A REAL first-page failure gets one automatic retry;
            // only the second failure surfaces the failure UI.
            // listsLoaded deliberately stays false either way, so
            // a later section appearance can re-pull via the
            // fallback .task.
            if page == nil, attempt == 0 {
                listsBusy = false
                await loadRelatedLists(detail, page: nil, attempt: 1)
                return
            }
            listsNext = nil
            if page == nil, relatedRows.isEmpty {
                listsFailed = true
                listsNeedLogin = false
            }
        }
    }

    private func magnetsSection(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader(title: "磁力链接", icon: "link", badge: "\(detail.magnets.count)", trailingTitle: nil)
            if detail.magnets.isEmpty {
                Text("这个页面没有解析到磁力链接。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(magnetsExpanded ? detail.magnets : Array(detail.magnets.prefix(3))) { magnet in
                magnetRow(magnet, detail: detail)
            }
            if detail.magnets.count > 3 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { magnetsExpanded.toggle() }
                } label: {
                    Text(magnetsExpanded ? "收起" : "展开全部（共 \(detail.magnets.count) 条）")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .glassChromeButton()
            }
            if externalSettings.enabled {
                externalMagnetsBlock(detail)
            }
        }
        .padding(.top, 4)
        .task(id: detail.displayCode) { await loadExternalLinks(detail) }
    }

    private func magnetRow(_ magnet: MagnetItem, detail: MovieDetail) -> some View {
        MagnetRow(
            magnet: magnet,
            configured: pan115.isConfigured,
            onPushPlay: {
                activeMagnet = magnet
                startFromBeginning = false
                if pan115.isConfigured {
                    showPlayer = true
                } else {
                    toast = "请先在设置里填写 115 Cookie 和目录 CID"
                    hideToastLater()
                }
            },
            onPushOnly: {
                Task { await pushOnly(magnet, keyword: detail.displayCode) }
            },
            onCopy: {
                UIPasteboard.general.string = magnet.url
                toast = "已复制磁力链接"
                hideToastLater()
            }
        )
    }

    /// The external database's extra links for this number
    /// (build 38): same rows, same 115 actions, deduplicated
    /// against the page's own magnets, with AVDB's status line.
    @ViewBuilder
    private func externalMagnetsBlock(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader(title: "外部数据库", icon: "externaldrive", badge: externalMagnets.isEmpty ? nil : "\(externalMagnets.count)", trailingTitle: nil)
            if let externalStatus {
                Text(externalStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(externalExpanded ? externalMagnets : Array(externalMagnets.prefix(3))) { magnet in
                magnetRow(magnet, detail: detail)
            }
            if externalMagnets.count > 3 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { externalExpanded.toggle() }
                } label: {
                    Text(externalExpanded ? "收起" : "展开全部（共 \(externalMagnets.count) 条）")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .glassChromeButton()
            }
        }
        .padding(.top, 8)
    }

    private func loadExternalLinks(_ detail: MovieDetail) async {
        let settings = ExternalLibrarySettings.shared
        guard settings.enabled else { return }
        let code = detail.displayCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, externalCode != code else { return }
        externalCode = code
        guard let token = settings.token(), !token.isEmpty else {
            externalStatus = "外部数据库未配置令牌，请前往「设置 → 外部数据库」保存。"
            return
        }
        externalStatus = "正在查询外部数据库…"
        do {
            let links = try await ExternalLibraryClient.shared.fetchLinks(for: code)
            let existing = Set(detail.magnets.map(\.url))
            var seen = Set<String>()
            externalMagnets = links.compactMap { link -> MagnetItem? in
                guard !existing.contains(link.downloadURL), seen.insert(link.downloadURL).inserted else { return nil }
                var tags: [String] = []
                if link.chinese == true { tags.append("中字") }
                if link.uncensored == true { tags.append("无码") }
                if link.uhd == true { tags.append("UHD") }
                if let seeders = link.seeders { tags.append("做种 \(seeders)") }
                var sizeText: String?
                if let mb = link.sizeMB {
                    sizeText = mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
                }
                return MagnetItem(
                    url: link.downloadURL,
                    name: link.title ?? code,
                    sizeText: sizeText,
                    sizeKB: link.sizeMB.map { Int($0 * 1024) },
                    fileCount: nil,
                    date: nil,
                    tags: tags
                )
            }
            externalStatus = links.isEmpty ? "外部数据库查询成功，暂无资源" : "外部数据库已加载"
        } catch is CancellationError {
            return
        } catch {
            externalStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func pushOnly(_ magnet: MagnetItem, keyword: String) async {
        guard pan115.isConfigured else {
            toast = "请先在设置里填写 115 Cookie 和目录 CID"
            hideToastLater()
            return
        }
        do {
            let result = try await Pan115Client.shared.addOfflineTask(
                url: magnet.url,
                cookie: pan115.cookie,
                folderCID: pan115.folderCID
            )
            toast = result.message
        } catch {
            toast = error.localizedDescription
        }
        hideToastLater()
    }

    private func hideToastLater() {
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            toast = nil
        }
    }

    private func refreshResume() {
        let code = model.detail?.displayCode ?? card.displayCode
        if let key = PlaybackResumeKey.make(number: code, source: "115") {
            resume115 = PlaybackResumeStore.shared.entry(key, scope: "avfan")
        }
        if let key = PlaybackResumeKey.make(number: code, source: "avfan") {
            resumeOnline = PlaybackResumeStore.shared.entry(key, scope: "avfan")
        }
    }

    private var shareText: String {
        let detail = model.detail
        let code = detail?.displayCode ?? card.displayCode
        let title = detail?.displayTitle ?? card.displayTitle
        let url = detail?.pageURL ?? HTMLParser.absoluteURL(card.href)
        return "\(code) \(title)\n\(url)"
    }
}

struct DetailPortraitGeometry {
    let width: CGFloat
    let imageHeight: CGFloat
    let titleTop: CGFloat
    let controlsTop: CGFloat

    init(availableSize: CGSize, isPad: Bool) {
        width = max(1, min(availableSize.width, isPad ? 900 : 600))
        imageHeight = min(width * 1.58, max(600, availableSize.height * 0.8))
        // The title block starts BELOW the cover (owner, build 21):
        // text never overlays the artwork.
        titleTop = imageHeight + 14
        controlsTop = max(titleTop + 132, min(width * 1.42, availableSize.height * 0.64))
    }
}

private struct DetailTitleHeights: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct DetailReadableTitle: View {
    let title: String
    let identifier: String
    var font: Font = .title2.weight(.bold)
    var collapsedLines: Int = 3
    @State private var expanded = false
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleText.lineLimit(expanded ? nil : collapsedLines)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
                .background(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        titleText.lineLimit(collapsedLines).fixedSize(horizontal: false, vertical: true)
                            .background { GeometryReader { proxy in
                                Color.clear.preference(key: DetailTitleHeights.self, value: ["collapsed": proxy.size.height])
                            } }
                        titleText.fixedSize(horizontal: false, vertical: true)
                            .background { GeometryReader { proxy in
                                Color.clear.preference(key: DetailTitleHeights.self, value: ["full": proxy.size.height])
                            } }
                    }.hidden().accessibilityHidden(true).allowsHitTesting(false)
                }
            if truncated {
                Button { expanded.toggle() } label: {
                    Text(expanded ? "收起标题" : "展开全文")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("detail-title-toggle")
            }
        }
        .onPreferenceChange(DetailTitleHeights.self) { heights in
            truncated = (heights["full"] ?? 0) > (heights["collapsed"] ?? 0) + 1
        }
    }

    private var titleText: some View {
        Text(title).font(font).lineSpacing(4).multilineTextAlignment(.leading)
    }
}

/// Tappable chips for a detail page's casts / tags: each chip pushes the
/// matching catalog list (the cast's, tag's, maker's… own movie list).
struct LinkChips: View {
    let links: [NamedLink]
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(links) { link in
                NavigationLink {
                    // Cast links open the native cast profile page
                    // (build 23); everything else keeps the catalog.
                    if HTMLParser.stripLocale(link.href).hasPrefix("casts/") {
                        CastProfileView(name: link.name, path: link.href)
                    } else {
                        CatalogListView(title: link.name, path: link.href)
                    }
                } label: {
                    Text(link.name)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AVFanTheme.accent.opacity(0.12), in: Capsule())
                        .foregroundStyle(AVFanTheme.accent)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        var width: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += row + spacing
                row = 0
            }
            row = max(row, size.height)
            x += size.width + spacing
            width = max(width, x - spacing)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var row: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}


struct MagnetRow: View {
    let magnet: MagnetItem
    let configured: Bool
    var onPushPlay: () -> Void
    var onPushOnly: () -> Void
    var onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(magnet.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 8) {
                if !magnet.displayMeta.isEmpty {
                    Text(magnet.displayMeta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(magnet.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AVFanTheme.accent.opacity(0.14), in: Capsule())
                        .foregroundStyle(AVFanTheme.accent)
                }
            }
            HStack(spacing: 8) {
                Button("推送并播放", action: onPushPlay)
                    .glassChromeButton(prominent: true)
                    .disabled(!configured)
                Button("仅推送", action: onPushOnly)
                    .glassChromeButton()
                    .disabled(!configured)
                ShareLink(item: magnet.url) {
                    Text("分享")
                }
                Button("复制", action: onCopy)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(10)
        .liquidGlassRect(cornerRadius: 16)
        .contextMenu {
            Button("复制磁力", action: onCopy)
            Button("推送到 115", action: onPushOnly)
        }
    }
}

@MainActor
final class MovieDetailViewModel: ObservableObject {
    @Published var detail: MovieDetail?
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var source: FetchSource?
    var pageURL: URL?

    func load(card: MovieCard, settings: AppSettings) async {
        // Identity reset (build 45, LOCK-1.3-build45 A): a reused
        // view must never show the previous movie's detail under
        // the new card — clear first, then load.
        if detail?.pathID != card.pathID { detail = nil }
        loading = true
        errorMessage = nil
        defer { loading = false }
        let url = SiteClient.shared.movieURL(pathID: card.pathID, locale: settings.locale, href: card.href)
        pageURL = url
        do {
            var result = try await SiteClient.shared.html(
                for: url,
                locale: settings.locale,
                ageCookie: settings.legalAgeCookie,
                allowWebViewFallback: true,
                expectCatalog: true
            )
            var html = result.html
            // Session self-check (lock 1.3): the app holds a login
            // but the page came back signed out — the bridged
            // cookies drifted. Re-bridge from the WebView store,
            // drop the cached guest copy, and refetch ONCE. Never
            // parse the guest copy for login-dependent features.
            if SiteSession.shared.isSignedIn, !HTMLParser.isSignedIn(html: html) {
                await CookieBridge.exportWebKitToShared()
                await SiteClient.shared.clearCache()
                result = try await SiteClient.shared.html(
                    for: url,
                    locale: settings.locale,
                    ageCookie: settings.legalAgeCookie,
                    allowWebViewFallback: true,
                    expectCatalog: true,
                    bypassCache: true
                )
                html = result.html
            }
            // Canonical identity check (build 46): the served page
            // names its own movie in <link rel="canonical">. If that
            // id is not the tapped card's, this HTML is a different
            // movie even when its parsed 番号 happens to agree —
            // refetch once bypassing the cache and re-check; still
            // mismatched → refuse through the same fallback path as
            // the 番号 guard below. No canonical → no opinion, no
            // block.
            if let canonical = HTMLParser.canonicalPathID(in: html), canonical != card.pathID {
                result = try await SiteClient.shared.html(
                    for: url,
                    locale: settings.locale,
                    ageCookie: settings.legalAgeCookie,
                    allowWebViewFallback: true,
                    expectCatalog: true,
                    bypassCache: true
                )
                html = result.html
                if let retryCanonical = HTMLParser.canonicalPathID(in: html),
                   retryCanonical != card.pathID {
                    throw SiteClientError.transport("打开的影片与所点封面不一致，已停止打开错误影片")
                }
            }
            var parsed = await HTMLParser.detached { HTMLParser.movieDetail(from: html, url: url) }
            if parsed.pathID.isEmpty { parsed.pathID = card.pathID }
            // Identity guard (build 11): the fetched page's own 番号 must
            // be the tapped card's. A mismatch means the page that came
            // back is a DIFFERENT movie — never display it as if it were
            // the tapped one; fall back to the card's own data and say so.
            if let cardCode = card.code, let parsedCode = parsed.code {
                let normalize: (String) -> String = {
                    $0.uppercased().filter { $0.isLetter || $0.isNumber }
                }
                if normalize(cardCode) != normalize(parsedCode) {
                    throw SiteClientError.transport("打开的影片与所点封面不一致，已停止打开错误影片")
                }
            }
            if parsed.code == nil { parsed.code = card.code }
            if parsed.title.isEmpty { parsed.title = card.titleWithoutCodePrefix }
            if parsed.coverURL == nil { parsed.coverURL = card.coverURL }
            if parsed.pageURL.isEmpty { parsed.pageURL = url.absoluteString }
            // List context on the card outranks a type parsed from the
            // page; the page fills in only when the card had none.
            if parsed.catalogType == nil { parsed.catalogType = card.catalogType }
            // A superseded load (the view was reused for another
            // card and .task(id:) cancelled this one) must not land
            // its movie on screen.
            guard !Task.isCancelled else { return }
            detail = parsed
            source = result.source
        } catch {
            errorMessage = error.localizedDescription
            detail = MovieDetail(
                pathID: card.pathID,
                pageURL: url.absoluteString,
                code: card.code,
                title: card.titleWithoutCodePrefix,
                coverURL: card.coverURL,
                summary: nil,
                releaseDate: card.date,
                duration: nil,
                rating: nil,
                ratingCount: nil,
                makers: [],
                publishers: [],
                directors: [],
                series: [],
                casts: [],
                tags: [],
                magnets: [],
                catalogType: card.catalogType
            )
        }
    }
}

struct IndexBox: Identifiable {
    let value: Int
    var id: Int { value }
}

/// 保存至清单 picker, account-synced: the rows are the account's own
/// lists as the site's modal endpoint returns them; tapping a row
/// toggles this movie's membership on the account, and a new list is
/// created on the account (the site returns its row, inserted here).
struct ListPickerSheet: View {
    let state: LibraryPageState
    @Environment(\.dismiss) private var dismiss
    @State private var options: [SyncListOption] = []
    @State private var loading = true
    @State private var newListName = ""
    @State private var message: String?
    @State private var showLogin = false

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取账号清单…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if options.isEmpty {
                    Text("账号里还没有清单。用下面的输入框新建一个。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(options) { option in
                    Button {
                        Task { await toggle(option) }
                    } label: {
                        HStack {
                            Text(option.name).foregroundStyle(.primary)
                            Spacer()
                            if option.checked {
                                Image(systemName: "checkmark").foregroundStyle(AVFanTheme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Section("新建清单") {
                    HStack {
                        TextField("清单名称", text: $newListName)
                        Button("新建") {
                            Task { await create() }
                        }
                        .disabled(newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.createListURL == nil)
                    }
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("保存至清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
        .sheet(isPresented: $showLogin) { SiteLoginView() }
    }

    private func load() async {
        loading = true
        if let listsURL = state.listsURL {
            options = await LibrarySync.fetchListOptions(listsURL: listsURL, csrf: state.csrfToken)
        }
        loading = false
    }

    private func toggle(_ option: SyncListOption) async {
        guard let changeURL = state.changeURL else {
            message = "页面没有给出同步地址"
            return
        }
        let outcome = await LibrarySync.toggleList(changeURL: changeURL, listID: option.listID, csrf: state.csrfToken)
        if outcome.success {
            if let index = options.firstIndex(where: { $0.listID == option.listID }) {
                options[index].checked.toggle()
            }
            message = outcome.message
        } else if outcome.needsLogin {
            showLogin = true
        } else {
            message = outcome.message ?? "同步失败"
        }
    }

    private func create() async {
        guard let url = state.createListURL else { return }
        let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let outcome = await LibrarySync.createList(url: url, mode: state.createListMode, name: name, csrf: state.csrfToken)
        if outcome.success {
            newListName = ""
            message = outcome.message ?? "已新建清单"
            if let fragment = outcome.listFragment, let parsed = HTMLParser.listOptions(in: fragment).first {
                options.insert(parsed, at: 0)
            } else {
                await load()
            }
        } else if outcome.needsLogin {
            showLogin = true
        } else {
            message = outcome.message ?? "新建失败"
        }
    }
}

/// Trailer playback, locked 1.3 build 28 order:
/// re-bridge cookies, then (when signed in) bypassCache refetch
/// the movie page so a logged-out cache cannot be reused;
/// prefer an avfan-hosted URL from that HTML over a DMM sample;
/// play KSPlayer → AVPlayer → in-app official-player WKWebView
/// (shared cookie store, that movie page, player only).
/// When SiteSession already says signed in, the failure overlay
/// has no 登录 button.
struct TrailerPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL?
    let pageURL: URL?
    let title: String
    let poster: String?
    @State private var mediaURL: URL?
    @State private var stage: Stage = .preparing
    @State private var reloadTick = 0
    @State private var showLogin = false
    @State private var signedIn = false

    private enum Stage { case preparing, ksPlayer, avPlayer, pageWeb, failed }

    private var headers: [String: String] {
        guard let mediaURL else { return [:] }
        return MediaRequestHeaders.headers(for: mediaURL, pageURL: pageURL)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch stage {
            case .preparing:
                ProgressView()
                    .tint(.white)
            case .ksPlayer:
                if let mediaURL {
                    KSChromePlayer(
                        url: mediaURL,
                        title: title,
                        subtitle: "预告片",
                        headers: headers,
                        onPlaybackFailure: { stage = .avPlayer },
                        publicSubtitleQuery: ""
                    )
                    .id("ks-\(reloadTick)")
                    .ignoresSafeArea()
                }
            case .avPlayer:
                if let mediaURL {
                    NativeTrailerPlayer(url: mediaURL, pageURL: pageURL) {
                        if pageURL != nil {
                            stage = .pageWeb
                        } else {
                            stage = .failed
                        }
                    }
                    .id("av-\(reloadTick)")
                    .ignoresSafeArea()
                }
            case .pageWeb:
                if let pageURL {
                    TrailerPageWebView(url: pageURL)
                        .id("web-\(reloadTick)")
                        .ignoresSafeArea()
                }
            case .failed:
                Color.black.ignoresSafeArea()
            }
            if stage == .failed {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34))
                        .foregroundStyle(.orange)
                    Text("预告片加载失败")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(signedIn
                         ? "已尝试原生播放器和站点预告片播放器，请稍后重试。"
                         : "已用原生播放器尝试打开预告片。若浏览器里可以观看，请确认已登录后再试。")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    HStack(spacing: 12) {
                        if !signedIn {
                            Button("登录") { showLogin = true }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("重试") {
                            Task { await prepareAndPlay() }
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                }
            }
            VStack {
                HStack(spacing: 14) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.16), in: Circle())
                    }
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                Spacer()
            }
        }
        .task {
            await prepareAndPlay()
        }
        .sheet(isPresented: $showLogin, onDismiss: {
            Task { await prepareAndPlay() }
        }) { SiteLoginView() }
    }

    @MainActor
    private func prepareAndPlay() async {
        signedIn = SiteSession.shared.isSignedIn
        stage = .preparing
        await CookieBridge.exportWebKitToShared()
        var resolved = url
        if signedIn, let pageURL {
            let settings = AppSettings.shared
            if let result = try? await SiteClient.shared.html(
                for: pageURL,
                locale: settings.locale,
                ageCookie: settings.legalAgeCookie,
                allowWebViewFallback: true,
                expectCatalog: true,
                bypassCache: true
            ) {
                if let fresh = HTMLParser.trailerURL(in: result.html), let freshURL = URL(string: fresh) {
                    resolved = freshURL
                }
            }
        }
        mediaURL = resolved
        reloadTick += 1
        if resolved != nil {
            stage = .ksPlayer
        } else if pageURL != nil {
            stage = .pageWeb
        } else {
            stage = .failed
        }
    }
}

/// Native trailer playback via AVPlayer with the headers the
/// media hosts check: Safari UA, the movie page as Referer, and
/// the shared session cookies for avfan hosts.
struct NativeTrailerPlayer: View {
    let url: URL
    let pageURL: URL?
    var onFailure: () -> Void
    @State private var player: AVPlayer?
    @State private var statusObserver: AnyCancellable?
    @State private var failObserver: NSObjectProtocol?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                Color.black
            }
        }
        .onAppear { start() }
        .onDisappear {
            player?.pause()
            statusObserver?.cancel()
            if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        }
    }

    private func start() {
        guard player == nil else { return }
        let headers = MediaRequestHeaders.headers(for: url, pageURL: pageURL)
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        player = p
        statusObserver = item.publisher(for: \AVPlayerItem.status)
            .receive(on: DispatchQueue.main)
            .sink { status in
                if status == .failed { onFailure() }
            }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { _ in onFailure() }
        p.play()
    }
}

/// Official-player fallback: the movie page in a WebView on the
/// shared cookie store. The detail chrome is hidden so only the
/// site's own trailer player is visible; the trigger is clicked
/// automatically. Not a full detail UI.
struct TrailerPageWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let script = WKUserScript(
            source: """
            (function(){
              var css = document.createElement('style');
              css.textContent = 'header,nav,aside,.side,#related-lists,#comments,.magnet-list,footer,tab-bar,.tab-link,form,#description{display:none !important;} body{background:#000 !important;} .fancybox__container,.fancybox-container,[data-vr-root],video.fancybox-trailer{z-index:2147483647 !important;}';
              document.documentElement.appendChild(css);
              function clickTrailer(){
                var el = document.querySelector('[data-trailer-player-src-value]')
                      || document.querySelector('[data-controller="trailer-player"]')
                      || document.querySelector('[data-caption="预告片"]')
                      || document.querySelector('[data-action*="trailer"]')
                      || document.querySelector('a[href*="/trailer"]');
                if (!el) return;
                var href = el.getAttribute('href') || '';
                if (href.indexOf('sign_in') === -1) { el.click(); }
              }
              setTimeout(clickTrailer, 800);
              setTimeout(clickTrailer, 2000);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(script)
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = SiteClient.mobileSafariUA
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Full-screen viewer for the detail page's sample stills.
struct StillViewer: View {
    let images: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var current: Int

    init(images: [String], index: Int) {
        self.images = images
        _current = State(initialValue: index)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $current) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, url in
                    RemoteImage(url: url, contentMode: .fit)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                    .padding(16)
                }
                Spacer()
            }
        }
    }
}


/// Request headers for native trailer playback: Referer is the movie
/// page, or the media's own site for DMM/FANZA samples. CookieBridge
/// cookies are sent only when the host is avfan.
enum MediaRequestHeaders {
    static func headers(for url: URL, pageURL: URL?) -> [String: String] {
        var headers: [String: String] = ["User-Agent": SiteClient.mobileSafariUA]
        let host = url.host?.lowercased() ?? ""
        if host.contains("dmm.co.jp") || host.contains("dmm.com") || host.contains("awsimgsrc") || host.contains("fanza") {
            headers["Referer"] = "https://www.dmm.co.jp/"
        } else if host.contains("avfan.com") {
            headers["Referer"] = pageURL?.absoluteString ?? "https://avfan.com/"
            let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
            if !cookies.isEmpty {
                headers["Cookie"] = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            }
        } else if let pageURL {
            headers["Referer"] = pageURL.absoluteString
        }
        return headers
    }
}
