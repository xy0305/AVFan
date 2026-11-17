import SwiftUI
import UIKit
import ImageIO
import CryptoKit

/// Persistent disk cache for cover image DATA (build 35).
/// The in-memory NSCache of decoded bitmaps dies with the app,
/// and URLSession's own cache is small and header-dependent —
/// so every cold launch used to re-download every cover,
/// HD originals included. Here the downloaded bytes are kept
/// as-is in the system Caches directory (purgeable by iOS),
/// keyed by a hash of the URL, LRU-evicted past a size cap.
/// Repeat views — hero, detail and grid thumbnails alike —
/// decode from local bytes at whatever pixel cap the caller
/// asks for, with no network round trip.
actor ImageDiskCache {
    static let shared = ImageDiskCache()

    private let directory: URL
    private let maxBytes: Int64 = 250 * 1024 * 1024

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("AVFanImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for urlString: String) -> URL {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".img")
    }

    func data(for urlString: String) -> Data? {
        let url = fileURL(for: urlString)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        // Touch so LRU eviction keeps what is actually being viewed.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    func store(_ data: Data, for urlString: String) {
        guard !data.isEmpty else { return }
        try? data.write(to: fileURL(for: urlString), options: [.atomic])
        evictIfNeeded()
    }

    func contains(_ urlString: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: urlString).path)
    }

    func totalSize() -> Int64 {
        files().reduce(0) { $0 + $1.size }
    }

    func clear() {
        for file in files() { try? FileManager.default.removeItem(at: file.url) }
    }

    private func files() -> [(url: URL, size: Int64, modified: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, Int64(values?.fileSize ?? 0),
                    values?.contentModificationDate ?? .distantPast)
        }
    }

    private func evictIfNeeded() {
        var all = files()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        all.sort { $0.modified < $1.modified }
        for file in all {
            if total <= maxBytes { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }
}

/// Loads the original decoded bitmap. Crop is applied at display time
/// (`HeroFrontWindow` / `HomeAnchoredFill`), never pre-baked into a new raster.
actor ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 220
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func load(_ urlString: String?, maxPixelSize: Int = 2048, timeout: TimeInterval = 20) async -> UIImage? {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        let key = "\(urlString)#\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if let existing = inFlight[key as String] { return await existing.value }

        let task = Task<UIImage?, Never> {
            if let data = await ImageDiskCache.shared.data(for: urlString) {
                return downsample(data, maxPixelSize: maxPixelSize)
            }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.setValue(SiteClient.mobileSafariUA, forHTTPHeaderField: "User-Agent")
            request.setValue("https://avfan.com/", forHTTPHeaderField: "Referer")
            request.setValue("image/jpeg,image/webp,image/avif,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<400).contains(status), !data.isEmpty else { return nil }
                await ImageDiskCache.shared.store(data, for: urlString)
                return downsample(data, maxPixelSize: maxPixelSize)
            } catch {
                return nil
            }
        }
        inFlight[key as String] = task
        let image = await task.value
        inFlight[key as String] = nil
        if let image {
            cache.setObject(image, forKey: key, cost: pixelCost(image))
        }
        return image
    }

    /// Prefetch the BYTES for a URL into the disk cache without
    /// decoding anything (build 35). When the view that shows the
    /// image appears, its load() decodes from local bytes at the
    /// size it needs — the network wait is already gone.
    func warm(_ urlString: String?) async {
        guard let urlString, !urlString.isEmpty, URL(string: urlString) != nil else { return }
        if await ImageDiskCache.shared.contains(urlString) { return }
        _ = await load(urlString, maxPixelSize: 64)
    }

    private func pixelCost(_ image: UIImage) -> Int {
        let w = image.cgImage?.width ?? Int(image.size.width)
        let h = image.cgImage?.height ?? Int(image.size.height)
        return max(1, w * h * 4)
    }

    private func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let limit = max(maxPixelSize, 1)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cg, scale: 1, orientation: .up)
        }
        return UIImage(data: data)
    }
}

