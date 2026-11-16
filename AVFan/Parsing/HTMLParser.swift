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

    /// Parsing is pure CPU work over large HTML. Running it on the main actor
    /// froze navigation transitions (build 5: entering a detail page stalled
    /// ~1.7 s mid-push), so view models parse through this detached hop.
    static func detached<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// "/zh-CN/rankings/fanza_ranking?t=daily" -> "rankings/fanza_ranking?t=daily".
    static func stripLocale(_ path: String) -> String {
        var p = path
        if p.hasPrefix("https://avfan.com") { p = String(p.dropFirst("https://avfan.com".count)) }
        if p.hasPrefix("/") { p.removeFirst() }
        for prefix in localePrefixes where p.hasPrefix(prefix + "/") {
            p = String(p.dropFirst(prefix.count + 1))
            break
        }
        return p
    }

    /// Sub-category links a ranking page carries itself (FANZA/MGS tab bars,
    /// TOP300 category + year dropdowns, FC2 year tabs). The values are NOT
    /// guessable from outside (no archive has them), so the app reads the
    /// page's own anchors / select options whose locale-stripped path equals
    /// the ranking's base path. Pagination links (page=) are excluded; the
    /// currently shown variant is excluded too.
    static func rankingTabs(in html: String, basePath: String, currentPath: String) -> [NamedLink] {
        let base = stripLocale(basePath)
        let current = stripLocale(currentPath)
        var results: [NamedLink] = []
        var seen = Set<String>()
        func consider(href rawHref: String, label rawLabel: String) {
            let href = unescape(rawHref).trimmingCharacters(in: .whitespacesAndNewlines)
            let label = stripTags(rawLabel)
            guard !label.isEmpty, label.count <= 14 else { return }
            guard stripLocale(href) != current else { return }
            guard stripLocale(href).split(separator: "?").first.map(String.init) == base else { return }
            guard !href.contains("page=") else { return }
            guard seen.insert(stripLocale(href)).inserted else { return }
            results.append(NamedLink(name: label, href: href, kind: "ranktab"))
        }
        if let regex = try? NSRegularExpression(
            pattern: "<a[^>]+href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                consider(href: ns.substring(with: match.range(at: 1)), label: ns.substring(with: match.range(at: 2)))
            }
        }
        if let regex = try? NSRegularExpression(
            pattern: "<option[^>]+value=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</option>",
            options: [.caseInsensitive]
        ) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                consider(href: ns.substring(with: match.range(at: 1)), label: ns.substring(with: match.range(at: 2)))
            }
        }
        return results
    }

    /// The site paginates catalog/search/ranking lists with page= links; the
    /// app turns that into infinite scroll. Returns the href of the page
    /// after `currentPage` (rel=next wins, then a "下一页/Next" label, then
    /// the numbered link for currentPage + 1), or nil on the last page.
    static func nextPagePath(in html: String, currentPage: Int) -> String? {
        if let href = firstMatch("<link[^>]+rel=\"next\"[^>]+href=\"([^\"]+)\"", in: html)
            ?? firstMatch("<link[^>]+href=\"([^\"]+)\"[^>]+rel=\"next\"", in: html) {
            return unescape(href)
        }
        var numbered: String?
        var labelled: String?
        if let regex = try? NSRegularExpression(
            pattern: "<a([^>]+href=\"([^\"]+)\"[^>]*)>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let tag = ns.substring(with: match.range(at: 1))
                let href = unescape(ns.substring(with: match.range(at: 2)))
                guard let pageText = firstMatch("[?&]page=(\\d+)", in: href), let page = Int(pageText) else { continue }
                if tag.contains("rel=\"next\"") { return href }
                guard page == currentPage + 1 else { continue }
                let label = stripTags(ns.substring(with: match.range(at: 3)))
                if ["下一页", "下一頁", "下页", "Next", "next", "›", "»"].contains(label) {
                    labelled = labelled ?? href
                } else {
                    numbered = numbered ?? href
                }
            }
        }
        return labelled ?? numbered
    }

    // MARK: - Pagination, casts, prefixes, list filters (build 11)

    /// Every numbered pagination link a list page carries: page number →
    /// href. The site renders « 1 2 3 … 40 » bars (build 11 replaces
    /// infinite append with the site's own paging).
    static func pageMap(in html: String) -> [Int: String] {
        var map: [Int: String] = [:]
        if let regex = try? NSRegularExpression(
            pattern: "<a[^>]+href=\"([^\"]+)\"[^>]*>",
            options: [.caseInsensitive]
        ) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let href = unescape(ns.substring(with: match.range(at: 1)))
                guard let pageText = firstMatch("[?&]page=(\\d+)", in: href),
                      let page = Int(pageText), page >= 1 else { continue }
                if map[page] == nil { map[page] = href }
            }
        }
        return map
    }

    /// `path` with its page= parameter set to `page` (added when absent).
    static func withPage(_ path: String, page: Int) -> String {
        if let regex = try? NSRegularExpression(pattern: "([?&])page=\\d+") {
            let ns = path as NSString
            if let match = regex.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)) {
                let sep = ns.substring(with: match.range(at: 1))
                return ns.replacingCharacters(in: match.range, with: "\(sep)page=\(page)")
            }
        }
        return path + (path.contains("?") ? "&" : "?") + "page=\(page)"
    }

    /// Cast entries on the site's cast index pages (/casts?t=asian etc.):
    /// anchors to /casts/<id> wrapping an avatar image and the name; a
    /// works-count line, when present in the block, becomes the subtitle.
    static func castCards(in html: String) -> [CastCard] {
        var out: [CastCard] = []
        var seen = Set<String>()
        if let regex = try? NSRegularExpression(
            pattern: "<a[^>]+href=\"([^\"]*/casts/([A-Za-z0-9]{8})[^\"]*)\"[^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges >= 4 else { continue }
                let href = ns.substring(with: match.range(at: 1))
                let id = ns.substring(with: match.range(at: 2))
                let block = ns.substring(with: match.range(at: 3))
                guard seen.insert(id).inserted else { continue }
                let avatar = firstMatch("<img[^>]+(?:src|data-src|data-original)=\"([^\"]+)\"", in: block)
                    .map { unescape($0) }
                // Block text as lines: name is the first meaningful line,
                // a "NNN 部作品" style line is the count.
                let lines = block
                    .replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
                    .split(separator: "\n")
                    .map { unescape(String($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                var name: String?
                var count: String?
                for line in lines {
                    if count == nil,
                       line.range(of: "\\d+\\s*(部作品|部影片|部|works|Works)", options: .regularExpression) != nil {
                        count = line
                    } else if name == nil {
                        name = line
                    }
                }
                guard let name, !name.isEmpty else { continue }
                out.append(CastCard(name: name, href: unescape(href), avatarURL: avatar, countText: count))
            }
        }
        return out
    }

    /// 番号前缀 entries (/number_letters/<PREFIX>) wherever a page links
    /// them — the series tab reads them off the site's own pages instead
    /// of hardcoding a list that would rot.
    static func prefixLinks(in html: String) -> [NamedLink] {
        var out: [NamedLink] = []
        var seen = Set<String>()
        if let regex = try? NSRegularExpression(
            pattern: "<a[^>]+href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let href = unescape(ns.substring(with: match.range(at: 1)))
                let stripped = stripLocale(href)
                // stripLocale drops the leading slash: "number_letters/JUR".
                guard stripped.hasPrefix("number_letters/") else { continue }
                let segment = String(stripped.dropFirst("number_letters/".count))
                    .split(separator: "?").first.map(String.init) ?? ""
                guard !segment.isEmpty, !segment.contains("/") else { continue }
                guard seen.insert(stripped).inserted else { continue }
                let label = stripTags(ns.substring(with: match.range(at: 2)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let name = label.isEmpty
                    ? (segment.removingPercentEncoding ?? segment)
                    : label
                out.append(NamedLink(name: name, href: href, kind: "prefix"))
            }
        }
        return out
    }

    /// The list filter/sort form a catalog page carries (the JUR prefix
    /// page's 筛选 panel: feature checkboxes + sort radios). Parsed from
    /// the page's own checkbox/radio inputs and their labels — names,
    /// values and pre-selected options all come from the site. Returns
    /// nil when the page has no such form.
    static func listFilterForm(in html: String) -> ListFilterForm? {
        struct RawOption { var name: String; var value: String; var label: String; var radio: Bool; var selected: Bool }
        var raw: [RawOption] = []
        var capturedIDs = Set<String>()
        func inputFields(_ tag: String) -> (type: String, name: String, value: String, id: String, checked: Bool)? {
            guard let type = firstMatch("type=\"(checkbox|radio)\"", in: tag),
                  let name = firstMatch("name=\"([^\"]+)\"", in: tag) else { return nil }
            let value = firstMatch("value=\"([^\"]*)\"", in: tag) ?? "on"
            let id = firstMatch("id=\"([^\"]+)\"", in: tag) ?? ""
            let checked = tag.range(of: "\\bchecked(\\s|>|=)", options: .regularExpression) != nil
            return (type, unescape(name), unescape(value), id, checked)
        }
        // Pass 1: inputs wrapped in their <label>.
        if let regex = try? NSRegularExpression(
            pattern: "<label[^>]*>([\\s\\S]*?)</label>", options: [.caseInsensitive]
        ) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let block = ns.substring(with: match.range(at: 1))
                guard let tag = firstMatch("(<input[^>]*>)", in: block),
                      let fields = inputFields(tag) else { continue }
                let label = stripTags(block.replacingOccurrences(of: tag, with: " "))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { continue }
                raw.append(RawOption(name: fields.name, value: fields.value, label: label,
                                     radio: fields.type == "radio", selected: fields.checked))
                if !fields.id.isEmpty { capturedIDs.insert(fields.id) }
            }
        }
        // Pass 2: inputs associated via <label for="id">.
        if let regex = try? NSRegularExpression(
            pattern: "<input[^>]+type=\"(?:checkbox|radio)\"[^>]*>", options: [.caseInsensitive]
        ) {
            let ns = html as NSString
            var labelsByFor: [String: String] = [:]
            if let labelRegex = try? NSRegularExpression(
                pattern: "<label[^>]+for=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</label>", options: [.caseInsensitive]
            ) {
                for match in labelRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                    labelsByFor[ns.substring(with: match.range(at: 1))] =
                        stripTags(ns.substring(with: match.range(at: 2)))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let tag = ns.substring(with: match.range)
                guard let fields = inputFields(tag), !fields.id.isEmpty,
                      !capturedIDs.contains(fields.id),
                      let label = labelsByFor[fields.id], !label.isEmpty else { continue }
                raw.append(RawOption(name: fields.name, value: fields.value, label: label,
                                     radio: fields.type == "radio", selected: fields.checked))
                capturedIDs.insert(fields.id)
            }
        }
        // Group by input name, first-seen order; drop degenerate groups.
        var order: [String] = []
        var grouped: [String: [RawOption]] = [:]
        for option in raw {
            if grouped[option.name] == nil { order.append(option.name) }
            grouped[option.name, default: []].append(option)
        }
        var groups: [ListFilterGroup] = []
        for name in order.prefix(4) {
            guard let options = grouped[name], options.count >= 2 else { continue }
            let isRadio = options.first?.radio ?? false
            let looksLikeSort = options.contains {
                $0.label.contains("最新") || $0.label.contains("最高") || $0.label.contains("评分")
            }
            groups.append(ListFilterGroup(
                name: name,
                isRadio: isRadio,
                title: looksLikeSort ? "排序" : "筛选",
                options: options.prefix(12).map {
                    ListFilterOption(value: $0.value, label: $0.label, selected: $0.selected)
                }
            ))
        }
        return groups.isEmpty ? nil : ListFilterForm(groups: groups)
    }

    /// Rebuilds a list path with the chosen filter values applied: the
    /// form's own parameters are replaced, pagination resets (page=
    /// dropped), unrelated parameters are kept.
    static func applyingFilters(_ path: String, form: ListFilterForm, selections: [String: Set<String>]) -> String {
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        let base = parts.first ?? path
        let formNames = Set(form.groups.map(\.name))
        var pairs: [(String, String)] = []
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let key = kv.first, !formNames.contains(key), key != "page" else { continue }
                pairs.append((key, kv.count == 2 ? kv[1] : ""))
            }
        }
        for group in form.groups {
            let chosen = selections[group.name] ?? []
            let ordered = group.options.filter { chosen.contains($0.value) }
            for option in (group.isRadio ? Array(ordered.prefix(1)) : ordered) {
                pairs.append((group.name, option.value))
            }
        }
        guard !pairs.isEmpty else { return base }
        let query = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        return base + "?" + query
    }

    // MARK: - News （资讯） and series （系列） (build 6)

    /// The news categories the site labels items with (both script variants).
    static let newsCategoryNames = ["新片情報", "新人情報", "活動情報", "八卦", "業界",
                                    "新片情报", "新人情报", "活动情报"]

    private static func anchorBlocks(in html: String) -> [(href: String, inner: String, start: Int)] {
        var out: [(href: String, inner: String, start: Int)] = []
        guard let regex = try? NSRegularExpression(
            pattern: "<a[^>]+href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) else { return out }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out.append((href: ns.substring(with: match.range(at: 1)),
                        inner: ns.substring(with: match.range(at: 2)),
                        start: match.range.location))
        }
        return out
    }

    /// News list rows. A row links to /news/<8-char id> more than once
    /// (cover anchor + title anchor), so anchors are grouped by id: the
    /// title is the longest text any of them carries, the cover the first
    /// image, and date / category / comment count come from the HTML
    /// window around the group.
    static func newsItems(in html: String) -> [NewsItem] {
        var order: [String] = []
        var groups: [String: [(href: String, inner: String, start: Int)]] = [:]
        var firstStart: [String: Int] = [:]
        for anchor in anchorBlocks(in: html) {
            guard let id = firstMatch("/news/([A-Za-z0-9]{8})(?:[?#].*)?$", in: anchor.href) else { continue }
            if groups[id] == nil { order.append(id); firstStart[id] = anchor.start }
            groups[id, default: []].append(anchor)
        }
        let ns = html as NSString
        var items: [NewsItem] = []
        for (index, id) in order.enumerated() {
            let group = groups[id] ?? []
            var title = ""
            var cover: String?
            for anchor in group {
                let text = stripTags(anchor.inner)
                if text.count > title.count { title = text }
                if cover == nil {
                    cover = firstMatch("<img[^>]+(?:data-src|src)=\"([^\"]+)\"", in: anchor.inner)
                }
            }
            let start = max(0, (firstStart[id] ?? 0) - 600)
            let end = (index + 1 < order.count)
                ? (firstStart[order[index + 1]] ?? ns.length)
                : min(ns.length, (firstStart[id] ?? 0) + 3000)
            let window = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
            if cover == nil {
                cover = firstMatch("<img[^>]+(?:data-src|src)=\"([^\"]+)\"", in: window)
            }
            if title.isEmpty, let heading = firstMatch("<h[23][^>]*>([\\s\\S]*?)</h[23]>", in: window) {
                title = stripTags(heading)
            }
            guard !title.isEmpty else { continue }
            let comments = firstMatch("(\\d+)\\s*(?:条评论|條評論|则评论|則評論)", in: window)
                ?? firstMatch("(\\d+)\\s*(?:评论|評論|留言)", in: window)
            items.append(NewsItem(
                pathID: id,
                href: group.first?.href ?? "/news/\(id)",
                title: title,
                category: newsCategoryNames.first(where: { window.contains($0) }),
                author: nil,
                date: firstMatch("(\\d{4}-\\d{2}-\\d{2})", in: window),
                commentCount: comments.flatMap(Int.init),
                coverURL: cover.map { absoluteURL(unescape($0)) }
            ))
        }
        return items
    }

    /// One news article: headline, byline bits, the body as ordered text /
    /// image blocks, and the related movies / casts / same-category news
    /// the page carries below the body.
    static func newsArticle(from html: String, url: URL) -> NewsArticle {
        var article = NewsArticle(title: "")
        if let h1 = firstMatch("<h1[^>]*>([\\s\\S]*?)</h1>", in: html) {
            article.title = stripTags(h1)
        }
        if article.title.isEmpty,
           let og = firstMatch("<meta[^>]+property=\"og:title\"[^>]+content=\"([^\"]+)\"", in: html) {
            article.title = unescape(og)
        }
        let header = String(html.prefix(6000))
        article.category = newsCategoryNames.first(where: { header.contains($0) })
        article.date = firstMatch("(\\d{4}-\\d{2}-\\d{2})", in: header)

        // Body region: after the headline, before the related sections.
        var body = html
        if let h1End = html.range(of: "</h1>", options: .caseInsensitive) {
            body = String(html[h1End.upperBound...])
        }
        let endMarkers = ["相关影片", "相關影片", "相关女优", "相關女優", "同分类", "同分類",
                          "资讯评论", "資訊評論"]
        var bodyEnd = body.endIndex
        for marker in endMarkers {
            if let r = body.range(of: marker), r.lowerBound < bodyEnd { bodyEnd = r.lowerBound }
        }
        body = String(body[..<bodyEnd])

        // Ordered blocks: paragraphs and images in document order. Images
        // nested inside a paragraph are emitted just before its text.
        if let regex = try? NSRegularExpression(
            pattern: "<p[^>]*>([\\s\\S]*?)</p>|<img[^>]*>",
            options: [.caseInsensitive]
        ) {
            let ns = body as NSString
            for match in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                if match.range(at: 1).location != NSNotFound {
                    let inner = ns.substring(with: match.range(at: 1))
                    for src in allMatches("<img[^>]+(?:data-src|src)=\"([^\"]+)\"", in: inner) {
                        appendNewsImage(src, to: &article)
                    }
                    let text = stripTags(inner)
                    if text.count >= 2 { article.blocks.append(.text(text)) }
                } else {
                    let tag = ns.substring(with: match.range)
                    if let src = firstMatch("(?:data-src|src)=\"([^\"]+)\"", in: tag) {
                        appendNewsImage(src, to: &article)
                    }
                }
                if article.blocks.count > 160 { break }
            }
        }

        // Related sections (best effort, scoped to their own regions).
        let selfID = firstMatch("/news/([A-Za-z0-9]{8})", in: url.absoluteString)
        if let region = sectionRegion(in: html, markers: ["相关影片", "相關影片"],
                                      endMarkers: ["相关女优", "相關女優", "同分类", "同分類", "资讯评论", "資訊評論"]) {
            article.relatedMovies = Array(movieCards(in: region).prefix(12))
        }
        if let region = sectionRegion(in: html, markers: ["相关女优", "相關女優"],
                                      endMarkers: ["同分类", "同分類", "资讯评论", "資訊評論"]) {
            var seen = Set<String>()
            for anchor in anchorBlocks(in: region) {
                guard firstMatch("/casts/([A-Za-z0-9]{8})", in: anchor.href) != nil else { continue }
                let name = stripTags(anchor.inner)
                guard !name.isEmpty, seen.insert(anchor.href).inserted else { continue }
                article.relatedCasts.append(NamedLink(name: name, href: anchor.href, kind: "cast"))
            }
        }
        if let region = sectionRegion(in: html, markers: ["同分类", "同分類"],
                                      endMarkers: ["资讯评论", "資訊評論"]) {
            article.relatedNews = newsItems(in: region).filter { $0.pathID != selfID }
        }
        return article
    }

    private static func appendNewsImage(_ rawSrc: String, to article: inout NewsArticle) {
        let src = unescape(rawSrc)
        guard !src.hasPrefix("data:"), !src.contains("avatar"), !src.contains("/icon"),
              !src.contains("logo"), !src.contains("emoji") else { return }
        let url = absoluteURL(src)
        if case .image(let last)? = article.blocks.last, last == url { return }
        article.blocks.append(.image(url))
    }

    private static func sectionRegion(in html: String, markers: [String], endMarkers: [String]) -> String? {
        var start: String.Index?
        for marker in markers {
            if let r = html.range(of: marker), start == nil || r.lowerBound < start! {
                start = r.lowerBound
            }
        }
        guard let start else { return nil }
        var end = html.endIndex
        for marker in endMarkers {
            if let r = html.range(of: marker, range: start..<html.endIndex), r.lowerBound < end {
                end = r.lowerBound
            }
        }
        let capped = html.index(start, offsetBy: 30000, limitedBy: end) ?? end
        return String(html[start..<min(end, capped)])
    }

    /// Series index rows: plain text links to /series/<8-char id> (the site
    /// shows no covers or counts there). The t= tab links and the drawer's
    /// number-letter / maker links don't match the id pattern.
    static func seriesItems(in html: String) -> [NamedLink] {
        var out: [NamedLink] = []
        var seen = Set<String>()
        for anchor in anchorBlocks(in: html) {
            guard firstMatch("/series/([A-Za-z0-9]{8})(?:[?#].*)?$", in: anchor.href) != nil else { continue }
            let name = stripTags(anchor.inner)
            guard !name.isEmpty, name.count <= 80, seen.insert(anchor.href).inserted else { continue }
            out.append(NamedLink(name: name, href: anchor.href, kind: "series"))
        }
        return out
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
                coverURL: CoverURLPolicy.preferred(from: CoverURLPolicy.collect(from: inner) + [imgSrc].compactMap { $0 }.map { absoluteURL($0) }),
                date: date,
                ratingText: rating.map(stripTags),
                badges: Array(Set(badges)),
                canPlay: inner.contains("可播放")
            )

            if let index = cards.firstIndex(where: { $0.pathID == id }) {
                if cards[index].code == nil { cards[index].code = incoming.code }
                if cards[index].title.isEmpty { cards[index].title = incoming.title }
                cards[index].coverURL = CoverURLPolicy.preferred(from: [cards[index].coverURL, incoming.coverURL].compactMap { $0 }) ?? cards[index].coverURL
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
                    cards[index].coverURL = CoverURLPolicy.preferred(from: [cards[index].coverURL, absoluteURL(src)].compactMap { $0 }) ?? cards[index].coverURL
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
        // Hot-cast pages wrap the photo and the name in ONE anchor
        // (<a href="/casts/ID"><img …><div>name</div></a>), so the name is the
        // anchor block's full text — reading only the anchor's first text node
        // (the old approach) yields whitespace and zero people.
        if let regex = try? NSRegularExpression(
            pattern: "<a[^>]+href=\"([^\"]*/casts/([A-Za-z0-9]{8})[^\"]*)\"[^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges >= 4 else { continue }
                let href = ns.substring(with: match.range(at: 1))
                let id = ns.substring(with: match.range(at: 2))
                let block = ns.substring(with: match.range(at: 3))
                if !seen.insert(id).inserted { continue }
                let name = stripTags(block)
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                guard !name.isEmpty, name != "推荐" else { continue }
                let avatar = firstMatch("<img[^>]+(?:src|data-src|data-original)=\"([^\"]+)\"", in: block)
                    .map { unescape($0) }
                people.append(NamedLink(name: name, href: href, kind: "cast", imageURL: avatar))
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

        // The page's own declared cover (og:image / JSON-LD thumbnailUrl)
        // IS this movie's cover — the same URL the list cards embed. It
        // wins outright. The whole-page candidate scan can surface OTHER
        // titles' images (FANZA promos, affiliate art, related covers)
        // whose class scores beat the avfan cover, and then the detail
        // hero shows a different cover than the card the user tapped.
        // The scan remains only as a fallback for pages declaring none.
        let declaredCover = cover.flatMap { $0.isEmpty ? nil : $0 }
        let preferredCover = declaredCover ?? CoverURLPolicy.preferred(in: html)
        return MovieDetail(
            pathID: pathID,
            pageURL: pageURL,
            code: code,
            title: title,
            coverURL: preferredCover,
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
                || path.contains(".m3u8")
            guard isMedia, !path.contains("/covers/") else { return }
            if seen.insert(url.absoluteString).inserted {
                results.append(WatchStream(url: url.absoluteString, label: label))
            }
        }
        if let content = firstMatch(#"contentUrl"\s*:\s*"([^"]+)""#, in: html) {
            accept(content, label: "在线观看")
        }
        if let regex = try? NSRegularExpression(pattern: #"<source[^>]+src=["']([^"']+)["'][^>]*>"#, options: [.caseInsensitive]) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                accept(ns.substring(with: match.range(at: 1)), label: "在线观看")
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"<video[^>]+src=["']([^"']+)["']"#, options: [.caseInsensitive]) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                accept(ns.substring(with: match.range(at: 1)), label: "在线观看")
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>]+\.(m3u8|mp4|m4v)(\?[^\s"'<>]*)?"#, options: [.caseInsensitive]) {
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

    // MARK: - Site session signals (public HTML only)

    static func containsSignInLink(_ html: String) -> Bool {
        html.contains("/sign_in") || html.contains(">登录<") || html.contains(">登入<")
    }

    static func isSignedIn(html: String) -> Bool {
        if signOutURL(in: html) != nil { return true }
        if html.contains(">退出登录<") || html.contains(">登出<") {
            return true
        }
        if html.contains(">退出<") && html.contains("sign_out") {
            return true
        }
        return false
    }

    static func signOutURL(in html: String) -> String? {
        if let href = firstMatch("href=\"([^\"]*sign_out[^\"]*)\"", in: html) { return absoluteURL(href) }
        if let href = firstMatch("href=\"([^\"]*logout[^\"]*)\"", in: html) { return absoluteURL(href) }
        return nil
    }

    static func signedInDisplayName(in html: String) -> String? {
        let candidates = [
            "id=\"dropdown-user\"[\\s\\S]{0,800}?>([^<]{1,40})</",
            "class=\"[^\"]*user-name[^\"]*\"[^>]*>([^<]+)",
        ]
        for pattern in candidates {
            if let name = firstMatch(pattern, in: html).map(stripTags), !name.isEmpty,
               name != "登录", name != "注册", name != "登入", name != "退出" {
                return name
            }
        }
        return nil
    }
}
