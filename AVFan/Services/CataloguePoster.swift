//
//  CataloguePoster.swift
//  AVFan
//
//  AVDB's avbase catalogue lookup, ported for cover discovery only:
//  a cookie-free search on avbase.net by catalog number, an identity-
//  checked record selection from the page's Next.js props, and the
//  record's bound images (DMM pair, DUGA jacket, MGS package extras).
//  No account state, no credentials; a challenge or ambiguous answer
//  is a cached miss. Independently implemented from public response
//  schemas, following AVDB's CatalogueMetadata.
//

import Foundation

enum CatalogueIdentity {
    /// NFKC fold + uppercase (AVDB's JRPolicy.foldedCode contract).
    static func foldedCode(_ raw: String) -> String {
        raw.precomposedStringWithCompatibilityMapping.uppercased()
    }

    static func parts(_ raw: String) -> (prefix: String, serial: String)? {
        let text = foldedCode(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        // Digit-bearing labels require an explicit separator: R18292 is ambiguous.
        let patterns = [#"^([A-Z]{1,4}[0-9]{1,4})[-_ ]([0-9]{2,10})$"#,
                        #"^([0-9]{1,4}[A-Z]{2,12})[-_ ]?([0-9]{2,10})$"#,
                        #"^([A-Z]{2,12})[-_ ]?([0-9]{2,10})$"#]
        for pattern in patterns {
            if let m = JRHTML.matches(pattern, text).first { return (m[1], m[2]) }
        }
        return nil
    }

    static func key(_ raw: String) -> String? {
        guard let p = parts(raw), !p.prefix.hasPrefix("FC2"), let n = UInt64(p.serial), n > 0 else { return nil }
        return p.prefix + "-" + String(n)
    }

    static func withoutLeadingDigits(_ raw: String) -> String? {
        guard let p = parts(raw), p.prefix.first?.isNumber == true else { return nil }
        return key(String(p.prefix.drop(while: { $0.isNumber })) + "-" + p.serial)
    }

    static func matches(_ candidate: String, wanted: String) -> Bool {
        guard let a = key(candidate), let b = key(wanted) else { return false }
        if a == b { return true }
        // Only absent leading digits, never two different numeric namespaces.
        return withoutLeadingDigits(candidate) == b || withoutLeadingDigits(wanted) == a
    }

    static func queryForms(_ number: String) -> [String] {
        guard let p = parts(number) else { return [] }
        var forms = [p.prefix + "-" + p.serial, p.prefix + p.serial]
        if p.prefix.first?.isNumber == true {
            forms.append(String(p.prefix.drop(while: { $0.isNumber })) + "-" + p.serial)
        }
        var seen = Set<String>(); return forms.filter { seen.insert($0).inserted }
    }
}

struct ScrapedMetadata: Sendable, Hashable {
    let number: String
    let sourceURL: String
    var title: String?
    var releaseDate: String?
    var duration: Int?
    var actorNames: [String] = []
    var maker: String?
    var publisher: String?
    var series: String?
    var poster: String?
    var cover: String?
    var digitalCID: String?
    /// Same-work HQ jackets from other stores (DUGA 1000 px jacket,
    /// MGS Prestige package, MGS pf_e portrait).
    var extras: [String] = []
    // HQ-first: large cover (pl / package large) before package thumb (ps).
    var images: [String] { var seen = Set<String>(); return ([cover, poster].compactMap { $0 } + extras).filter { seen.insert($0).inserted } }
}

enum AvbaseMetadata {
    static let origin = "https://www.avbase.net"

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func props(_ html: String) -> [String: Any]? {
        guard html.utf8.count <= 2 * 1024 * 1024 else { return nil }
        let blocks = JRHTML.matches(#"<script\b([^>]*)>(.*?)</script\s*>"#, html)
        let matches = blocks.filter { !JRHTML.matches(#"(?:^|\s)id\s*=\s*[\"']__NEXT_DATA__[\"']"#, $0[1]).isEmpty }
        guard matches.count == 1, let data = matches[0][2].data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = root["props"] as? [String: Any] else { return nil }
        return props["pageProps"] as? [String: Any]
    }

    static func path(_ work: [String: Any]) -> String? {
        guard let number = string(work["work_id"]), CatalogueIdentity.key(number) != nil,
              number.range(of: #"^[A-Za-z0-9_-]{3,80}$"#, options: .regularExpression) != nil else { return nil }
        let prefix = string(work["prefix"]) ?? ""
        guard prefix.range(of: #"^[A-Za-z0-9_-]{0,80}$"#, options: .regularExpression) != nil else { return nil }
        return "/works/" + (prefix.isEmpty ? "" : prefix + ":") + number
    }

    static func selected(_ works: [[String: Any]], number: String) -> [String: Any]? {
        guard let key = CatalogueIdentity.key(number) else { return nil }
        let exact = works.filter { CatalogueIdentity.key(string($0["work_id"]) ?? "") == key }
        let loose = works.filter { CatalogueIdentity.matches(string($0["work_id"]) ?? "", wanted: number) }
        var pool = exact.isEmpty ? loose : exact
        // A missing numeric prefix is accepted only for a unique identity group.
        guard Set(pool.compactMap { CatalogueIdentity.key(string($0["work_id"]) ?? "") }).count == 1 else { return nil }
        if pool.count == 1 { return path(pool[0]) == nil ? nil : pool[0] }
        let productBound = pool.filter { work in
            (work["products"] as? [[String: Any]] ?? []).contains { CatalogueIdentity.key(string($0["product_id"]) ?? "") == key }
        }
        if !productBound.isEmpty { pool = productBound }
        if pool.count == 1 { return path(pool[0]) == nil ? nil : pool[0] }
        let canonical = pool.filter { string($0["prefix"]) == nil }
        return canonical.count == 1 && path(canonical[0]) != nil ? canonical[0] : nil
    }

    static func parse(html: String, number: String) -> ScrapedMetadata? {
        guard let data = props(html) else { return nil }
        let rows: [[String: Any]]
        if let work = data["work"] as? [String: Any] { rows = [work] }
        else { rows = data["works"] as? [[String: Any]] ?? [] }
        guard let work = selected(rows, number: number), let path = path(work) else { return nil }
        var result = ScrapedMetadata(number: number, sourceURL: origin + path)
        result.title = string(work["title"])
        result.releaseDate = date(string(work["min_date"]))
        let casts = (work["casts"] as? [[String: Any]] ?? []).compactMap { $0["actor"] as? [String: Any] }
        let actors = casts.isEmpty ? (work["actors"] as? [[String: Any]] ?? []) : casts
        result.actorNames = Array(Set(actors.filter { string($0["note"]) != "男優" }.compactMap { string($0["name"]) })).sorted()
        let products = work["products"] as? [[String: Any]] ?? []
        var bestRank = -1
        for product in products {
            result.maker = result.maker ?? name(product["maker"])
            result.publisher = result.publisher ?? name(product["label"])
            result.series = result.series ?? name(product["series"])
            if result.duration == nil, let item = product["iteminfo"] as? [String: Any] {
                let raw = string(item["volume"]) ?? ""
                if let minutes = Int(raw), minutes > 0, minutes < 2000 { result.duration = minutes }
                else if let m = JRHTML.matches(#"^([0-9]{1,2}):([0-5][0-9]):([0-5][0-9])$"#, raw).first {
                    result.duration = (Int(m[1]) ?? 0) * 60 + (Int(m[2]) ?? 0)
                }
            }
            guard let pid = string(product["product_id"]) else { continue }
            let dmm = DMMAmateurMetadata.link(string(product["url"]) ?? "")
            // CID is read from a linked product, NEVER synthesized from the number.
            if let dmm, dmm.cid == pid, dmm.amateur { result.digitalCID = result.digitalCID ?? dmm.cid }
            guard dmm?.cid == pid || (dmm == nil && CatalogueIdentity.matches(pid, wanted: number)) else { continue }
            let poster = image(string(product["thumbnail_url"]), productID: pid, dmm: dmm?.cid == pid, namespace: dmm?.imageRoot)
            let cover = image(string(product["image_url"]), productID: pid, dmm: dmm?.cid == pid, namespace: dmm?.imageRoot)
            guard poster != nil || cover != nil else { continue }
            // Score: prefer pl (large) over ps/jp; prefer digital video package over mono DVD.
            let coverURL = cover ?? poster!
            let rank = coverRank(coverURL) * 10 + (dmm?.imageRoot == "/digital/video/" || dmm?.imageRoot == "/digital/amateur/" ? 1 : 0)
            if rank > bestRank {
                bestRank = rank
                result.poster = poster ?? cover
                result.cover = cover ?? poster
            }
        }
        result.extras = AvbaseHQExtras.extras(products: products, number: number)
        return result
    }

    /// Higher is better: pl large jacket > jp amateur package > ps thumb.
    static func coverRank(_ url: String) -> Int {
        if url.hasSuffix("pl.jpg") { return 3 }
        if url.hasSuffix("jp.jpg") { return 2 }
        if url.hasSuffix("ps.jpg") { return 1 }
        return 0
    }

    static func name(_ value: Any?) -> String? { (value as? [String: Any]).flatMap { string($0["name"]) } }

    static func date(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if let iso = JRHTML.matches(#"^([0-9]{4}-[0-9]{2}-[0-9]{2})(?:T|$)"#, raw).first { return iso[1] }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 9 * 3600)
        f.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT'Z"
        guard let date = f.date(from: raw.components(separatedBy: " (")[0]) else { return nil }
        f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }

    static func image(_ raw: String?, productID: String, dmm: Bool, namespace: String? = nil) -> String? {
        guard let raw, let url = URL(string: raw), cleanImageURL(url) else { return nil }
        if ["pics.dmm.co.jp", "awsimgsrc.dmm.co.jp"].contains(url.host ?? "") {
            guard dmm, productID.range(of: #"^[a-z0-9_]{2,80}$"#, options: .regularExpression) != nil else { return nil }
            let relative = url.host == "awsimgsrc.dmm.co.jp" ? String(url.path.dropFirst("/pics_dig".count)) : url.path
            guard url.host != "awsimgsrc.dmm.co.jp" || url.path.hasPrefix("/pics_dig/") else { return nil }
            if let namespace, !relative.hasPrefix(namespace) { return nil }
            let expected = #"^/(?:digital/(?:video|amateur)/|mono/movie/(?:adult/|japanese/)?)"#
                + NSRegularExpression.escapedPattern(for: productID) + "/" + NSRegularExpression.escapedPattern(for: productID) + #"(ps|pl|jp)\.jpg$"#
            return JRHTML.matches(expected, relative).isEmpty ? nil : raw
        }
        if url.host == "image.mgstage.com", url.path.hasPrefix("/images/"), url.path.hasSuffix(".jpg"),
           let filename = url.lastPathComponent.lowercased().components(separatedBy: ".").first,
           let p = CatalogueIdentity.parts(productID),
           !JRHTML.matches(#"^(?:h1-|pf_|pb_)"#, filename).isEmpty,
           filename.hasSuffix(p.prefix.lowercased() + "-" + p.serial.lowercased()) { return raw }
        return nil
    }

    static func allowedDiscoveredImage(_ url: URL) -> Bool {
        let directories = url.path.split(separator: "/")
        guard directories.count >= 2 else { return false }
        let pid = String(directories[directories.count - 2])
        if image(url.absoluteString, productID: pid, dmm: true) != nil { return true }
        if AvbaseHQExtras.isDugaJacket(url) || AvbaseHQExtras.isMGSPrestigePackage(url) { return true }
        // MGS admission is used only after the exact-record product parser returned this URL.
        return cleanImageURL(url) && url.host == "image.mgstage.com" && url.path.hasPrefix("/images/")
            && url.path.hasSuffix(".jpg") && url.path.count < 300
    }

    static func cleanImageURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil
            && url.query == nil && url.fragment == nil && !url.absoluteString.contains("%")
    }
}

enum DMMAmateurMetadata {
    struct Link { let cid: String; let amateur: Bool; let imageRoot: String }

    static func link(_ raw: String) -> Link? {
        guard let initial = URLComponents(string: raw), initial.scheme == "https", initial.user == nil,
              initial.password == nil, initial.port == nil, initial.fragment == nil else { return nil }
        var target = initial
        if initial.host == "al.fanza.co.jp" {
            let links = (initial.queryItems ?? []).filter { $0.name == "lurl" }
            guard links.count == 1, let value = links[0].value, let decoded = URLComponents(string: value) else { return nil }
            target = decoded
        }
        guard target.scheme == "https", target.user == nil, target.password == nil,
              target.port == nil, target.fragment == nil else { return nil }
        if target.host == "video.dmm.co.jp", ["/av/content/", "/amateur/content/"].contains(target.path) {
            let ids = (target.queryItems ?? []).filter { $0.name == "id" }
            guard ids.count == 1, target.queryItems?.count == 1, let cid = ids[0].value,
                  cid.range(of: #"^[a-z0-9_]{2,80}$"#, options: .regularExpression) != nil else { return nil }
            return Link(cid: cid, amateur: target.path == "/amateur/content/", imageRoot: target.path == "/amateur/content/" ? "/digital/amateur/" : "/digital/video/")
        }
        if target.host == "www.dmm.co.jp", target.query == nil,
           let m = JRHTML.matches(#"^/mono/dvd/-/detail/=/cid=([a-z0-9_]{2,80})/$"#, target.path).first {
            return Link(cid: m[1], amateur: false, imageRoot: "/mono/movie/")
        }
        return nil
    }
}

/// Extra HQ jackets that avbase lists for the SAME work: DUGA jacket,
/// MGS Prestige package, MGS pf_e portrait derived from a listed pb_e.
enum AvbaseHQExtras {
    static func isDugaJacket(_ url: URL) -> Bool {
        AvbaseMetadata.cleanImageURL(url) && url.host == "pic.duga.jp"
            && url.path.range(of: #"^/unsecure/[a-z0-9_-]{2,40}/[0-9]{1,8}/noauth/jacket\.jpg$"#, options: .regularExpression) != nil
    }

    static func isMGSPrestigePackage(_ url: URL) -> Bool {
        AvbaseMetadata.cleanImageURL(url) && url.host == "image.mgstage.com"
            && url.path.range(of: #"^/images/prestige/[a-z0-9_-]{1,40}/[a-z0-9]{1,20}/[0-9a-z]{1,12}/pake-03_sp-[a-z0-9]{1,20}-[0-9a-z]{1,12}\.jpg$"#, options: .regularExpression) != nil
    }

    static func dugaLabel(_ url: URL) -> String? {
        let parts = url.path.split(separator: "/"); return parts.count > 2 ? String(parts[1]) : nil
    }

    static func mgsMaker(_ url: URL) -> String? {
        let parts = url.path.split(separator: "/"); return parts.count > 2 ? String(parts[1]) : nil
    }

    static func extras(products: [[String: Any]], number: String) -> [String] {
        var dugas: [URL] = []
        var mgs: [URL] = []
        for product in products {
            guard let pid = AvbaseMetadata.string(product["product_id"]) else { continue }
            let link = URL(string: AvbaseMetadata.string(product["url"]) ?? "")
            guard let raw = AvbaseMetadata.string(product["image_url"]), let image = URL(string: raw) else { continue }
            if link?.host == "click.duga.jp", isDugaJacket(image) { dugas.append(image) }
            if link?.host == "www.mgstage.com", image.host == "image.mgstage.com",
               CatalogueIdentity.matches(pid, wanted: number), AvbaseMetadata.cleanImageURL(image),
               let parts = CatalogueIdentity.parts(pid) {
                let suffix = parts.prefix.lowercased() + "-" + parts.serial.lowercased() + ".jpg"
                guard image.lastPathComponent.lowercased().hasSuffix(suffix) else { continue }
                mgs.append(image)
            }
        }
        var out: [String] = []
        for image in mgs {
            if isMGSPrestigePackage(image) { out.append(image.absoluteString) }
            if image.lastPathComponent.hasPrefix("pb_e_") {
                let pf = image.deletingLastPathComponent().appendingPathComponent("pf_e_" + image.lastPathComponent.dropFirst(5))
                if AvbaseMetadata.cleanImageURL(pf) { out.append(pf.absoluteString) }
            }
        }
        let makers = Set(mgs.compactMap(mgsMaker))
        let duga: URL? = dugas.count == 1 ? dugas[0] : {
            let matched = dugas.filter { dugaLabel($0).map(makers.contains) == true }
            return matched.count == 1 ? matched[0] : nil
        }()
        if let duga { out.insert(duga.absoluteString, at: 0) }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}

private final class CatalogueRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Cookie-free avbase lookup for cover discovery, with AVDB's cache
/// TTLs (1h positive / 5min negative).
actor CataloguePosterService {
    static let shared = CataloguePosterService()

    private struct Entry { let value: ScrapedMetadata?; let expires: Date }
    private var entries: [String: Entry] = [:]

    func lookup(number: String, timeout: TimeInterval = 4) async -> ScrapedMetadata? {
        guard let identity = CatalogueIdentity.key(number), !Task.isCancelled, timeout > 0 else { return nil }
        if let entry = entries[identity] {
            if entry.expires > Date() { return entry.value }
            entries[identity] = nil
        }
        let result = await Self.fetch(number: number, timeout: timeout)
        entries[identity] = Entry(value: result, expires: Date().addingTimeInterval(result == nil ? 300 : 3600))
        if entries.count > 128, let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key {
            entries[oldest] = nil
        }
        return result
    }

    private static func fetch(number: String, timeout: TimeInterval) async -> ScrapedMetadata? {
        let deadline = ProcessInfo.processInfo.systemUptime + min(6, max(0, timeout))
        for term in CatalogueIdentity.queryForms(number).prefix(3) {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, !Task.isCancelled else { break }
            var c = URLComponents(string: AvbaseMetadata.origin + "/works")!
            c.queryItems = [URLQueryItem(name: "q", value: term)]
            guard let url = c.url, let data = await request(url, timeout: remaining),
                  let html = String(data: data, encoding: .utf8) else { break }
            if let result = AvbaseMetadata.parse(html: html, number: number) { return result }
        }
        return nil
    }

    /// Plain public-page GET for the discovery sources (JavBus /
    /// Tenhow / avbase): cookie-free ephemeral session, no redirects,
    /// 2 MB cap, HTML only. Returns the body and the final URL.
    static func fetchPage(_ url: URL, timeout: TimeInterval) async -> (html: String, finalURL: URL)? {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              timeout > 0, !Task.isCancelled else { return nil }
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCredentialStorage = nil; c.urlCache = nil
        c.timeoutIntervalForRequest = timeout; c.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: c, delegate: CatalogueRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.timeoutInterval = timeout
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let finalURL = response.url,
                  response.expectedContentLength <= 2 * 1024 * 1024,
                  http.mimeType == "text/html" else { return nil }
            var data = Data()
            for try await byte in bytes { try Task.checkCancellation(); guard data.count < 2 * 1024 * 1024 else { return nil }; data.append(byte) }
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return (html, finalURL)
        } catch { return nil }
    }

    private static func request(_ url: URL, timeout: TimeInterval) async -> Data? {
        // Avbase HTML only: www.avbase.net exact origin, no body/credentials.
        guard url.scheme == "https", url.host == "www.avbase.net", url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil else { return nil }
        guard let page = await fetchPage(url, timeout: timeout) else { return nil }
        return page.html.data(using: .utf8)
    }
}