/// Visible front window in the original bitmap (Build 332 display-time crop).
enum HeroFrontWindow {
    struct Placement: Equatable {
        var drawnSize: CGSize
        var offset: CGSize
        var window: CGRect
        var jacket: Bool
        var visiblePixelSize: CGSize
    }

    static func cropRect(image: UIImage, source: String?, validatedJacket: Bool = false) -> CGRect? {
        guard let source, let cg = image.cgImage else { return nil }
        return FrontPosterPolicy.cropRect(width: cg.width, height: cg.height,
                                          source: source, validatedJacket: validatedJacket)
    }

    static func placement(image: UIImage, source: String?, container: CGSize,
                          anchorY: CGFloat = 0.22, validatedJacket: Bool = false) -> Placement {
        let iw = max(image.size.width, 1)
        let ih = max(image.size.height, 1)
        let pw = max(CGFloat(image.cgImage?.width ?? Int((iw * image.scale).rounded())), 1)
        let ph = max(CGFloat(image.cgImage?.height ?? Int((ih * image.scale).rounded())), 1)
        let sx = iw / pw
        let sy = ih / ph
        let window: CGRect
        let jacket: Bool
        if let rect = cropRect(image: image, source: source, validatedJacket: validatedJacket) {
            let uiY = (ph - rect.origin.y - rect.height) * sy
            window = CGRect(x: rect.origin.x * sx, y: uiY, width: rect.width * sx, height: rect.height * sy)
            jacket = true
        } else {
            window = CGRect(x: 0, y: 0, width: iw, height: ih)
            jacket = false
        }
        let scale = max(container.width / max(window.width, 1), container.height / max(window.height, 1))
        let drawn = CGSize(width: iw * scale, height: ih * scale)
        let dww = window.width * scale
        let dwh = window.height * scale
        let x: CGFloat
        if jacket {
            x = -window.minX * scale + (container.width - dww) / 2
        } else if iw > ih {
            x = container.width - drawn.width
        } else {
            x = (container.width - drawn.width) / 2
        }
        let y = -window.minY * scale - (dwh - container.height) * anchorY
        let visible = CGSize(width: (window.width / sx), height: (window.height / sy))
        return Placement(drawnSize: drawn, offset: CGSize(width: x, height: y),
                         window: window, jacket: jacket, visiblePixelSize: visible)
    }
}

/// aspectFill of the visible front window, painting the original decoded bitmap
/// (zero pixel reprocessing). Landscape jackets are windowed at display time.
struct HomeAnchoredFill: View {
    let image: UIImage
    let size: CGSize
    var source: String? = nil
    var anchorY: CGFloat = 0.22
    var allowUpscale: Bool = true

    var body: some View {
        let p = HeroFrontWindow.placement(image: image, source: source, container: size, anchorY: anchorY)
        let interpolation: Image.Interpolation = shouldUpscale(p, container: size) ? .high : .medium
        Image(uiImage: image)
            .resizable()
            .interpolation(interpolation)
            .frame(width: p.drawnSize.width, height: p.drawnSize.height)
            .offset(x: p.offset.width, y: p.offset.height)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            // .clipped() hides overflow but does not clip hit testing.
            // Front-crop offsets the full jacket to the left, so the
            // invisible overflow would otherwise steal taps on the
            // neighbor tile (build 49: tap left cover, open the right
            // movie). Lock hits to the visible box.
            .contentShape(Rectangle())
    }

    /// Do not treat a small thumb as HQ: skip aggressive upscaling when the
    /// visible front is much smaller than the display box.
    private func shouldUpscale(_ p: HeroFrontWindow.Placement, container: CGSize) -> Bool {
        if allowUpscale { return true }
        let needed = max(container.width, container.height) * (UIScreen.main.scale)
        return max(p.visiblePixelSize.width, p.visiblePixelSize.height) >= needed * 0.72
    }
}

@MainActor
/// What one cover surface actually displayed for a movie (build 45,
/// LOCK-1.3-build45 B): the resolved URL on screen and how it was
/// presented. A tap snapshots this; the pushed detail view pins
/// exactly it for the whole visit.
struct DisplayedCoverSnapshot: Hashable {
    let url: String
    let wholeImage: Bool
    let anchorY: CGFloat
}

