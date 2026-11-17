import Foundation
import Combine

// Build 42: the rankings tab carries ONLY the five external boards the
// owner picked — DMM, JAV Ranking, MissAV, 中指通, JAVLibrary. AVFan's
// own ranking pages are no longer shown anywhere.
//
// Data routes (none of them touches JavDB):
//  - DMM / JAV Ranking / 中指通: the pre-matched feed AVDB publishes on
//    its repo's `feed` branch (frozen 2026-11-14; the generated date is
//    shown in the UI so the staleness is never hidden).
//  - JAVLibrary: the VPS snapshot API, through the same ExternalLibrary
//    settings (server + token) the detail page already uses.
//  - MissAV: missav.fans' own ranking pages, parsed on device the same
//    way AVDB parses them; a Cloudflare challenge surfaces as an error,
//    it is never bypassed.
//
// Every entry is keyed by its code. Tapping an entry resolves the code
// against AVFan's OWN search (exact code match) and opens the AVFan
// detail page; resolutions persist on disk so repeat opens are instant
// and the visible list pre-resolves in the background.

struct RankingBoardEntry: Identifiable, Hashable {
    var rank: Int
    var code: String?
    var title: String
    var coverURL: String?
    var actresses: [String] = []
    var actorName: String?

    var id: String { "\(rank)|\(code ?? actorName ?? title)" }
    var isActor: Bool { actorName != nil }
}

enum RankingSourcesError: LocalizedError {
    case feedUnavailable
    case missavChallenged
    case missavEmpty

    var errorDescription: String? {
        switch self {
        case .feedUnavailable: return "榜单数据暂时取不到，请稍后重试。"
        case .missavChallenged: return "MissAV 触发了人机验证，原生请求被拦。稍后再试，或在浏览器打开 MissAV 核对。"
        case .missavEmpty: return "MissAV 榜单页没有解析到条目。"
        }
    }
}

// MARK: - Feed boards (DMM / JAV Ranking / 中指通)

enum RankingFeedLoader {
    static let rawBase = "https://raw.githubusercontent.com/xy0305/AVDB/feed/feed"

    private struct FeedFile: Decodable {
        struct Match: Decodable {
            let number: String?
            let title: String?
            let cover: String?
            let thumb: String?
        }
        struct Entry: Decodable {
            let rank: Int
            let code: String?
            let label: String?
            let name: String?
            let actresses: [String]?
            let match: Match?
        }
        let board: String
        let generatedAt: String?
        let entries: [Entry]
        enum CodingKeys: String, CodingKey {
            case board, entries
            case generatedAt = "generated_at"
        }
    }

    static func load(board: String, term: String) async throws
        -> (entries: [RankingBoardEntry], generatedAt: String?) {
        guard let url = URL(string: "\(rawBase)/\(board)-\(term).json") else {
            throw RankingSourcesError.feedUnavailable
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 4_000_000,
              let feed = try? JSONDecoder().decode(FeedFile.self, from: data),
              feed.board == board else {
            throw RankingSourcesError.feedUnavailable
        }
        let entries = feed.entries.map { entry in
            let code = entry.code ?? entry.match?.number
            if code == nil, let name = entry.name ?? entry.match?.title {
                return RankingBoardEntry(rank: entry.rank, code: nil,
                                         title: name, coverURL: entry.match?.thumb,
                                         actresses: entry.actresses ?? [], actorName: name)
            }
            return RankingBoardEntry(
                rank: entry.rank,
                code: code,
                title: entry.match?.title ?? entry.label ?? code ?? "",
                coverURL: entry.match?.cover ?? entry.match?.thumb,
                actresses: entry.actresses ?? [],
                actorName: nil)
        }
        return (entries, feed.generatedAt)
    }
}

// MARK: - MissAV boards

enum MissAVRankings {
    static let base = "https://missav.fans"
    static let routes: [String: String] = [
        "today-hot": "/dm301/cn/today-hot",
        "weekly-hot": "/dm170/cn/weekly-hot",
        "monthly-hot": "/dm273/cn/monthly-hot",
    ]

    static func load(term: String) async throws -> [RankingBoardEntry] {
        guard let route = routes[term], let url = URL(string: base + route) else {
            throw RankingSourcesError.missavEmpty
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw RankingSourcesError.missavEmpty
        }
        if isChallenge(html) { throw RankingSourcesError.missavChallenged }
        let entries = entries(in: html)
        guard !entries.isEmpty else { throw RankingSourcesError.missavEmpty }
        return entries
    }

    static func isChallenge(_ html: String) -> Bool {
        let lower = html.lowercased()
        if lower.contains("thumbnail") && html.count > 12_000 { return false }
        if lower.contains("<title>just a moment") || lower.contains("<title>attention required") {
            return true
        }
        return (lower.contains("cf-chl-") || lower.contains("_cf_chl_opt")
            || lower.contains("verify you are human")) && html.count < 20_000
    }

