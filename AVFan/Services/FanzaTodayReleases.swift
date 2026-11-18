import Foundation
import Combine

/// Independent FANZA same-day 有码 digital feed (build 55).
/// Modeled on build 52's JavRankingLists: a dedicated fetcher, a
/// local same-day cache, a serial ~1s pause between page loads, and
/// a timeout. Failures stay inside this section — they never go
/// through SiteClient (avfan cookies) or the frozen AVDB feed.
enum FanzaTodayError: LocalizedError {
    case empty
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "今天还没有抓到 FANZA 新作，请稍后重试。"
        case .transport(let message): return message
        }
    }
}

struct FanzaTodayItem: Identifiable, Hashable, Codable {
    var cid: String
    var number: String
    var title: String
    var coverURL: String?
    var dateText: String?

    var id: String { Self.syntheticID(cid: cid, number: number) }

    static func syntheticID(cid: String, number: String) -> String {
        let key = cid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { return "fanza:" + key.lowercased() }
        return "fanza:" + number.uppercased()
    }

    func placeholderCard() -> MovieCard {
        MovieCard(
            pathID: id,
            href: "",
            code: number,
            title: title.isEmpty ? number : title,
            coverURL: coverURL,
            date: dateText,
            ratingText: nil,
            badges: [],
            canPlay: false
        )
    }
}

enum FanzaTodayLists {
    static let pagePause: TimeInterval = 1.0
    static let maxPages = 16

    private static let cacheName = "avfan.fanzaToday.v1.json"

    private struct CacheFile: Codable {
        var day: String
        var items: [FanzaTodayItem]
        var complete: Bool
        var savedAt: Date
    }

    static func jstDayStamp(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = FanzaTodayParser.tokyo
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    /// Paginate the official list until a page shows an earlier JST
    /// date (keep only today's items, then stop). `force` bypasses
    /// the same-day cache.
    static func loadToday(now: Date = Date(), force: Bool = false) async throws -> [FanzaTodayItem] {
        let day = jstDayStamp(now: now)
        if !force, let cached = cached(day: day) { return cached }
        var collected: [FanzaTodayItem] = []
        var seen = Set<String>()
        var page = 1
        var complete = false
        while page <= maxPages {
            if page > 1 {
                try await Task.sleep(nanoseconds: UInt64(pagePause * 1_000_000_000))
            }
            if Task.isCancelled { throw CancellationError() }
            let snapshot: FanzaWebFetcher.Snapshot
            do {
                snapshot = try await FanzaWebFetcher.shared.snapshot(
                    for: FanzaTodayParser.listURL(page: page)
                )
            } catch {
                if collected.isEmpty {
                    throw FanzaTodayError.transport(error.localizedDescription)
                }
                break
            }
            let parsed = FanzaTodayParser.parse(
                snapshot.html,
                today: now,
                currentPage: page,
                datesByCID: snapshot.datesByCID
            )
            for item in parsed.todayItems.map(fromParser) {
                if seen.insert(item.number.uppercased()).inserted {
                    collected.append(item)
                }
            }
            if parsed.sawEarlierDate || parsed.nextPage == nil {
                complete = true
                break
            }
            guard let next = parsed.nextPage, next > page else {
                complete = true
                break
            }
            page = next
        }
        if collected.isEmpty { throw FanzaTodayError.empty }
        store(CacheFile(day: day, items: collected, complete: complete, savedAt: Date()))
        return collected
    }

    private static func fromParser(_ item: FanzaTodayParser.Item) -> FanzaTodayItem {
        FanzaTodayItem(
            cid: item.cid,
            number: item.number,
            title: item.title,
            coverURL: item.coverURL,
            dateText: item.dateText
        )
    }

    private static func cached(day: String) -> [FanzaTodayItem]? {
        guard let data = try? Data(contentsOf: cacheURL()),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              file.day == day, !file.items.isEmpty else { return nil }
        return file.items
    }

    private static func store(_ file: CacheFile) {
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: cacheURL(), options: .atomic)
        }
    }

    private static func cacheURL() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent(cacheName)
    }
}

/// Home + full-list state for 今日发行. Kept out of HomeViewModel so a
/// FANZA failure only hides or retries this section.
@MainActor
final class FanzaTodayHomeModel: ObservableObject {
    static let homeCap = 9
    static let preResolveCap = 12

