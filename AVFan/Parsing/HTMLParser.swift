import Foundation

enum HTMLParser {
    static let localePrefixes = ["zh-CN", "zh-TW", "en", "ja", "ko", "th"]

    static func unescape(_ raw: String) -> String {
        var text = raw
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&nbsp;", " "),
            ("&rarr;", "→"),
        ]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "&#x([0-9a-fA-F]+);", with: "{$1}", options: .regularExpression)
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                if let range = Range(match.range(at: 1), in: text),
                   let value = UInt32(text[range]),
                   let scalar = UnicodeScalar(value) {
                    text.replaceSubrange(Range(match.range, in: text)!, with: String(Character(scalar)))
                }
            }
        }
        return text
    }

    static func stripTags(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return unescape(noTags).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let patterns = [
            "\(name)=\"([^\"]*)\"",
            "\(name)='([^']*)'",
        ]
        for pattern in patterns {
            if let match = firstMatch(pattern, in: tag) {
                return unescape(match)
            }
        }
        return nil
    }

    static func firstMatch(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    static func allMatches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > group, let r = Range(match.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }

    static func isBlocked(_ html: String, status: Int?) -> Bool {
        if let status, status == 403 || status == 429 || status == 503 { return true }
        let lowered = html.lowercased()
        if lowered.contains("just a moment") { return true }
        if lowered.contains("cf-browser-verification") { return true }
        if lowered.contains("attention required") && lowered.contains("cloudflare") { return true }
        if lowered.contains("why have i been blocked") { return true }
        return false
    }

    static func hasCatalogItems(_ html: String) -> Bool {
        if firstMoviePath(in: html) != nil { return true }
        if html.contains("data-magnet=") || html.contains("magnet:?") { return true }
        if html.contains("class=\"movie-info") || html.contains("class='movie-info") { return true }
        if html.contains("/casts/") && html.range(of: "/casts/[A-Za-z0-9]{8}", options: .regularExpression) != nil {
            return true
        }
        return false
    }

    static func firstMoviePath(in html: String) -> String? {
        firstMatch("(?:https://avfan\\.com)?(/?(?:zh-CN|zh-TW|en|ja|ko|th)?/movies/[A-Za-z0-9]{8})", in: html)
    }

    static func pathID(from href: String) -> String? {
        firstMatch("/movies/([A-Za-z0-9]{8})(?:[/?#]|$)", in: href)
    }

    static func absoluteURL(_ href: String, locale: SiteLocale = .zhCN) -> String {
        if href.hasPrefix("http://") || href.hasPrefix("https://") { return href }
        if href.hasPrefix("/") { return "https://avfan.com" + href }
        return "https://avfan.com/\(locale.rawValue)/" + href
    }

    static func extractCode(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = firstMatch("\\[([A-Z0-9]{2,10}-[A-Z0-9]{2,12})\\]", in: trimmed, options: [.caseInsensitive]) {
            return match.uppercased()
        }
        if let match = firstMatch("^\\s*([A-Z]{2,10}-?\\d{2,8}(?:-[A-Z0-9]+)?)\\s*$", in: trimmed, options: [.caseInsensitive]) {
            return match.uppercased()
        }
        if let match = firstMatch("\\b(FC2[-_]?PPV[-_]?\\d{5,8})\\b", in: trimmed, options: [.caseInsensitive]) {
            return match.uppercased().replacingOccurrences(of: "_", with: "-")
        }
        if let match = firstMatch("\\b([A-Z]{2,10}-\\d{2,8})\\b", in: trimmed, options: [.caseInsensitive]) {
            return match.uppercased()
        }
        return nil
    }

    // MARK: - Cards

    static func movieCards(in html: String) -> [MovieCard] {
        var cards: [MovieCard] = []
        var seen = Set<String>()
        guard let regex = try? NSRegularExpression(
            pattern: "<a([^>]*href=\"([^\"]*/movies/[A-Za-z0-9]{8})[^\"]*\"[^>]*)>(.*?)</a>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: html, range: range) {
            let tag = ns.substring(with: match.range(at: 1))
            let href = unescape(ns.substring(with: match.range(at: 2)))
            let inner = ns.substring(with: match.range(at: 3))
            guard let id = pathID(from: href) else { continue }

            let titleAttr = attribute("title", in: tag).map(unescape) ?? ""
            let imgSrc = firstMatch("<img[^>]+src=\"([^\"]+)\"", in: inner)
            let imgAlt = firstMatch("<img[^>]+alt=\"([^\"]*)\"", in: inner).map(unescape) ?? ""
            let bold = firstMatch("class=\"[^\"]*font-bold[^\"]*\"[^>]*>([^<]+)", in: inner)
                ?? firstMatch("<strong[^>]*>([^<]+)</strong>", in: inner)
            let sub = firstMatch("class=\"[^\"]*text-sm[^\"]*\"[^>]*>([^<]+)", in: inner)
                ?? firstMatch("<span class=\"[^\"]*line-clamp-1[^\"]*\"[^>]*>([^<]+)", in: inner)
            let date = firstMatch("class=\"[^\"]*text-xs[^\"]*\"[^>]*>\\s*(\\d{4}-\\d{2}-\\d{2})", in: inner)
            let rating = firstMatch("(\\d+(?:\\.\\d+)?分[^<]*)", in: inner)

            let code = extractCode(from: bold ?? "") ?? extractCode(from: titleAttr) ?? extractCode(from: imgAlt)
            var title = stripTags(sub ?? "")
            if title.isEmpty {
                if let code, titleAttr.contains(code) {
                    title = titleAttr.replacingOccurrences(of: "[\(code)]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                } else if !titleAttr.isEmpty {
                    title = titleAttr
                } else {
                    title = imgAlt
                }
            }
            if title.hasPrefix("["), let close = title.firstIndex(of: "]") {
                title = title[title.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            var badges: [String] = []
            for badge in allMatches("class=\"[^\"]*sub-tag[^\"]*\"[^>]*>([^<]+)", in: inner) {
                let label = stripTags(badge)
                if !label.isEmpty { badges.append(label) }
            }
            if inner.contains("可播放") { badges.append("可播放") }
            if inner.contains("最新上架") { badges.append("最新上架") }

            let incoming = MovieCard(
                pathID: id,
                href: href,
                code: code,
                title: title,
                coverURL: imgSrc.map { absoluteURL($0) },
                date: date,
                ratingText: rating.map(stripTags),
                badges: Array(Set(badges)),
                canPlay: inner.contains("可播放")
            )

            if let index = cards.firstIndex(where: { $0.pathID == id }) {
                if cards[index].code == nil { cards[index].code = incoming.code }
                if cards[index].title.isEmpty { cards[index].title = incoming.title }
                if cards[index].coverURL == nil { cards[index].coverURL = incoming.coverURL }
                if cards[index].date == nil { cards[index].date = incoming.date }
                if cards[index].ratingText == nil { cards[index].ratingText = incoming.ratingText }
                if incoming.canPlay { cards[index].canPlay = true }
                var merged = Set(cards[index].badges)
                merged.formUnion(incoming.badges)
                cards[index].badges = Array(merged)
            } else {
                seen.insert(id)
                cards.append(incoming)
            }
        }

        // Ranking-style: cover link and title link are separate. Merge covers into existing cards and add missing ones.
        if let coverRegex = try? NSRegularExpression(
            pattern: "<a([^>]*href=\"([^\"]*/movies/[A-Za-z0-9]{8})[^\"]*\"[^>]*)>[^<]*<img[^>]+src=\"([^\"]+)\"[^>]*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            for match in coverRegex.matches(in: html, range: range) {
                let href = unescape(ns.substring(with: match.range(at: 2)))
                let src = unescape(ns.substring(with: match.range(at: 3)))
                guard let id = pathID(from: href) else { continue }
                if let index = cards.firstIndex(where: { $0.pathID == id }) {
                    if cards[index].coverURL == nil {
                        cards[index].coverURL = absoluteURL(src)
                    }
                }
            }
        }
        return cards
    }

    static func home(from html: String) -> HomePage {
        let cards = movieCards(in: html)
        var sections: [HomeSection] = []

        // Featured "在线观看" / watch section: first <section> ...
        if let sectionHTML = firstMatch("<section[^>]*>([\\s\\S]*?)</section>", in: html) {
            let featured = movieCards(in: sectionHTML)
            if !featured.isEmpty {
                let title = firstMatch("text-lg font-bold[^>]*>[\\s\\S]*?</svg>\\s*([^<]+)", in: sectionHTML)
                    ?? firstMatch("<span[^>]*>\\s*([^<]{2,20})\\s*</span>", in: sectionHTML)
                    ?? "在线观看"
                let more = firstMatch("href=\"([^\"]+)\"[^>]*>\\s*查看全部", in: sectionHTML)
                sections.append(HomeSection(title: stripTags(title), cards: featured, moreHref: more))
            }
        }

        let featuredIDs = Set(sections.flatMap { $0.cards.map(\.pathID) })
        let rest = cards.filter { !featuredIDs.contains($0.pathID) }
        if !rest.isEmpty {
            sections.append(HomeSection(title: "最新磁链", cards: rest, moreHref: nil))
        }
        if sections.isEmpty, !cards.isEmpty {
            sections.append(HomeSection(title: "首页", cards: cards, moreHref: nil))
        }
        return HomePage(sections: sections)
    }

    static func ranking(from html: String) -> RankingPage {
        let heading = firstMatch("<h2[^>]*>([\\s\\S]*?)</h2>", in: html).map(stripTags)
            ?? firstMatch("<title>([^|<]+)", in: html).map(stripTags)
            ?? "排行榜"
        let cards = movieCards(in: html)
        var people: [NamedLink] = []
        var seen = Set<String>()
        for href in allMatches("href=\"([^\"]*/casts/[A-Za-z0-9]{8}[^\"]*)\"", in: html) {
            let id = firstMatch("/casts/([A-Za-z0-9]{8})", in: href) ?? href
            if !seen.insert(id).inserted { continue }
            if let name = firstMatch("href=\"[^\"]*/casts/\(id)[^\"]*\"[^>]*>([^<]+)", in: html) {
                let trimmed = stripTags(name)
                if !trimmed.isEmpty, trimmed != "推荐" {
                    people.append(NamedLink(name: trimmed, href: href, kind: "cast"))
                }
            }
        }
        return RankingPage(title: heading, cards: cards, people: people)
    }

    static func magnets(in html: String) -> [MagnetItem] {
        var items: [MagnetItem] = []
        var seen = Set<String>()

        if let regex = try? NSRegularExpression(
            pattern: "<div class=\"magnet-list-item\"[\\s\\S]*?</div>\\s*</div>",
            options: [.caseInsensitive]
        ) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let block = ns.substring(with: match.range)
                guard let raw = attribute("data-magnet", in: block) ?? firstMatch("href=\"(magnet:[^\"]+)\"", in: block) else { continue }
                let url = unescape(raw)
                if !seen.insert(url).inserted { continue }
                let name = firstMatch("class=\"[^\"]*break-all[^\"]*\"[^>]*>([^<]+)", in: block).map(stripTags)
                    ?? firstMatch("[?&]dn=([^&\"']+)", in: url).map { unescape($0.removingPercentEncoding ?? $0) }
                    ?? "磁力链接"
                let sizeKB = firstMatch("data-sort-size=\"(\\d+)\"", in: block).flatMap(Int.init)
                let files = firstMatch("data-sort-files=\"(\\d+)\"", in: block).flatMap(Int.init)
                let meta = firstMatch("<span>(\\d{4}-\\d{2}-\\d{2}[^<]*)</span>", in: block).map(stripTags)
                var date: String?
                var sizeText: String?
                var fileCount = files
                if let meta {
                    let parts = meta.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
                    for part in parts {
                        if part.range(of: "^\\d{4}-\\d{2}-\\d{2}", options: .regularExpression) != nil {
                            date = String(part.prefix(10))
                        } else if part.contains("文件"), let n = firstMatch("(\\d+)", in: part) {
                            fileCount = fileCount ?? Int(n)
                        } else if part.contains("GB") || part.contains("MB") || part.contains("KB") {
                            sizeText = part
                        }
                    }
                }
                if sizeText == nil, let sizeKB {
                    sizeText = formatSize(mb: sizeKB)
                }
                var tags: [String] = []
                for tag in allMatches("class=\"[^\"]*sub-tag[^\"]*\"[^>]*>([^<]+)", in: block) {
                    let label = stripTags(tag)
                    if !label.isEmpty { tags.append(label) }
                }
                items.append(MagnetItem(url: url, name: name, sizeText: sizeText, sizeKB: sizeKB, fileCount: fileCount, date: date, tags: tags))
            }
        }

        if items.isEmpty {
            for raw in allMatches("(?:data-magnet=|href=)\"(magnet:[^\"]+)\"", in: html) {
                let url = unescape(raw)
                if seen.insert(url).inserted {
                    let name = firstMatch("[?&]dn=([^&\"']+)", in: url).map { unescape($0.removingPercentEncoding ?? $0) } ?? "磁力链接"
                    items.append(MagnetItem(url: url, name: name, sizeText: nil, sizeKB: nil, fileCount: nil, date: nil, tags: []))
                }
            }
        }
        return items
    }

    /// `data-sort-size` on avfan magnet rows is already in megabytes.
    static func formatSize(mb: Int) -> String {
        if mb >= 1024 * 1024 {
            return String(format: "%.2fPB", Double(mb) / 1024.0 / 1024.0)
        }
        if mb >= 1024 {
            return String(format: "%.2fGB", Double(mb) / 1024.0)
        }
        return "\(mb)MB"
    }

    static func movieDetail(from html: String, url: URL?) -> MovieDetail {
        let pageURL = url?.absoluteString
            ?? firstMatch("property=\"og:url\"\\s+content=\"([^\"]+)\"", in: html)
            ?? ""
        let pathID = pathID(from: pageURL) ?? pathID(from: html) ?? ""
        let schema = firstMatch("<script[^>]*type=\"application/ld\\+json\"[^>]*>(\\{[\\s\\S]*?\"@type\"\\s*:\\s*\"VideoObject\"[\\s\\S]*?\\})</script>", in: html)
            ?? firstMatch("<script[^>]*type=\"application/ld\\+json\"[^>]*>(\\{[\\s\\S]*?VideoObject[\\s\\S]*?\\})</script>", in: html)

        var title = firstMatch("<h1[^>]*>([\\s\\S]*?)</h1>", in: html).map(stripTags)
            ?? firstMatch("property=\"og:title\"\\s+content=\"([^\"]+)\"", in: html).map { unescape($0).replacingOccurrences(of: " | AVFan", with: "") }
            ?? ""
        var cover = firstMatch("property=\"og:image\"\\s+content=\"([^\"]+)\"", in: html)
            ?? firstMatch("thumbnailUrl\"\\s*:\\s*\"([^\"]+)\"", in: html)
        var summary = firstMatch("property=\"og:description\"\\s+content=\"([^\"]+)\"", in: html).map(unescape)
        var releaseDate = definition(named: "发行日期", in: html) ?? firstMatch("uploadDate\"\\s*:\\s*\"([0-9T:+-]+)\"", in: html).map { String($0.prefix(10)) }
        var duration = definition(named: "片长", in: html)
        var rating: Double?
        var ratingCount: Int?

        if let schema, let data = schema.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if title.isEmpty, let name = obj["name"] as? String { title = unescape(name) }
            if cover == nil, let thumb = obj["thumbnailUrl"] as? String { cover = thumb }
            if summary == nil, let desc = obj["description"] as? String { summary = unescape(desc) }
            if releaseDate == nil, let upload = obj["uploadDate"] as? String { releaseDate = String(upload.prefix(10)) }
            if duration == nil, let iso = obj["duration"] as? String, let minutes = firstMatch("PT(\\d+)M", in: iso) {
                duration = "\(minutes) 分钟"
            }
            if let agg = obj["aggregateRating"] as? [String: Any] {
                rating = (agg["ratingValue"] as? NSNumber)?.doubleValue ?? Double("\(agg["ratingValue"] ?? "")")
                ratingCount = (agg["ratingCount"] as? NSNumber)?.intValue ?? Int("\(agg["ratingCount"] ?? "")")
            }
        }

        let code = firstMatch("data-number=\"([^\"]+)\"", in: html)
            ?? firstMatch("class=\"[^\"]*movie-number[^\"]*\"[^>]*>([\\s\\S]*?)</span>", in: html).map { stripTags($0).replacingOccurrences(of: " ", with: "") }
            ?? extractCode(from: title)

        if let code, title.hasPrefix(code) {
            title = title.replacingOccurrences(of: code, with: "", options: [], range: title.startIndex..<title.index(title.startIndex, offsetBy: min(code.count + 1, title.count))).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return MovieDetail(
            pathID: pathID,
            pageURL: pageURL,
            code: code,
            title: title,
            coverURL: cover,
            summary: summary,
            releaseDate: releaseDate,
            duration: duration,
            rating: rating,
            ratingCount: ratingCount,
            makers: links(in: definitionHTML(named: "制作商", in: html) ?? "", kind: "maker"),
            publishers: links(in: definitionHTML(named: "发行商", in: html) ?? "", kind: "publisher"),
            directors: links(in: definitionHTML(named: "导演", in: html) ?? "", kind: "director"),
            series: links(in: html, kind: "series", pathHint: "/series/"),
            casts: links(in: definitionHTML(named: "演员", in: html) ?? "", kind: "cast"),
            tags: links(in: definitionHTML(named: "标签", in: html) ?? "", kind: "tag"),
            magnets: magnets(in: html),
            watchStreams: watchStreams(in: html, pageURL: pageURL)
        )
    }


    /// Public HTML media only: ld+json VideoObject contentUrl / <video><source> / visible m3u8|mp4.
    /// Skips /api/ paths and non-http(s) schemes. Covers are never treated as streams.
    static func watchStreams(in html: String, pageURL: String) -> [WatchStream] {
        var results: [WatchStream] = []
        var seen = Set<String>()
        func accept(_ raw: String, label: String) {
            let trimmed = unescape(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            let path = url.path.lowercased()
            if path.contains("/api/") { return }
            let isMedia = path.hasSuffix(".m3u8") || path.hasSuffix(".mp4") || path.hasSuffix(".m4v")
                || path.contains(".m3u8") || (path.hasSuffix(".mp4") && !path.contains("/covers/"))
            guard isMedia else { return }
            if seen.insert(url.absoluteString).inserted {
                results.append(WatchStream(url: url.absoluteString, label: label))
            }
        }
        if let content = firstMatch("contentUrl"\s*:\s*"([^"]+)"", in: html) {
            accept(content, label: "在线观看")
        }
        if let regex = try? NSRegularExpression(pattern: "<source[^>]+src=["']([^"']+)["'][^>]*>", options: [.caseInsensitive]) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                accept(ns.substring(with: match.range(at: 1)), label: "在线观看")
            }
        }
        if let regex = try? NSRegularExpression(pattern: "<video[^>]+src=["']([^"']+)["']", options: [.caseInsensitive]) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                accept(ns.substring(with: match.range(at: 1)), label: "在线观看")
            }
        }
        if let regex = try? NSRegularExpression(pattern: "https?://[^\s"'<>]+\.(m3u8|mp4|m4v)(\?[^\s"'<>]*)?", options: [.caseInsensitive]) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                accept(ns.substring(with: match.range), label: "在线观看")
            }
        }
        _ = pageURL
        return results
    }

    private static func definition(named label: String, in html: String) -> String? {
        definitionHTML(named: label, in: html).map(stripTags).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func definitionHTML(named label: String, in html: String) -> String? {
        firstMatch("<dt[^>]*>\\s*\(NSRegularExpression.escapedPattern(for: label))\\s*</dt>\\s*<dd[^>]*>([\\s\\S]*?)</dd>", in: html)
    }

    private static func links(in html: String, kind: String, pathHint: String? = nil) -> [NamedLink] {
        var results: [NamedLink] = []
        var seen = Set<String>()
        let pattern: String
        if let pathHint {
            pattern = "href=\"([^\"]*\(NSRegularExpression.escapedPattern(for: pathHint))[^\"]*)\"[^>]*>([^<]+)"
        } else {
            pattern = "href=\"([^\"]+)\"[^>]*>([^<]+)"
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = unescape(ns.substring(with: match.range(at: 1)))
            let name = stripTags(ns.substring(with: match.range(at: 2)))
            guard !name.isEmpty, seen.insert(href + name).inserted else { continue }
            if pathHint == nil, href.contains("/advanced_search") || href.contains("javascript:") { continue }
            results.append(NamedLink(name: name, href: href, kind: kind))
        }
        return results
    }
}
