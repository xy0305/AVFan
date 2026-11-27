import Foundation

// Build 60: AVBase board transport. Surfaces, all plain
// public pages on www.avbase.net — no login, no /api/:
//   最新作品   /works/recent?page=N
//   按发售日   /works/date/<yyyy-MM-dd>?page=N
//   番号搜索   /works?q=<keyword>&page=N
// Build 61 adds:
//   女优排行   /talents/popular?date=<yyyy-MM-dd>
//   女优作品页 /talents/<name>?page=N
//
// Politeness mirrors the other live boards: a single serial lane
// with at least one second between requests, the app's mobile UA.
// URLSession goes first; a 403/429/503, a Cloudflare challenge page
// (HTMLParser.isBlocked) or a page without __NEXT_DATA__ falls back
// to the shared WKWebView fetcher — the same pattern SiteClient
// uses for avfan itself. If the WebView answer is still a challenge
// or still has no data, the board surfaces avbaseChallenged; it is
// never bypassed. (This host's egress is Cloudflare-blocked from
// the build machine, so the route is device-verified only — see
// Build60-AVBase.md.)

struct AVBaseBoardPage {
    let entries: [RankingBoardEntry]
    let hasMore: Bool
    let total: Int?
}

/// One page of a talent's works wall plus her profile (build 61).
/// The profile rides every page's props; page 1's copy is the one
/// the header keeps.
struct AVBaseTalentPage {
    let profile: AVBaseTalentProfile?
    let page: AVBaseBoardPage
}

