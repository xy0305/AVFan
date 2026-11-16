import Foundation

actor SiteClient {
    static let shared = SiteClient()

    nonisolated static let mobileSafariUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"

    private let session: URLSession
    private let minInterval: TimeInterval = 1.0
    private var lastRequestAt: Date = .distantPast
    private let cacheTTL: TimeInterval = 12 * 60
    private var memoryCache: [String: (html: String, source: FetchSource, storedAt: Date)] = [:]
    private let cacheDir: URL

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        self.session = session ?? URLSession(configuration: config)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheDir = caches.appendingPathComponent("AVFanHTML", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func clearCache() {
        memoryCache.removeAll()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    nonisolated func homeURL(locale: SiteLocale) -> URL {
        URL(string: "https://avfan.com/\(locale.rawValue)")!
    }

    nonisolated func movieURL(pathID: String, locale: SiteLocale, href: String? = nil) -> URL {
        if let href, let url = URL(string: HTMLParser.absoluteURL(href, locale: locale)) {
            return url
        }
        return URL(string: "https://avfan.com/\(locale.rawValue)/movies/\(pathID)")!
    }

    nonisolated func rankingURL(_ kind: RankingKind, locale: SiteLocale) -> URL {
        URL(string: "https://avfan.com/\(locale.rawValue)/\(kind.path)")!
    }

    /// Ranking sub-category paths come from the ranking page's own links
    /// (they already carry a locale prefix); re-apply the requested locale.
    nonisolated func rankingURL(path: String, locale: SiteLocale) -> URL {
        pageURL(path: path, locale: locale)
    }

    /// Locale-prefixed URL for a site-relative page path (news list /
    /// article, series index / detail…). Full http(s) paths pass through.
    nonisolated func pageURL(path: String, locale: SiteLocale) -> URL {
        if path.hasPrefix("http"), let url = URL(string: path) { return url }
        return URL(string: "https://avfan.com/\(locale.rawValue)/\(HTMLParser.stripLocale(path))")!
    }

    nonisolated func searchURL(query: String) -> URL {
        searchURL(query: query, st: "all")
    }

    /// Search URL for one result type (build 24): the site's own
    /// st values — all / movie / cast / series / maker / director.
    nonisolated func searchURL(query: String, st: String) -> URL {
        var components = URLComponents(string: "https://avfan.com/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "st", value: st),
        ]
        return components.url!
    }

    nonisolated func catalogURL(path: String) -> URL {
        if path.hasPrefix("http") { return URL(string: path)! }
        return URL(string: HTMLParser.absoluteURL(path))!
    }

    func html(
        for url: URL,
        locale: SiteLocale,
        ageCookie: String?,
        allowWebViewFallback: Bool,
        expectCatalog: Bool
    ) async throws -> (html: String, source: FetchSource) {
        let key = url.absoluteString
        if let cached = cachedValue(for: key) {
            return cached
        }

        do {
            let html = try await fetchWithURLSession(url: url, locale: locale, ageCookie: ageCookie)
            if HTMLParser.isBlocked(html, status: nil) {
                throw SiteClientError.blocked(status: 403, url: url)
            }
            if expectCatalog && !HTMLParser.hasCatalogItems(html) {
                throw SiteClientError.emptyPage(url: url)
            }
            store(html: html, source: .urlSession, key: key)
            await rememberSession(html: html, url: url)
            return (html, .urlSession)
        } catch {
            let shouldFallback: Bool
            if case SiteClientError.blocked = error { shouldFallback = true }
            else if case SiteClientError.emptyPage = error { shouldFallback = true }
            else if let urlError = error as? URLError, urlError.code == .userAuthenticationRequired {
                shouldFallback = true
            } else if let raw = error as? HTTPStatusError, raw.status == 403 || raw.status == 429 || raw.status == 503 {
                shouldFallback = true
            } else {
                shouldFallback = false
            }

            if shouldFallback && allowWebViewFallback {
                let html = try await fetchWithWebView(url: url, ageCookie: ageCookie)
                if HTMLParser.isBlocked(html, status: nil) {
                    throw SiteClientError.blocked(status: 403, url: url)
                }
                if expectCatalog && !HTMLParser.hasCatalogItems(html) {
                    throw SiteClientError.emptyPage(url: url)
                }
                store(html: html, source: .wkWebView, key: key)
                await rememberSession(html: html, url: url)
                return (html, .wkWebView)
            }

            if let raw = error as? HTTPStatusError, raw.status == 403 || raw.status == 429 {
                throw SiteClientError.blocked(status: raw.status, url: url)
            }
            throw error
        }
    }

    /// Authenticated JSON call in the site's own session (the shared
    /// cookie store the login flow populates), mirroring the page's own
    /// fetch() calls for the library actions: JSON body, CSRF header,
    /// same rate limit as page fetches. HTTP statuses are RETURNED, not
    /// thrown — the site's own code treats 401/403 as "go sign in", and
    /// the caller needs the JSON message either way.
    func jsonRequest(
        method: String,
        url: URL,
        csrf: String?,
        body: [String: Any]? = nil
    ) async throws -> (status: Int, json: [String: Any]?) {
        try await respectRateLimit()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Self.mobileSafariUA, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://avfan.com/", forHTTPHeaderField: "Referer")
        if let csrf { request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (status, json)
    }

    /// HTML fragment fetch in the site's session, mirroring the
    /// page's own XHR fragment loads (cast details panel, review
    /// lists). Returns the raw fragment text.
    func fragment(for url: URL, csrf: String?) async throws -> String {
        try await respectRateLimit()
        var request = URLRequest(url: url)
        request.setValue(Self.mobileSafariUA, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://avfan.com/", forHTTPHeaderField: "Referer")
        if let csrf { request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SiteClientError.transport("HTTP \(status)")
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private func fetchWithURLSession(url: URL, locale: SiteLocale, ageCookie: String?) async throws -> String {
        try await respectRateLimit()
        await CookieBridge.applyLegalAge(ageCookie != nil)
        var request = URLRequest(url: url)
        request.setValue(Self.mobileSafariUA, forHTTPHeaderField: "User-Agent")
        request.setValue(acceptLanguage(for: locale), forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("https://avfan.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 || status == 429 || status == 503 {
            throw HTTPStatusError(status: status)
        }
        guard (200..<400).contains(status) else {
            throw SiteClientError.transport("HTTP \(status)")
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private func fetchWithWebView(url: URL, ageCookie: String?) async throws -> String {
        try await respectRateLimit()
        await CookieBridge.applyLegalAge(ageCookie != nil)
        let html = try await WebViewFetcher.shared.html(for: url, ageCookie: ageCookie)
        await CookieBridge.exportWebKitToShared()
        return html
    }

    private func respectRateLimit() async throws {
        let gap = Date().timeIntervalSince(lastRequestAt)
        if gap < minInterval {
            let delay = minInterval - gap
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        lastRequestAt = Date()
    }

    private func acceptLanguage(for locale: SiteLocale) -> String {
        switch locale {
        case .zhCN: return "zh-CN,zh;q=0.9,en;q=0.5"
        case .zhTW: return "zh-TW,zh;q=0.9,en;q=0.5"
        case .ja: return "ja,en;q=0.6"
        case .ko: return "ko,en;q=0.6"
        case .th: return "th,en;q=0.6"
        case .en: return "en-US,en;q=0.9"
        }
    }

    private func cachedValue(for key: String) -> (html: String, source: FetchSource)? {
        if let entry = memoryCache[key], Date().timeIntervalSince(entry.storedAt) < cacheTTL {
            return (entry.html, .cache)
        }
        let file = cacheFile(for: key)
        guard let data = try? Data(contentsOf: file),
              let html = String(data: data, encoding: .utf8) else { return nil }
        let storedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        guard Date().timeIntervalSince(storedAt) < cacheTTL else { return nil }
        memoryCache[key] = (html, .cache, storedAt)
        return (html, .cache)
    }

    private func store(html: String, source: FetchSource, key: String) {
        memoryCache[key] = (html, source, Date())
        try? html.data(using: .utf8)?.write(to: cacheFile(for: key), options: .atomic)
    }

    private func cacheFile(for key: String) -> URL {
        let name = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return cacheDir.appendingPathComponent(name)
    }

    private func rememberSession(html: String, url: URL) async {
        await MainActor.run {
            SiteSession.shared.applyPageSignals(html: html, url: url)
        }
    }
}

struct HTTPStatusError: Error {
    var status: Int
}
