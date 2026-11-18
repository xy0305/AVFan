import Foundation

/// Parses the rendered FANZA official 有码 digital list
/// (`https://video.dmm.co.jp/av/list/?release=recent&sort=date`).
/// The server HTML is an empty Next.js shell; this expects the
/// WKWebView-rendered document (product cards, not `__NEXT_DATA__`).
enum FanzaTodayParser {
    static let officialListURL = URL(string: "https://video.dmm.co.jp/av/list/?release=recent&sort=date")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    struct Item: Equatable, Hashable, Codable {
        var cid: String
        var number: String
        var title: String
        var coverURL: String?
        var dateText: String?
    }

    struct Page: Equatable {
        /// Items that produced a catalog number and fall on JST today.
        var todayItems: [Item]
        /// Every dated card whose day is strictly before JST today
        /// (including cards later excluded for a missing 番号). Used
        /// to stop pagination.
        var sawEarlierDate: Bool
        /// Next `page=` value advertised in the rendered pagination,
        /// when present and greater than `currentPage`.
        var nextPage: Int?
    }

    /// Build the official list URL for a 1-based page. Page 1 omits
    /// the query so it matches the documented start URL; later pages
    /// use `page=N` as the live pagination links do.
    static func listURL(page: Int) -> URL {
        if page <= 1 { return officialListURL }
        var components = URLComponents(url: officialListURL, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.removeAll { $0.name == "page" }
        items.append(URLQueryItem(name: "page", value: String(page)))
        components?.queryItems = items
        return components?.url ?? officialListURL
    }

    static func jstDay(from date: Date, timeZone: TimeZone = tokyo) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    static func titleDate(from date: Date, timeZone: TimeZone = tokyo) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    /// Pull a catalog number out of on-card text (title first). Does
    /// not invent a number from a CID — that is `DMMCID.numberFromCID`.
    static func catalogNumber(in text: String) -> String? {
        let matches = JRHTML.matches(
            #"(?<![A-Z0-9])([0-9]{0,4}[A-Z]{2,10})[-_]?0*([0-9]{2,6})(?![A-Z0-9])"#,
            text.uppercased()
        )
        for match in matches {
            let raw = match[1] + "-" + match[2]
            if let parts = DMMCID.parts(raw) {
                return parts.label.uppercased() + "-" + String(parts.serial)
            }
        }
        return nil
    }

    /// Parse a rendered list page. `today` is compared in `timeZone`
    /// (Asia/Tokyo, never the Shanghai calendar). `datesByCID` overlays
    /// delivery/release days captured from the page's GraphQL/React
    /// payload when the visible card hides 配信日 for already-out titles.
    static func parse(
        _ html: String,
        today: Date,
        timeZone: TimeZone = tokyo,
        currentPage: Int = 1,
        datesByCID: [String: Date] = [:]
    ) -> Page {
        let todayDay = jstDay(from: today, timeZone: timeZone)
        let cards = cardBlocks(in: html)
        var todayItems: [Item] = []
        var sawEarlier = false
        var seen = Set<String>()

        for card in cards {
            let cid = card.cid.lowercased()
            let overlay = datesByCID[cid] ?? datesByCID[card.cid]
            let date = overlay ?? card.date
            if let date, compareDay(date, todayDay, timeZone: timeZone) == .orderedAscending {
                sawEarlier = true
            }
            guard let number = number(for: card) else { continue }
            let dayMatch: Bool
            if let date {
                dayMatch = compareDay(date, todayDay, timeZone: timeZone) == .orderedSame
            } else {
                // No visible/captured date: keep only while this page
                // has not already shown an earlier day (the official
                // list is date-sorted, newest first).
                dayMatch = !sawEarlier
            }
            guard dayMatch else { continue }
            let key = number.uppercased()
            guard seen.insert(key).inserted else { continue }
            todayItems.append(Item(
                cid: cid,
                number: number,
                title: card.title,
                coverURL: card.coverURL,
                dateText: card.dateText ?? formatDay(date, timeZone: timeZone)
            ))
        }

        return Page(
            todayItems: todayItems,
            sawEarlierDate: sawEarlier,
            nextPage: nextPage(in: html, current: currentPage)
        )
    }

    /// `page=` advertised by the rendered pagination that is strictly
    /// after `current`. The live list uses `?release=recent&sort=date&page=N`.
    static func nextPage(in html: String, current: Int) -> Int? {
        var found: [Int] = []
        // Rendered markup often entity-encodes the query (`&amp;page=2`).
        for match in JRHTML.matches(#"[?&](?:amp;)?page=(\d+)"#, html) {
            if let value = Int(match[1]) { found.append(value) }
        }
        let later = found.filter { $0 > current }
        return later.min()
    }

    static func parseDate(_ raw: String, timeZone: TimeZone = tokyo) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let patterns = [
            #"(\d{4})[/-](\d{1,2})[/-](\d{1,2})"#,
            #"(\d{4})年(\d{1,2})月(\d{1,2})日?"#,
        ]
        for pattern in patterns {
            if let match = JRHTML.matches(pattern, trimmed).first,
               let year = Int(match[1]),
               let month = Int(match[2]),
               let day = Int(match[3]),
               year >= 2000, month >= 1, month <= 12, day >= 1, day <= 31 {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withFullDate]
        return iso.date(from: trimmed)
    }

    // MARK: - Cards

    fileprivate struct RawCard {
        var cid: String
        var title: String
        var text: String
        var coverURL: String?
        var date: Date?
        var dateText: String?
    }

    private static func cardBlocks(in html: String) -> [RawCard] {
        var blocks: [String] = []
        let ns = html as NSString
        let starts = startIndexes(of: #"data-e2eid\s*=\s*["']content-card["']"#, in: html)
        if !starts.isEmpty {
            var ends = starts
            ends.append(ns.length)
            if let pagination = startIndexes(of: #"data-e2eid\s*=\s*["']pagination["']"#, in: html).first {
                ends[ends.count - 1] = pagination
            }
            for index in 0..<starts.count {
                let from = starts[index]
                let to = min(ends[index + 1], ns.length)
                if to > from {
                    blocks.append(ns.substring(with: NSRange(location: from, length: to - from)))
                }
            }
        } else {
            // Fallback when the live class names change but content
            // links remain: one block per /av/content/?id= occurrence.
            let matches = JRHTML.matches(#"(?i)(?:/av)?/content/\?id=([a-z0-9_]+)"#, html)
            var seen = Set<String>()
            for match in matches {
                let cid = match[1].lowercased()
                guard seen.insert(cid).inserted else { continue }
                blocks.append(surroundingBlock(of: cid, in: html))
            }
        }

        var cards: [RawCard] = []
        var seen = Set<String>()
        for block in blocks {
            guard let card = rawCard(in: block), seen.insert(card.cid.lowercased()).inserted else { continue }
            cards.append(card)
        }
        return cards
    }

    private static func startIndexes(of pattern: String, in html: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map(\.range.location)
    }

    private static func surroundingBlock(of cid: String, in html: String) -> String {
        let ns = html as NSString
        let found = ns.range(of: "id=" + cid, options: .caseInsensitive)
        guard found.location != NSNotFound else { return html }
        let from = max(0, found.location - 400)
        let to = min(ns.length, found.location + found.length + 1200)
        return ns.substring(with: NSRange(location: from, length: to - from))
    }

    private static func rawCard(in html: String) -> RawCard? {
        guard let cid = extractCID(from: html) else { return nil }
        let text = visibleText(in: html)
        let title = extractTitle(from: html, text: text)
        let dateText = extractDateText(from: text)
        return RawCard(
            cid: cid,
            title: title,
            text: text,
            coverURL: extractCover(from: html, cid: cid),
            date: dateText.flatMap { parseDate($0) },
            dateText: dateText
        )
    }

    private static func extractCID(from html: String) -> String? {
        if let match = JRHTML.matches(#"(?i)(?:/av)?/content/\?id=([a-z0-9_]+)"#, html).first {
            return match[1]
        }
        if let match = JRHTML.matches(#"(?i)/digital/video/([a-z0-9_]+)/"#, html).first {
            return match[1]
        }
        return nil
    }

    private static func extractTitle(from html: String, text: String) -> String {
        if let match = JRHTML.matches(
            #"(?is)data-e2eid\s*=\s*["']title["'][^>]*>(.*?)</"#,
            html
        ).first {
            let value = JRHTML.text(stripTags(match[1]))
            if !value.isEmpty { return value }
        }
        if let match = JRHTML.matches(#"(?is)<img[^>]+alt=["']([^"']+)["']"#, html).first {
            let value = JRHTML.text(match[1])
            if !value.isEmpty, value != "パッケージ画像" { return value }
        }
        // First meaningful line of visible text, skipping labels.
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "|" }) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, !value.hasPrefix("配信"), !value.hasPrefix("発売"),
               !value.hasPrefix("お気に入り"), value != "パッケージ画像" {
                return value
            }
        }
        return text
    }