    /// Movie code from a MissAV slug ("snos-376-uncensored-leak" →
    /// "SNOS-376"); nil when the slug is not a movie slug (period
    /// links, actress links and other navigation share the /cn/ space).
    static func code(fromSlug slug: String) -> String? {
        var clean = slug.uppercased()
        for suffix in ["-UNCENSORED-LEAK", "-CHINESE-SUBTITLE"] {
            if clean.hasSuffix(suffix) { clean = String(clean.dropLast(suffix.count)) }
        }
        guard clean.range(of: #"^[A-Z0-9]+(-[A-Z0-9]+)+$"#, options: .regularExpression) != nil,
              clean.range(of: #"\d"#, options: .regularExpression) != nil,
              !["TODAY-HOT", "WEEKLY-HOT", "MONTHLY-HOT"].contains(clean) else { return nil }
        return clean
    }

    static func entries(in html: String) -> [RankingBoardEntry] {
        guard let anchorRegex = try? NSRegularExpression(
            pattern: "<a[^>]+href=\"([^\"]*/cn/([a-z0-9][a-z0-9-]*))\"[^>]*>",
            options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        let matches = anchorRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [RankingBoardEntry] = []
        var seen = Set<String>()
        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges >= 3 else { continue }
            let slug = ns.substring(with: match.range(at: 2))
            guard let code = code(fromSlug: slug), seen.insert(code).inserted else { continue }
            let windowEnd = index + 1 < matches.count
                ? matches[index + 1].range.location : min(ns.length, match.range.location + 6000)
            let window = ns.substring(with: NSRange(location: match.range.location,
                                                    length: windowEnd - match.range.location))
            var cover: String?
            var title: String?
            if let imgRange = window.range(of: "<img[^>]+>", options: .regularExpression) {
                let tag = String(window[imgRange])
                cover = HTMLParser.firstMatch("data-src=\"([^\"]+)\"", in: tag)
                    ?? HTMLParser.firstMatch("src=\"([^\"]+)\"", in: tag)
                if let alt = HTMLParser.firstMatch("alt=\"([^\"]*)\"", in: tag),
                   !alt.isEmpty {
                    title = HTMLParser.unescape(alt)
                }
            }
            out.append(RankingBoardEntry(
                rank: out.count + 1,
                code: code,
                title: title ?? code,
                coverURL: cover,
                actresses: [],
                actorName: nil))
            if out.count >= 120 { break }
        }
        return out
    }
}

// MARK: - Code → AVFan resolution

@MainActor
final class RankingMatchStore: ObservableObject {
    static let shared = RankingMatchStore()

    @Published private(set) var movieIDs: [String: String] = [:]
    @Published private(set) var actorPaths: [String: String] = [:]
    private var missedMovies = Set<String>()
    private var missedActors = Set<String>()
    private let defaultsKey = "avfan.rankingMatch.v1"

    private struct Persisted: Codable {
        var movies: [String: String] = [:]
        var actors: [String: String] = [:]
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(Persisted.self, from: data) {
            movieIDs = saved.movies
            actorPaths = saved.actors
        }
    }

    private func persist() {
        let saved = Persisted(movies: movieIDs, actors: actorPaths)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func key(for code: String) -> String {
        code.uppercased().filter { !$0.isWhitespace }
    }

    func cachedMovieCard(code: String, title: String, coverURL: String?) -> MovieCard? {
        guard let pathID = movieIDs[Self.key(for: code)] else { return nil }
        return MovieCard(pathID: pathID, href: "/movies/\(pathID)", code: code,
                         title: title, coverURL: coverURL, date: nil, ratingText: nil,
                         badges: [], canPlay: false)
    }

    func resolveMovie(code: String, title: String, coverURL: String?,
                      locale: SiteLocale, ageCookie: String?,
                      force: Bool = false) async -> MovieCard? {
        if let cached = cachedMovieCard(code: code, title: title, coverURL: coverURL) {
            return cached
        }
        let key = Self.key(for: code)
        if force { missedMovies.remove(key) }
        if missedMovies.contains(key) { return nil }
        let url = SiteClient.shared.searchURL(query: code, st: "all")
        guard let result = try? await SiteClient.shared.html(
            for: url, locale: locale, ageCookie: ageCookie,
            allowWebViewFallback: true, expectCatalog: false) else {
            return nil
        }
        let cards = HTMLParser.movieCards(in: result.html)
        guard let hit = cards.first(where: {
            Self.key(for: $0.code ?? "") == key
        }) else {
            missedMovies.insert(key)
            return nil
        }
        movieIDs[key] = hit.pathID
        persist()
        var card = hit
        if card.coverURL == nil { card.coverURL = coverURL }
        if card.title.isEmpty { card.title = title }
        return card
    }

    func resolveActor(name: String, locale: SiteLocale, ageCookie: String?,
                      force: Bool = false) async
        -> (name: String, path: String)? {
        if let path = actorPaths[name] { return (name, path) }
        if force { missedActors.remove(name) }
        if missedActors.contains(name) { return nil }
        let url = SiteClient.shared.searchURL(query: name, st: "cast")
        guard let result = try? await SiteClient.shared.html(
            for: url, locale: locale, ageCookie: ageCookie,
            allowWebViewFallback: true, expectCatalog: false) else {
            return nil
        }
        let casts = HTMLParser.castCards(in: result.html)
        let hit = casts.first(where: { $0.name == name })
            ?? casts.first(where: { $0.name.contains(name) || name.contains($0.name) })
        guard let hit else {
            missedActors.insert(name)
            return nil
        }
        actorPaths[name] = hit.href
        persist()
        return (hit.name, hit.href)
    }

    /// Warms the cache for a visible list, one search at a time
    /// (SiteClient rate-limits on its own). Stops at the first
    /// cancellation; entries already cached or already missed in this
    /// session are skipped.
    func preResolve(entries: [RankingBoardEntry], locale: SiteLocale, ageCookie: String?) async {
        for entry in entries.prefix(40) {
            if Task.isCancelled { return }
            if let name = entry.actorName {
                if actorPaths[name] == nil && !missedActors.contains(name) {
                    _ = await resolveActor(name: name, locale: locale, ageCookie: ageCookie)
                }
            } else if let code = entry.code {
                let key = Self.key(for: code)
                if movieIDs[key] == nil && !missedMovies.contains(key) {
                    _ = await resolveMovie(code: code, title: entry.title,
                                           coverURL: entry.coverURL,
                                           locale: locale, ageCookie: ageCookie)
                }
            }
        }
    }
}