    @Published var items: [FanzaTodayItem] = []
    @Published var cards: [MovieCard] = []
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var missedMessage: String?
    @Published var resolvingID: String?

    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var didPreResolve = false

    var sectionTitle: String {
        "今日发行 · \(FanzaTodayParser.titleDate(from: Date()))"
    }

    var visibleCards: [MovieCard] {
        Array(cards.prefix(Self.homeCap))
    }

    var hasMore: Bool { cards.count > Self.homeCap || items.count > Self.homeCap }

    var statusMessage: String? {
        if resolvingID != nil { return "按番号匹配中…" }
        return missedMessage
    }

    func load(settings: AppSettings, force: Bool) async {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task { await self.performLoad(settings: settings, force: force, generation: generation) }
        loadTask = task
        await task.value
    }

    private func performLoad(settings: AppSettings, force: Bool, generation: Int) async {
        loading = true
        errorMessage = nil
        missedMessage = nil
        if force {
            didPreResolve = false
        }
        defer { if generation == loadGeneration { loading = false } }
        do {
            let fetched = try await FanzaTodayLists.loadToday(force: force)
            guard generation == loadGeneration else { return }
            items = fetched
            cards = fetched.map { resolvedCard(for: $0) }
            await preResolveIfNeeded(settings: settings)
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            if items.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Refresh cards from RankingMatchStore as matches land.
    func refreshResolvedCards() {
        cards = items.map { resolvedCard(for: $0) }
    }

    func resolvedCard(for item: FanzaTodayItem) -> MovieCard {
        let placeholder = item.placeholderCard()
        if let hit = RankingMatchStore.shared.cachedMovieCard(
            code: item.number, title: item.title, coverURL: item.coverURL
        ) {
            var card = hit
            if card.coverURL == nil { card.coverURL = item.coverURL }
            if card.title.isEmpty { card.title = item.title }
            if card.date == nil { card.date = item.dateText }
            return card
        }
        if let hit = RankingMatchStore.shared.resolvedCards[RankingMatchStore.key(for: item.number)] {
            var card = hit
            if card.coverURL == nil { card.coverURL = item.coverURL }
            if card.date == nil { card.date = item.dateText }
            return card
        }
        return placeholder
    }

    /// A tap always force-resolves so a previous miss is retried.
    /// Unmatched items stay in the section with 「AVFan 暂无此作」;
    /// the main path never opens a FANZA/DMM webpage.
    func open(_ card: MovieCard, settings: AppSettings) async -> MovieCard? {
        missedMessage = nil
        if !card.isFanzaPlaceholder {
            return card
        }
        guard let code = card.code, !code.isEmpty else {
            missedMessage = "AVFan 暂无此作"
            return nil
        }
        resolvingID = card.id
        defer { resolvingID = nil }
        let hit = await RankingMatchStore.shared.resolveMovie(
            code: code,
            title: card.title,
            coverURL: card.coverURL,
            locale: settings.locale,
            ageCookie: settings.legalAgeCookie,
            force: true
        )
        refreshResolvedCards()
        if let hit {
            var result = hit
            if result.coverURL == nil { result.coverURL = card.coverURL }
            if result.date == nil { result.date = card.date }
            return result
        }
        missedMessage = "AVFan 暂无此作"
        return nil
    }

    func preResolveVisible(settings: AppSettings, from index: Int, count: Int) async {
        let slice = Array(items.dropFirst(index).prefix(count))
        guard !slice.isEmpty else { return }
        let entries = slice.map {
            RankingBoardEntry(rank: 0, code: $0.number, title: $0.title, coverURL: $0.coverURL)
        }
        await RankingMatchStore.shared.preResolve(
            entries: entries, locale: settings.locale, ageCookie: settings.legalAgeCookie
        )
        if Task.isCancelled { return }
        refreshResolvedCards()
    }

    private func preResolveIfNeeded(settings: AppSettings) async {
        guard !didPreResolve else {
            refreshResolvedCards()
            return
        }
        didPreResolve = true
        await preResolveVisible(settings: settings, from: 0, count: Self.preResolveCap)
    }
}

extension MovieCard {
    var isFanzaPlaceholder: Bool { pathID.hasPrefix("fanza:") }
}