    private static func extractDateText(from text: String) -> String? {
        let labeled = JRHTML.matches(
            #"(?:配信開始日|配信開始|配信日|発売日|発売)\s*[:：]?\s*(\d{4}[/-]\d{1,2}[/-]\d{1,2}|\d{4}年\d{1,2}月\d{1,2}日?)"#,
            text
        )
        if let match = labeled.first { return match[1] }
        if let match = JRHTML.matches(#"(\d{4}[/-]\d{1,2}[/-]\d{1,2}|\d{4}年\d{1,2}月\d{1,2}日?)"#, text).first {
            return match[0]
        }
        return nil
    }

    private static func extractCover(from html: String, cid: String) -> String? {
        var candidates: [String] = []
        let patterns = [
            #"(?is)<img[^>]+(?:src|data-src)\s*=\s*["']([^"']+)["']"#,
            #"(?is)<source[^>]+srcset\s*=\s*["']([^"'\s]+)["']"#,
        ]
        for pattern in patterns {
            for match in JRHTML.matches(pattern, html) {
                candidates.append(match[1])
            }
        }
        for raw in candidates {
            guard let clean = normalizedImageURL(raw, cid: cid) else { continue }
            return clean
        }
        return nil
    }

    private static func normalizedImageURL(_ raw: String, cid: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        if path.contains("now_printing") || path.contains("/bnr_") || path.contains("/common/") {
            return nil
        }
        let isDMM = host.contains("dmm.co.jp") || host.contains("awsimgsrc") || host.contains("dmm.com")
        guard isDMM else { return nil }
        if !path.contains(cid.lowercased()) && !path.contains("/digital/video/") && !path.contains("/mono/movie/") {
            return nil
        }
        return trimmed
    }

    private static func number(for card: RawCard) -> String? {
        if let fromTitle = catalogNumber(in: card.title) { return fromTitle }
        if let fromText = catalogNumber(in: card.text) { return fromText }
        return DMMCID.numberFromCID(card.cid)
    }

    private static func visibleText(in html: String) -> String {
        JRHTML.text(stripTags(html))
    }

    private static func stripTags(_ html: String) -> String {
        var result = html
        if let regex = try? NSRegularExpression(pattern: #"<[^>]+>"#, options: [.dotMatchesLineSeparators]) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: " "
            )
        }
        return result
    }

    private static func compareDay(_ date: Date, _ day: DateComponents, timeZone: TimeZone) -> ComparisonResult {
        let other = jstDay(from: date, timeZone: timeZone)
        let lhs = (other.year ?? 0, other.month ?? 0, other.day ?? 0)
        let rhs = (day.year ?? 0, day.month ?? 0, day.day ?? 0)
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private static func formatDay(_ date: Date?, timeZone: TimeZone) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }
}