/// Click-time snapshots of displayed covers, keyed by pathID with a
/// normalized-code fallback. Written by CoverImage whenever a bitmap
/// lands (the URL it actually resolved to, not the one requested);
/// read ONCE when a detail view is created. A detail view never
/// re-reads it during the visit, so later updates (a probe finishing,
/// a cell remounting with the HQ winner) cannot change a cover the
/// user is already looking at.
final class DisplayedCoverRegistry {
    static let shared = DisplayedCoverRegistry()
    private let lock = NSLock()
    private var byPathID: [String: DisplayedCoverSnapshot] = [:]
    private var byCode: [String: DisplayedCoverSnapshot] = [:]

    static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    func record(pathID: String?, code: String?, snapshot: DisplayedCoverSnapshot) {
        guard !snapshot.url.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if let pathID, !pathID.isEmpty { byPathID[pathID] = snapshot }
        if let code, !code.isEmpty { byCode[Self.normalize(code)] = snapshot }
    }

    func snapshot(pathID: String?, code: String?) -> DisplayedCoverSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        if let pathID, !pathID.isEmpty, let hit = byPathID[pathID] { return hit }
        if let code, !code.isEmpty, let hit = byCode[Self.normalize(code)] { return hit }
        return nil
    }
}

final class PosterImageModel: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false
    /// The URL whose bitmap is currently shown (the page cover, or the
    /// cached HQ winner chosen at load time). Crop policy keys off this,
    /// not the request. This may move to a probe/HQ target *before* the
    /// matching bitmap has been assigned.
    @Published var resolvedURL: String?
    /// The URL that produced the bitmap currently in `image`. Assigned
    /// only in the same places `image` is assigned (build 48 / LOCK
    /// 1.3-build47 B10), never when a load merely picks a new target.
    /// Cover surfaces snapshot this, not a leading `resolvedURL`.
    private(set) var displayedURL: String?
    private var token = 0
    /// Code of the movie whose bitmap is currently on screen.
    /// A reload for the SAME movie (grid cover → detail cover)
    /// keeps the current bitmap until the new one is ready —
    /// blanking it first is the detail page's visible flash
    /// (build 29). A different movie still blanks immediately,
    /// so a reused grid cell never shows the wrong cover.
    private var shownCode: String?

    /// Bitmaps already decoded this session, keyed by resolved
    /// URL (build 39). Lazy grids and strips destroy and recreate
    /// their CoverImage views while scrolling; a fresh model used
    /// to start empty and flash the placeholder until the async
    /// load landed — the detail page's scroll flicker. Seeding
    /// synchronously from this store makes a recreated view show
    /// the cover in its first frame; the async load below still
    /// fetches the properly-sized decode and replaces it (same
    /// image, no visible change).
    private static let retained = NSCache<NSString, UIImage>()

    private func show(_ loaded: UIImage, from source: String, code: String?) {
        displayedURL = source
        image = loaded
        shownCode = code
    }

    private func clearShownImage() {
        displayedURL = nil
        image = nil
    }

    /// Longest pixel dimension of a bitmap, for comparing decodes
    /// of the same file against each other.
    private func pixelLongest(_ image: UIImage) -> Int {
        if let cg = image.cgImage { return max(cg.width, cg.height) }
        return Int(max(image.size.width, image.size.height) * image.scale)
    }

    /// The single landing point for async decodes (session-store
    /// write + `show`). Paint-once callers (build 50, detail hero):
    /// a decode that is not strictly larger than the bitmap
    /// already on screen must neither repaint it — the small-then-
    /// sharp swap is the visible hero flicker — nor evict the
    /// larger bitmap from the session store.
    private func land(_ loaded: UIImage, from source: String, code: String?, key: String, paintOnce: Bool) {
        if paintOnce, let current = image,
           pixelLongest(loaded) <= pixelLongest(current) { return }
        Self.retained.setObject(loaded, forKey: key as NSString)
        show(loaded, from: source, code: code)
    }

    func load(url: String?, code: String? = nil, displayPoints: CGSize, allowUpscale: Bool, actors: [String] = [], pinnedURL: String? = nil, probeDisplaysWinner: Bool = false, paintOnce: Bool = false) {
        token += 1
        let current = token
        let sameMovie = code != nil && code == shownCode && image != nil
        if !sameMovie { clearShownImage() }
        failed = false
        resolvedURL = url
        let scale = UIScreen.main.scale
        let longest = Int(max(displayPoints.width, displayPoints.height) * scale)
        // Never request more pixels than needed, but keep HQ jackets sharp.
        // Small thumbs stay at their native size (no invented HQ source).
        let cap = allowUpscale ? max(longest, 1200) : min(max(longest, 400), 900)
        guard let url, !url.isEmpty else {
            // Probe-display mode (build 46, rankings grid only):
            // no URL to show yet, but a code — run the HQ probe on
            // its own and display the winner when it lands. Pinned
            // mode ignores this parameter entirely.
            if probeDisplaysWinner, pinnedURL == nil,
               let code, !code.isEmpty, HQCoverResolver.enabled {
                Task {
                    let winner = await HQCoverResolver.shared.winner(for: code, pageCover: nil, actors: actors)
                    guard current == token else { return }
                    guard let winner, !winner.isEmpty else { failed = true; return }
                    resolvedURL = winner
                    let loaded = await ImageLoader.shared.load(winner, maxPixelSize: max(cap, 1200))
                    guard current == token else { return }
                    if let loaded {
                        Self.retained.setObject(loaded, forKey: winner as NSString)
                        show(loaded, from: winner, code: code)
                    } else {
                        failed = true
                    }
                }
                return
            }
            failed = true
            return
        }

        if let pinnedURL, !pinnedURL.isEmpty {
            // Build 45 pin (LOCK-1.3-build45 B): this view was pushed
            // with the exact cover file the user tapped. Display that
            // file — never a cached HQ winner, never a probe result.
            // The fetch still runs at this view's pixel cap, so the
            // SAME file may arrive sharper; a different file may not
            // arrive at all. If the pinned file itself fails, fall
            // back only when `url` is the same file (build 45
            // isSameFile) — never to a winner or a different cover.
            resolvedURL = pinnedURL
            if !sameMovie, let seeded = Self.retained.object(forKey: pinnedURL as NSString),
               !paintOnce || pixelLongest(seeded) >= cap {
                show(seeded, from: pinnedURL, code: code)
            }
            Task {
                let loaded = await ImageLoader.shared.load(pinnedURL, maxPixelSize: cap)
                guard current == token else { return }
                if let loaded {
                    land(loaded, from: pinnedURL, code: code, key: pinnedURL, paintOnce: paintOnce)
                } else if CoverURLPolicy.isSameFile(pinnedURL, url), pinnedURL != url {
                    // Fall back only to the same file (build 45
                    // isSameFile) — never a different cover.
                    resolvedURL = url
                    let fallback = await ImageLoader.shared.load(url, maxPixelSize: cap)
                    guard current == token else { return }
                    if let fallback {
                        land(fallback, from: url, code: code, key: url, paintOnce: paintOnce)
                    } else {
                        failed = true
                    }
                } else {
                    failed = true
                }
            }
            return
        }

        // AVDB HQ cover sources (DMM / MGS), on by default. The cover for
        // a number is decided ONCE, here at load time, from the shared
        // winner cache: a cached winner is the cover from the first frame
        // in every view, grid and detail alike. With no winner cached yet
        // the page cover is shown, and a background probe warms the cache
        // for the next appearance — it must NOT swap the image when it
        // finishes. The old swap landed in the detail page (which stays
        // on screen) but not in the grid cell (whose probe dies with the
        // cell), so the tapped cover and the detail cover disagreed.
        var displayURL = url
        var displayCap = cap
        if let code, !code.isEmpty, HQCoverResolver.enabled {
            if let cached = HQCoverResolver.cachedWinner(for: code), cached != url {
                displayURL = cached
                displayCap = max(cap, 1200)
            } else if probeDisplaysWinner {
                // Probe-display mode (build 46, rankings grid only):
                // the given URL shows first; when the probe finds an
                // HQ winner, swap it in. This surface's identity is
                // its code, and the displayed-cover registry
                // re-records on the swap, so a tap still pins
                // exactly what is on screen at tap time. Every other
                // surface keeps the no-swap rule below.
                Task {
                    let winner = await HQCoverResolver.shared.winner(for: code, pageCover: url, actors: actors)
                    guard current == token, let winner, !winner.isEmpty, winner != displayURL else { return }
                    resolvedURL = winner
                    let loaded = await ImageLoader.shared.load(winner, maxPixelSize: max(cap, 1200))
                    guard current == token else { return }
                    if let loaded {
                        Self.retained.setObject(loaded, forKey: winner as NSString)
                        show(loaded, from: winner, code: code)
                    }
                }
            } else {
                Task { _ = await HQCoverResolver.shared.winner(for: code, pageCover: url, actors: actors) }
            }
        }
        resolvedURL = displayURL
        if !sameMovie, let seeded = Self.retained.object(forKey: displayURL as NSString),
           !paintOnce || pixelLongest(seeded) >= displayCap {
            show(seeded, from: displayURL, code: code)
        }
        Task {
            let loaded = await ImageLoader.shared.load(displayURL, maxPixelSize: displayCap)
            guard current == token else { return }
            if let loaded {
                land(loaded, from: displayURL, code: code, key: displayURL, paintOnce: paintOnce)
            } else if displayURL != url {
                // The cached winner failed to load; fall back to the
                // page cover rather than showing nothing.
                resolvedURL = url
                let fallback = await ImageLoader.shared.load(url, maxPixelSize: cap)
                guard current == token else { return }
                if let fallback {
                    land(fallback, from: url, code: code, key: url, paintOnce: paintOnce)
                } else {
                    failed = true
                }
            } else {
                failed = true
            }
        }
    }
}