actor AVBaseClient {
    static let shared = AVBaseClient()
    static let origin = "https://www.avbase.net"

    private let minInterval: TimeInterval = 1.0
    private var lastRequestAt: Date = .distantPast
    /// First-page sizes per surface key: AVBase mixes 10/30-item
    /// pages, so pagination math uses the size the first page
    /// actually returned (avCollectAllWorks' rule in avbase.js).
    private var firstPageCounts: [String: Int] = [:]

    func loadRecent(page: Int) async throws -> AVBaseBoardPage {
        try await loadPage(key: "recent", path: "/works/recent", query: [], page: page)
    }

    func loadDate(_ date: String, page: Int) async throws -> AVBaseBoardPage {
        try await loadPage(key: "date|\(date)", path: "/works/date/\(date)",
                           query: [], page: page)
    }

    func loadSearch(query keyword: String, page: Int) async throws -> AVBaseBoardPage {
        try await loadPage(key: "search|\(keyword)", path: "/works",
                           query: [URLQueryItem(name: "q", value: keyword)], page: page)
    }

    /// 女优排行 (build 61): /talents/popular?date=<JST today>. The
    /// snapshot for the requested day may not exist yet — avbase.js
    /// falls back to the latest issue, and so does this: one retry
    /// without the date before giving up as empty.
    func loadTalentRanking(date: String) async throws -> [RankingBoardEntry] {
        var components = URLComponents(string: Self.origin + "/talents/popular")!
        components.queryItems = [URLQueryItem(name: "date", value: date)]
        guard let datedURL = components.url else { throw RankingSourcesError.avbaseEmpty }
        var rows = AVBaseParser.talentRanking(html: try await fetchHTML(datedURL))
        if rows.isEmpty {
            guard let latestURL = URL(string: Self.origin + "/talents/popular") else {
                throw RankingSourcesError.avbaseEmpty
            }
            rows = AVBaseParser.talentRanking(html: try await fetchHTML(latestURL))
        }
        guard !rows.isEmpty else { throw RankingSourcesError.avbaseEmpty }
        return rows.map { row in
            RankingBoardEntry(rank: row.rank, code: nil, title: row.name,
                              coverURL: row.avatarURL, actresses: [],
                              actorName: row.name)
        }
    }

    /// 女优作品页 (build 61): /talents/<name>?page=N — the profile
    /// and the works list ride the same pageProps, so one fetch
    /// returns both. Pagination shares the works surfaces' rule.
    func loadTalent(name: String, page: Int) async throws -> AVBaseTalentPage {
        let page = max(1, page)
        let encoded = name.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlPathAllowed) ?? name
        var components = URLComponents(string: Self.origin + "/talents/\(encoded)")!
        components.queryItems = [URLQueryItem(name: "page", value: String(page))]
        guard let url = components.url else { throw RankingSourcesError.avbaseEmpty }
        let html = try await fetchHTML(url)
        guard let props = AvbaseMetadata.props(html) else {
            throw RankingSourcesError.avbaseChallenged
        }
        let parsed = AVBaseParser.page(props: props)
        let board = try finishPage(works: parsed.works, total: parsed.total,
                                   page: page, key: "talent|\(name)")
        return AVBaseTalentPage(profile: AVBaseParser.talentProfile(props: props),
                                page: board)
    }

    private func loadPage(key: String, path: String, query: [URLQueryItem],
                          page: Int) async throws -> AVBaseBoardPage {
        let page = max(1, page)
        var components = URLComponents(string: Self.origin + path)!
        components.queryItems = query + [URLQueryItem(name: "page", value: String(page))]
        guard let url = components.url else { throw RankingSourcesError.avbaseEmpty }

        let html = try await fetchHTML(url)
        guard let parsed = AVBaseParser.page(html: html) else {
            throw RankingSourcesError.avbaseChallenged
        }
        return try finishPage(works: parsed.works, total: parsed.total,
                              page: page, key: key)
    }

    /// Shared page shaping: dedupe by code within the page
    /// (RankingMatchStore keys everything by code; a duplicate row
    /// would double-list), then judge pagination by what actually
    /// came back (build 61 — AVBaseParser.hasMore; the declared
    /// total no longer decides).
    private func finishPage(works rawWorks: [AVBaseWork], total: Int?,
                            page: Int, key: String) throws -> AVBaseBoardPage {
        var seen = Set<String>()
        let works = rawWorks.filter { seen.insert($0.code).inserted }
        if works.isEmpty {
            // An empty later page just ends pagination; an empty
            // first page is the board's error state.
            if page <= 1 { throw RankingSourcesError.avbaseEmpty }
            return AVBaseBoardPage(entries: [], hasMore: false, total: total)
        }
        if page <= 1 { firstPageCounts[key] = works.count }
        let pageSize = firstPageCounts[key] ?? works.count
        let hasMore = AVBaseParser.hasMore(pageCount: works.count,
                                           firstPageCount: pageSize)
        let entries = works.enumerated().map { index, work in
            RankingBoardEntry(rank: (page - 1) * pageSize + index + 1,
                              code: work.code, title: work.title,
                              coverURL: nil, actresses: work.actresses,
                              actorName: nil)
        }
        return AVBaseBoardPage(entries: entries, hasMore: hasMore, total: total)
    }

    // MARK: - Transport (URLSession → WKWebView fallback)

    private func fetchHTML(_ url: URL) async throws -> String {
        var sessionError: Error?
        do {
            let html = try await fetchWithURLSession(url)
            if !HTMLParser.isBlocked(html, status: nil),
               AvbaseMetadata.props(html) != nil {
                return html
            }
            // 200 but a challenge shell or a page without data:
            // fall through to the WebView.
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            sessionError = error
        }
        let html = try await fetchWithWebView(url)
        guard !HTMLParser.isBlocked(html, status: nil),
              AvbaseMetadata.props(html) != nil else {
            if let http = sessionError as? HTTPStatusError,
               [403, 429, 503].contains(http.status) {
                throw RankingSourcesError.avbaseChallenged
            }
            if let sessionError { throw sessionError }
            throw RankingSourcesError.avbaseChallenged
        }
        return html
    }

    private func fetchWithURLSession(_ url: URL) async throws -> String {
        try await respectRateLimit()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 25)
        request.setValue(SiteClient.mobileSafariUA, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        request.setValue("ja,en-US;q=0.7,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.origin + "/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPStatusError(status: status) }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private func fetchWithWebView(_ url: URL) async throws -> String {
        try await respectRateLimit()
        return try await WebViewFetcher.shared.html(for: url, ageCookie: nil)
    }

    private func respectRateLimit() async throws {
        let gap = Date().timeIntervalSince(lastRequestAt)
        if gap < minInterval {
            try await Task.sleep(nanoseconds: UInt64((minInterval - gap) * 1_000_000_000))
        }
        lastRequestAt = Date()
    }
}