/// Whole-image presentation for covers with no HQ source (build 18):
/// the original bitmap at its native aspect over a blurred, darkened
/// fill of itself. Never stretched, never slice-zoomed — a landscape
/// page cover in a tall hero otherwise gets magnified several times
/// and cropped to a narrow band, which looks terrible.
struct NativeFitImage: View {
    let image: UIImage
    let size: CGSize

    var body: some View {
        ZStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .scaleEffect(1.3)
                .blur(radius: 24)
                .brightness(-0.2)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

/// Front-cropped cover that paints the original bitmap with a 332 crop window.
struct CoverImage: View {
    let url: String?
    /// Catalog number used to look up AVDB-style HQ cover sources (DMM / MGS).
    var code: String? = nil
    var anchorY: CGFloat = 0.22
    var allowUpscale: Bool = false
    var validatedJacket: Bool = false
    /// Heroes only (build 18): when the loaded cover is a plain
    /// landscape original with no HQ jacket/portrait behind it, show
    /// the whole image at its native aspect instead of force-filling
    /// the tall hero frame.
    var fitWholeImage: Bool = false
    /// Actor display names for Tenhow cover discovery (build 19);
    /// only the detail page can supply them.
    var actors: [String] = []
    /// Build 45 (LOCK-1.3-build45 B): when set, this view displays
    /// exactly the tapped cover snapshot — that URL, that
    /// presentation — for its whole lifetime. Set only by the
    /// detail hero from the snapshot captured at push time.
    var pinned: DisplayedCoverSnapshot? = nil
    /// Build 45: identity of the movie this cover belongs to, for
    /// the displayed-cover registry. Any cover rendered with a
    /// pathID or a code records what it actually displayed.
    var registryPathID: String? = nil
    var registryCode: String? = nil
    /// Build 46 (rankings grid only): let an HQ probe's winner
    /// become the displayed cover — immediately when there is no
    /// URL to show, or as a swap-in when there is. Everywhere else
    /// the probe only warms the cache and never swaps (build 45's
    /// identity rule); pinned views ignore this entirely.
    var probeDisplaysWinner: Bool = false
    /// Build 47 (LOCK-1.3-build47 B): reports the snapshot this
    /// view actually put on screen (same value, same moments as
    /// the registry record below) to a caller that keeps its own
    /// copy — the detail strips freeze it at tap time instead of
    /// consulting the shared registry.
    var onDisplayed: ((DisplayedCoverSnapshot) -> Void)? = nil
    /// Paint-once surfaces (build 50, detail hero only): never
    /// paint a session-store bitmap below this view's decode cap,
    /// and never repaint with a decode that is not larger than
    /// what is already on screen — the hero paints once, at size.
    var paintOnce: Bool = false

    @StateObject private var model = PosterImageModel()
    @State private var lastURL: String?
    @State private var lastPinURL: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                placeholder
                if let image = model.image {
                    if (pinned?.wholeImage ?? fitWholeImage), Self.shouldShowWhole(image: image, source: displayedSource) {
                        NativeFitImage(image: image, size: proxy.size)
                    } else {
                        HomeAnchoredFill(image: image, size: proxy.size, source: displayedSource,
                                         anchorY: pinned?.anchorY ?? anchorY, allowUpscale: allowUpscale)
                    }
                } else if !model.failed {
                    ProgressView().tint(.secondary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .onAppear {
                reload(size: proxy.size)
                if let image = model.image {
                    emitDisplayed(image)
                }
            }
            .onChange(of: url) { _, _ in reload(size: proxy.size) }
            .onChange(of: model.image) { _, newImage in
                guard let newImage else { return }
                emitDisplayed(newImage)
            }
        }
    }

    /// The URL of the bitmap already painted — never a leading probe
    /// or HQ target that has not yet been assigned to `image`.
    private var displayedSource: String? {
        model.displayedURL ?? model.resolvedURL ?? url
    }

    private func emitDisplayed(_ image: UIImage) {
        guard let shown = model.displayedURL else { return }
        let whole = (pinned?.wholeImage ?? fitWholeImage) && Self.shouldShowWhole(image: image, source: shown)
        let snapshot = DisplayedCoverSnapshot(url: shown, wholeImage: whole, anchorY: pinned?.anchorY ?? anchorY)
        onDisplayed?(snapshot)
        // Registry writes only when the caller opted in with
        // registryPathID / registryCode. `code` alone is the HQ
        // lookup key and must not record a 番号 from strip cells.
        guard pinned == nil else { return }
        if registryPathID != nil || registryCode != nil {
            DisplayedCoverRegistry.shared.record(
                pathID: registryPathID, code: registryCode ?? code, snapshot: snapshot)
        }
    }

    private static func shouldShowWhole(image: UIImage, source: String?) -> Bool {
        guard let cg = image.cgImage, cg.width > cg.height else { return false }
        if let source {
            if CoverURLPolicy.isOfficialFrontPortrait(source) { return false }
            if HeroFrontWindow.cropRect(image: image, source: source) != nil { return false }
        }
        return true
    }

    private func reload(size: CGSize) {
        if lastURL != url || lastPinURL != pinned?.url || model.image == nil {
            lastURL = url
            lastPinURL = pinned?.url
            model.load(url: url, code: code, displayPoints: size, allowUpscale: allowUpscale, actors: actors, pinnedURL: pinned?.url, probeDisplaysWinner: probeDisplaysWinner, paintOnce: paintOnce)
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.14))
            .overlay {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
    }
}

/// Warms the disk cache with the covers a list of cards will
/// display (build 35): the cached HQ winner when one is known,
/// otherwise the page cover. Serial and quiet — bytes land
/// before the user scrolls to them, and ImageLoader dedups
/// against loads already in flight.
enum CoverPrefetch {
    static func warm(cards: [MovieCard]) {
        guard !cards.isEmpty else { return }
        Task {
            for card in cards {
                let winner = card.code.flatMap { HQCoverResolver.cachedWinner(for: $0) }
                await ImageLoader.shared.warm(winner ?? card.coverURL)
            }
        }
    }
}
