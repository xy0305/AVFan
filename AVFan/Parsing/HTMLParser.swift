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
    /// Visible names of the site's locales, as rendered in its
    /// language menu; links with these labels are never tabs.
    static let languageNames: Set<String> = ["English", "简体中文", "繁體中文", "日本語", "한국어", "ภาษาไทย", "ไทย"]

    static func rankingTabs(in html: String, basePath: String, currentPath: String) -> [NamedLink] {
        let base = stripLocale(basePath)
        let current = stripLocale(currentPath)
        // Collect every anchor / option candidate first (build 17).
        // The site's language menu links to this same page — path AND
        // query included — in every other locale, and it sits in the
        // header BEFORE the real tabs. Keyed by locale-stripped href,
        // a variant steals the real tab's dedupe slot: on the series
        // page the ไทย variant of ?t=asian arrived first and the
        // genuine 亚洲 tab was deduped away, leaving a ไทย chip in
        // its place. A name list cannot cover every language label,
        // so the page's own locale is derived from the candidates
        // themselves: it is the locale most base-matching candidates
        // use, and candidates in any other locale are language-menu
        // variants, never tabs.
        var pairs: [(href: String, label: String)] = []
        if let regex = try? NSRegularExpression(
            pattern: "<a[^>]+href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                pairs.append((href: ns.substring(with: match.range(at: 1)), label: ns.substring(with: match.range(at: 2))))
            }
        }
        if let regex = try? NSRegularExpression(
            pattern: "<option[^>]+value=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</option>",
            options: [.caseInsensitive]
        ) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                pairs.append((href: ns.substring(with: match.range(at: 1)), label: ns.substring(with: match.range(at: 2))))
            }
        }
        func localePrefix(of href: String) -> String? {
            var p = href
            if p.hasPrefix("https://avfan.com") { p = String(p.dropFirst("https://avfan.com".count)) }
            if p.hasPrefix("/") { p.removeFirst() }
            for prefix in localePrefixes where p.hasPrefix(prefix + "/") { return prefix }
            return nil
        }
        var localeVotes: [String: Int] = [:]
        for pair in pairs {
            let href = unescape(pair.href).trimmingCharacters(in: .whitespacesAndNewlines)
            guard stripLocale(href).split(separator: "?").first.map(String.init) == base,
                  let prefix = localePrefix(of: href) else { continue }
            localeVotes[prefix, default: 0] += 1
        }
        // Only a locale with at least two candidates is trusted as
        // the page's own; a lone candidate proves nothing.
        let pageLocale = localeVotes.filter { $0.value >= 2 }.max(by: { $0.value < $1.value })?.key
        var results: [NamedLink] = []
        var seen = Set<String>()
        for pair in pairs {
            let href = unescape(pair.href).trimmingCharacters(in: .whitespacesAndNewlines)
            let label = stripTags(pair.label)
            guard !label.isEmpty, label.count <= 14 else { continue }
            // Language-menu entries are not tabs (build 16: an
            // "English" chip appeared among the series tabs).
            guard !languageNames.contains(label) else { continue }
            if let pageLocale, let prefix = localePrefix(of: href), prefix != pageLocale { continue }
            // A bare link to the section root (the search-type
            // selector's 系列 option, say) is not a tab variant
            // either — except a deliberate 全部 tab, which the
            // news page keeps.
            if stripLocale(href) == base, label != "全部" { continue }
            guard stripLocale(href) != current else { continue }
            guard stripLocale(href).split(separator: "?").first.map(String.init) == base else { continue }
            guard !href.contains("page=") else { continue }
            guard seen.insert(stripLocale(href)).inserted else { continue }
            results.append(NamedLink(name: label, href: href, kind: "ranktab"))
        }
        return results
    }

    /// The drawer's series-group shortcuts beyond the three t= tabs
    /// (build 17): number-letter prefixes, the Blacked series page
    /// and the 麻豆傳媒映畫 maker page, in the site's own order.
    /// Drawer sub-items carry the sidebar-sub-item class; the main
    /// list's own rows do not, so they cannot leak in.
    static func drawerSeriesLinks(in html: String) -> [NamedLink] {
        var out: [NamedLink] = []
        var seen = Set<String>()
        guard let regex = try? NSRegularExpression(
            pattern: "<a([^>]+)>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) else { return out }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attrs = ns.substring(with: match.range(at: 1))
            guard attrs.contains("sidebar-sub-item"),
                  let rawHref = attribute("href", in: attrs) else { continue }
            let href = unescape(rawHref).trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = stripLocale(href)
            let isPrefix = stripped.hasPrefix("number_letters/")
            let isSeries = firstMatch("^series/([A-Za-z0-9]{8})$", in: stripped) != nil
            let isMaker = firstMatch("^makers/([A-Za-z0-9]{8})", in: stripped) != nil
            guard isPrefix || isSeries || isMaker else { continue }
            let name = stripTags(ns.substring(with: match.range(at: 2)))
            guard !name.isEmpty, seen.insert(stripped).inserted else { continue }
            out.append(NamedLink(name: name, href: href, kind: "serieslink"))
        }
        return out
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

    /// The next page to auto-load after `page`, computed from a list page
    /// just fetched from `path`: its own next link first, then its
    /// numbered link for page + 1, then — when the page carries a
    /// pagination bar at all — `path` with page= bumped. nil when the
    /// page shows no sign of a following page. (Build 13: every list
    /// auto-loads on scroll; the manual pager is gone.)
    static func autoNextPath(in html: String, page: Int, path: String) -> String? {
        if let next = nextPagePath(in: html, currentPage: page) { return next }
        let pages = pageMap(in: html)
        if let mapped = pages[page + 1] { return mapped }
        if !pages.isEmpty { return withPage(path, page: page + 1) }
        return nil
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

    /// id → visible text for every <label for="…"> on the page.
    private static func labelTexts(in html: String) -> [String: String] {
        var map: [String: String] = [:]
        if let regex = try? NSRegularExpression(
            pattern: "<label[^>]+for=\"([^\"]+)\"[^>]*>(.*?)</label>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: match.range(at: 1))
                let text = stripTags(unescape(ns.substring(with: match.range(at: 2))))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { map[key] = text }
            }
        }
        return map
    }

    /// The site's movie-toolbar filter component (build 15): its type
    /// and filter checkboxes have NO name attribute — they are keyed by
    /// data-movie-toolbar-target and labelled via <label for>, so the
    /// generic form parse only ever saw the named sort/grid radios and
    /// produced a partial panel （排序 missing 最新磁链， no 影片类型 or
    /// 筛选 groups at all). Groups are keyed by the query parameters
    /// the controller applies with (tfilter / mfilter / msort); grid
    /// groups keep their input names and never reach the URL.
    static func movieToolbar(in html: String) -> ListFilterForm? {
        guard html.contains("movie-toolbar") else { return nil }
        func controllerValue(_ key: String) -> String? {
            firstMatch("data-movie-toolbar-\(key)-value=\"([^\"]*)\"", in: html).map(unescape)
        }
        let labels = labelTexts(in: html)
        struct Input {
            var target: String
            var value: String
            var label: String
            var checked: Bool
        }
        var inputs: [Input] = []
        let pattern = "<input[^>]*data-movie-toolbar-target=\"(typeAll|typeOption|filterAll|filterOption|sortOption|gridDesktopOption|gridMobileOption)\"[^>]*>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let tag = ns.substring(with: match.range)
                guard let id = attribute("id", in: tag), let label = labels[id] else { continue }
                inputs.append(Input(
                    target: ns.substring(with: match.range(at: 1)),
                    value: unescape(attribute("value", in: tag) ?? ""),
                    label: label,
                    checked: tag.range(of: "\\bchecked(\\s|>|=)", options: .regularExpression) != nil))
            }
        }
        func options(_ targets: [String]) -> [ListFilterOption] {
            inputs.filter { targets.contains($0.target) }
                .map { ListFilterOption(value: $0.value, label: $0.label, selected: $0.checked) }
        }
        var groups: [ListFilterGroup] = []
        let typeOptions = options(["typeAll", "typeOption"])
        if typeOptions.count >= 2 {
            groups.append(ListFilterGroup(name: "tfilter", isRadio: false, title: "影片类型", options: typeOptions))
        }
        let filterOptions = options(["filterAll", "filterOption"])
        if filterOptions.count >= 2 {
            groups.append(ListFilterGroup(name: "mfilter", isRadio: false, title: "筛选", options: filterOptions))
        }
        let sortOptions = options(["sortOption"])
        if sortOptions.count >= 2 {
            groups.append(ListFilterGroup(name: "msort", isRadio: true, title: "排序", options: sortOptions))
        }
        let desktopOptions = options(["gridDesktopOption"])
        if desktopOptions.count >= 2 {
            groups.append(ListFilterGroup(name: "movie-toolbar-grid-desktop", isRadio: true, title: "布局", options: desktopOptions))
        }
        let mobileOptions = options(["gridMobileOption"])
        if mobileOptions.count >= 2 {
            groups.append(ListFilterGroup(name: "movie-toolbar-grid-mobile", isRadio: true, title: "布局", options: mobileOptions))
        }
        guard groups.contains(where: { ["tfilter", "mfilter", "msort"].contains($0.name) }) else { return nil }
        let categories = controllerValue("category-paths")
            .map { allMatches("\"([^\"]+)\"", in: $0) } ?? []
        let meta = ListFilterForm.ToolbarMeta(
            basePath: controllerValue("base-path") ?? "",
            categoryPaths: categories,
            defaultType: controllerValue("default-type") ?? "all",
            defaultFilter: controllerValue("default-filter") ?? "",
            defaultSort: controllerValue("default-sort") ?? "")
        // A page whose checkboxes carry no pre-checked state (the
        // controller restores it from cookies client-side) still gets
        // the site's declared defaults: 全部类型 for types, the
        // defaultFilter option for filters.
        for gi in groups.indices where !groups[gi].isRadio {
            guard !groups[gi].options.contains(where: \.selected) else { continue }
            let fallback = groups[gi].name == "mfilter" ? meta.defaultFilter : ""
            for oi in groups[gi].options.indices where groups[gi].options[oi].value == fallback {
                groups[gi].options[oi].selected = true
            }
        }
        return ListFilterForm(groups: groups, toolbar: meta)
    }

    /// Port of the movie-toolbar controller's apply(): a single chosen
    /// category type moves into the path (basePath/<type>) instead of a
    /// parameter; everything else rides as tfilter / mfilter / msort,
    /// parameters at their default values are omitted, page= is
    /// dropped, and unrelated parameters are kept. Grid layout groups
    /// never reach the URL (the site persists them in cookies; the app
    /// applies them locally through layoutColumns).
    static func applyingToolbar(_ path: String, form: ListFilterForm, selections: [String: Set<String>]) -> String {
        guard let meta = form.toolbar else { return path }
        func chosen(_ groupName: String) -> [String] {
            guard let group = form.groups.first(where: { $0.name == groupName }) else { return [] }
            let selected = selections[groupName] ?? []
            return group.options.map(\.value).filter { !$0.isEmpty && selected.contains($0) }
        }
        let types = chosen("tfilter")
        let filters = chosen("mfilter")
        let sort = chosen("msort").first
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var pairs: [(String, String)] = []
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let key = kv.first,
                      !["page", "tfilter", "mfilter", "msort"].contains(key) else { continue }
                pairs.append((key, kv.count == 2 ? kv[1] : ""))
            }
        }
        var base = meta.basePath.isEmpty ? (parts.first ?? path) : meta.basePath
        if types.count == 1, meta.categoryPaths.contains(types[0]) {
            base = base.hasSuffix("/") ? base + types[0] : base + "/" + types[0]
        } else {
            let joined = types.isEmpty ? "all" : types.joined(separator: ",")
            if joined != meta.defaultType { pairs.append(("tfilter", joined)) }
        }
        let filterJoined = filters.isEmpty ? "all" : filters.joined(separator: ",")
        if filterJoined != meta.defaultFilter { pairs.append(("mfilter", filterJoined)) }
        if let sort, sort != meta.defaultSort { pairs.append(("msort", sort)) }
        guard !pairs.isEmpty else { return base }
        return base + "?" + pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    /// The list filter/sort form a catalog page carries (the JUR prefix
    /// page's 筛选 panel: feature checkboxes + sort radios). Parsed from
    /// the page's own checkbox/radio inputs and their labels — names,
    /// values and pre-selected options all come from the site. Returns
    /// nil when the page has no such form. The movie-toolbar
    /// component, when present, is parsed by movieToolbar instead.
    static func listFilterForm(in html: String) -> ListFilterForm? {
        if let toolbar = movieToolbar(in: html) { return toolbar }
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
        for name in order.prefix(6) {
            guard let options = grouped[name], options.count >= 2 else { continue }
            let isRadio = options.first?.radio ?? false
            let labels = options.map(\.label)
            let looksLikeSort = labels.contains {
                $0.contains("最新") || $0.contains("最高") || $0.contains("评分")
            }
            // The panel's own headings, recovered from the option sets:
            // 布局 options are all "N列"; 影片类型 is the closed type
            // vocabulary headed by 全部类型 (the homepage panel carries
            // both alongside 筛选 and 排序).
            let isLayout = !labels.isEmpty && labels.allSatisfy {
                $0.replacingOccurrences(of: " ", with: "")
                    .range(of: "^\\d+列$", options: .regularExpression) != nil
            }
            let typeLabels: Set<String> = ["全部类型", "有码", "无码", "欧美", "FC2", "动漫", "华语"]
            let isType = labels.contains("全部类型")
                || (!labels.isEmpty && labels.allSatisfy { typeLabels.contains($0) })
            let groupTitle = isLayout ? "布局" : isType ? "影片类型" : looksLikeSort ? "排序" : "筛选"
            groups.append(ListFilterGroup(
                name: name,
                isRadio: isRadio,
                title: groupTitle,
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
        if form.toolbar != nil { return applyingToolbar(path, form: form, selections: selections) }
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
            sections.append(HomeSection(title: "最新磁链", cards: rest, moreHref: nil, isMainList: true))
        }
        if sections.isEmpty, !cards.isEmpty {
            sections.append(HomeSection(title: "首页", cards: cards, moreHref: nil, isMainList: true))
        }
        return HomePage(sections: sections, listCards: rest)
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
        // The full synopsis lives in the page's #description block
        // (the 简介 tab); og:description is only a truncated teaser,
        // so the block wins when present (build 24).
        var summary = descriptionText(in: html)
            ?? firstMatch("property=\"og:description\"\\s+content=\"([^\"]+)\"", in: html).map(unescape)
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
            watchStreams: watchStreams(in: html, pageURL: pageURL),
            trailerURL: trailerURL(in: html),
            hasTrailerAffordance: hasTrailerAffordance(in: html),
            previewImages: previewImages(in: html, cover: preferredCover),
            library: libraryState(in: html),
            commentsURL: firstMatch("data-comments-url=\"([^\"]+)\"", in: html).map(unescape),
            relatedListsURL: firstMatch("<div[^>]*id=\"related-lists\"[^>]*data-url=\"([^\"]+)\"", in: html).map(unescape)
                ?? firstMatch("data-url=\"([^\"]+)\"[^>]*id=\"related-lists\"", in: html).map(unescape)
                ?? firstMatch("(/?[A-Za-z-]+/lists/related\\?movie_id=[A-Za-z0-9]+)", in: html).map(unescape),
            commentsCount: firstMatch("tabComments\"[^>]*>[\\s\\S]*?评论[\\s\\S]*?>(\\d+)<", in: html).flatMap { Int($0) },
            alsoStarred: sectionCards(in: html, heading: "还出演过"),
            relatedWorks: sectionCards(in: html, heading: "相关作品")
        )
    }

    /// The full synopsis from the detail page's #description block.
    static func descriptionText(in html: String) -> String? {
        guard let inner = firstMatch("<div[^>]*id=\"description\"[^>]*>([\\s\\S]*?)</div>", in: html) else { return nil }
        var text = stripTags(inner)
        text = text.replacingOccurrences(of: "<br>", with: "\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Movie cards under one of the detail page's own section
    /// headings （她/他还出演过 / 相关作品）: the slice from the heading
    /// to the next section heading (or a sane cap), parsed with the
    /// standard card parser.
    static func sectionCards(in html: String, heading: String) -> [MovieCard] {
        guard let range = html.range(of: heading) else { return [] }
        var slice = String(html[range.upperBound...])
        for other in ["还出演过", "相关作品", "相关清单"] where other != heading {
            if let end = slice.range(of: other) {
                slice = String(slice[..<end.lowerBound])
            }
        }
        if slice.count > 60000 { slice = String(slice.prefix(60000)) }
        var seen = Set<String>()
        return movieCards(in: slice).filter { seen.insert($0.pathID).inserted }.prefix(12).map { $0 }
    }

    /// Whether the page carries a trailer player trigger at all
    /// (the trailer-player Stimulus component or its src value),
    /// regardless of whether a direct media URL parsed out.
    static func hasTrailerAffordance(in html: String) -> Bool {
        html.contains("trailer-player") || html.contains("data-trailer")
    }

    /// Tag stripping that respects quoted attribute values: a `>`
    /// or quote inside an attribute (the reply button's
    /// data-placeholder carries quoted text with both) must not end
    /// the tag early — the naive `<[^>]+>` regex breaks exactly
    /// there and leaks the attribute tail into the text (the
    /// owner's build-25 screenshots). Character scanner, no regex.
    static func stripTagsQuoteAware(_ html: String) -> String {
        var out = ""
        out.reserveCapacity(html.count)
        var inTag = false
        var quote: Character? = nil
        for ch in html {
            if inTag {
                if let q = quote {
                    if ch == q { quote = nil }
                } else if ch == "\"" || ch == "'" {
                    quote = ch
                } else if ch == ">" {
                    inTag = false
                }
            } else if ch == "<" {
                inTag = true
            } else {
                out.append(ch)
            }
        }
        return unescape(out)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Movie comments from the comments fragment (build 25,
    /// rewritten against the real markup the owner's screenshots
    /// exposed): each top-level comment is a
    /// div.comment-list-item carrying
    /// data-comment-comment-id-value; the author is its .username
    /// element; the site's own load-more is cursor-based, see
    /// commentsCursor(in:). All slicing is NSString-based — mixing
    /// UTF-16 match offsets with String indices garbled the blocks
    /// on CJK text in build 24.
    static func movieComments(in fragment: String) -> [MovieComment] {
        guard let regex = try? NSRegularExpression(
            pattern: "<div[^>]*class=\"[^\"]*comment-list-item[^\"]*\"[^>]*>",
            options: [.caseInsensitive]
        ) else { return [] }
        let ns = fragment as NSString
        let matches = regex.matches(in: fragment, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }
        var items: [MovieComment] = []
        for (index, match) in matches.enumerated() {
            let start = match.range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let block = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
            var author = "匿名"
            if let raw = firstMatch("class=\"[^\"]*username[^\"]*\"[^>]*>([\\s\\S]*?)<", in: block) {
                let name = stripTags(raw)
                if !name.isEmpty { author = name }
            }
            let commentID = firstMatch("data-comment-comment-id-value=\"(\\d+)\"", in: block)
            let text = stripTagsQuoteAware(block)
            let date = firstMatch(#"(?<!\d)(\d{4}-\d{2}-\d{2}|\d{1,2}-\d{1,2})(?!\d)"#, in: text)
            // Layer 1 (lock 1.3): the body comes from the item's
            // content element — the longest <p> in the block — not
            // from the whole item (which includes the action/menu
            // subtree that leaked attribute text in build 25).
            var body = ""
            for p in allMatches("<p[^>]*>([\\s\\S]*?)</p>", in: block) {
                let candidate = stripTagsQuoteAware(p)
                if candidate.count > body.count { body = candidate }
            }
            if body.isEmpty {
                body = text
                if author != "匿名", let r = body.range(of: author) { body.removeSubrange(r) }
                if let date, let r = body.range(of: date) { body.removeSubrange(r) }
            }
            for cut in ["回复", "加载更多", "查看回复", "收起回复", "举报"] {
                if let r = body.range(of: cut) { body = String(body[..<r.lowerBound]) }
            }
            // Layer 3: residue guard — attribute debris in the body
            // means the cleaning missed a spot; truncate there
            // rather than show markup to the user.
            for marker in ["data-", "comment#", "openCommentModal", "href=", "class="] {
                if let r = body.range(of: marker) { body = String(body[..<r.lowerBound]) }
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            items.append(MovieComment(author: author, body: body, dateText: date, commentID: commentID))
        }
        return items
    }

    /// The comments load-more cursor declared by the fragment's own
    /// .load-more-comments anchor (the comment controller's
    /// loadMore): the next fetch is
    /// commentsURL?sort_by=<sortBy>&last_value=<lastValue>&last_id=<lastId>.
    static func commentsCursor(in fragment: String) -> (sortBy: String, lastValue: String, lastId: String)? {
        guard let tag = firstMatch("(<a[^>]*data-action=\"comment#loadMore\"[^>]*>)", in: fragment),
              let sortBy = firstMatch("data-sort-by=\"([^\"]*)\"", in: tag),
              let lastValue = firstMatch("data-last-value=\"([^\"]*)\"", in: tag),
              let lastId = firstMatch("data-last-id=\"([^\"]*)\"", in: tag) else { return nil }
        return (sortBy, lastValue, lastId)
    }

    /// The next comments/lists page declared inside a fragment:
    /// a data-next-page attribute, or a 加载更多 anchor's page param.
    static func fragmentNextPage(in fragment: String) -> Int? {
        if let value = firstMatch("data-next-page=\"(\\d+)\"", in: fragment) {
            return Int(value)
        }
        if let href = firstMatch("<a[^>]+href=\"([^\"]*[?&]page=\\d+[^\"]*)\"[^>]*>\\s*加载更多", in: fragment),
           let page = firstMatch("[?&]page=(\\d+)", in: href) {
            return Int(page)
        }
        return nil
    }

    /// Related-list rows from the related-lists fragment: each
    /// /lists/<id> anchor's name plus the counts that follow it.
    static func relatedListRows(in fragment: String) -> [RelatedListRow] {
        guard let regex = try? NSRegularExpression(
            pattern: "<a[^>]+href=\"([^\"]*/lists/[^\"/]+)\"[^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) else { return [] }
        let ns = fragment as NSString
        let matches = regex.matches(in: fragment, range: NSRange(location: 0, length: ns.length))
        var rows: [RelatedListRow] = []
        var seen = Set<String>()
        for (index, match) in matches.enumerated() {
            let href = unescape(ns.substring(with: match.range(at: 1)))
            var name = stripTags(ns.substring(with: match.range(at: 2)))
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let tail = stripTags(ns.substring(with: NSRange(location: match.range.location, length: end - match.range.location)))
            if name.count < 2 {
                // The name may sit outside the anchor (block-style
                // rows): stripTags flattens the row to one line, so
                // take the tail with the counts segments removed.
                var candidate = tail
                for pattern in [#"\d+\s*部作品"#, #"被查看\s*\d+\s*次"#] {
                    candidate = candidate.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                }
                candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " ，,·・"))
                if candidate.count >= 2 { name = candidate }
            }
            guard !name.isEmpty, seen.insert(href).inserted else { continue }
            rows.append(RelatedListRow(
                name: name,
                href: href,
                moviesCount: firstMatch(#"(\d+)\s*部作品"#, in: tail).flatMap { Int($0) },
                viewsCount: firstMatch(#"被查看\s*(\d+)\s*次"#, in: tail).flatMap { Int($0) }
            ))
        }
        if rows.isEmpty {
            // Fallback (lock 1.3): the fragment's rows may use
            // single-quoted hrefs or non-anchor carriers. Scan for
            // any /lists/ href, then read the name and counts from
            // the text segment that follows it.
            let loose = allMatches("href=['\"]([^'\"]*/lists/[^'\"/]+)['\"]", in: fragment)
            var seenLoose = Set<String>()
            for href in loose {
                let clean = unescape(href)
                guard seenLoose.insert(clean).inserted,
                      let anchorRange = fragment.range(of: href) else { continue }
                // Start AFTER the href and skip the rest of the
                // opening tag, so the URL itself never leaks into
                // the row's name.
                let afterHref = fragment[anchorRange.upperBound...]
                guard let tagEnd = afterHref.firstIndex(of: ">") else { continue }
                let tail = stripTagsQuoteAware(String(afterHref[afterHref.index(after: tagEnd)...].prefix(600)))
                var name = ""
                var candidate = tail
                for pattern in [#"\d+\s*部作品"#, #"被查看\s*\d+\s*次"#] {
                    candidate = candidate.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                }
                candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " ，,·・"))
                if candidate.count >= 2 { name = String(candidate.prefix(60)) }
                guard !name.isEmpty else { continue }
                rows.append(RelatedListRow(
                    name: name,
                    href: clean,
                    moviesCount: firstMatch(#"(\d+)\s*部作品"#, in: tail).flatMap { Int($0) },
                    viewsCount: firstMatch(#"被查看\s*(\d+)\s*次"#, in: tail).flatMap { Int($0) }
                ))
            }
        }
        return rows
    }

    /// Link rows for non-movie search results (series / makers /
    /// directors): anchors into /<section>/<id> with a real name,
    /// deduped, section-index links excluded.
    static func searchLinkRows(in html: String, section: String) -> [NamedLink] {
        guard let regex = try? NSRegularExpression(
            pattern: "<a[^>]+href=\"([^\"]*/\(section)/[A-Za-z0-9]{4,}[^\"#]*)\"[^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) else { return [] }
        let ns = html as NSString
        var out: [NamedLink] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = unescape(ns.substring(with: match.range(at: 1)))
            let name = stripTags(ns.substring(with: match.range(at: 2)))
            guard name.count >= 2, seen.insert(href).inserted else { continue }
            out.append(NamedLink(name: name, href: href, kind: section))
            if out.count >= 60 { break }
        }
        return out
    }

    /// The search page's type dropdown （影片/演员/系列/制作商/导演）:
    /// anchors into /search carrying an st parameter, labelled by
    /// their own text. Returned in page order.
    static func searchTypes(in html: String) -> [NamedLink] {
        guard let regex = try? NSRegularExpression(
            pattern: "<a[^>]+href=\"([^\"]*/search\\?[^\"#]*st=[a-z]+[^\"#]*)\"[^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) else { return [] }
        let ns = html as NSString
        var out: [NamedLink] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = unescape(ns.substring(with: match.range(at: 1)))
            let label = stripTags(ns.substring(with: match.range(at: 2)))
            guard ["全部", "影片", "演员", "系列", "制作商", "导演"].contains(label) else { continue }
            guard seen.insert(label).inserted else { continue }
            out.append(NamedLink(name: label, href: href, kind: "search-type"))
        }
        return out
    }

    /// The account library block （想看 / 看过 / 保存至清单） as the detail
    /// page itself declares it: the review controller's buttons carry
    /// their POST endpoints in data-url and their state in which
    /// "already" button is not hidden; the save-to-list modal carries
    /// the toggle endpoint and the list-rows endpoint. Everything is
    /// read from the page's own attributes — no endpoint is guessed.
    /// Returns nil when the page has no such block.
    static func libraryState(in html: String) -> LibraryPageState? {
        func targetTag(_ target: String) -> String? {
            firstMatch("(<[^>]*data-review-target=\"\(target)\"[^>]*>)", in: html)
        }
        let addWatchlist = targetTag("btnAddToWatchlist")
        let alreadyWatchlist = targetTag("btnAlreadyInWatchlist")
        let watchedButton = targetTag("btnWatched")
        let markWatched = targetTag("btnMarkAsWatched")
        let alreadyWatched = targetTag("btnAlreadyWatched")
        let removeButton = targetTag("btnRemoveReview")
        let modal = firstMatch("(<[^>]*id=\"save-to-list-modal\"[^>]*>)", in: html)
        guard addWatchlist != nil || alreadyWatchlist != nil || watchedButton != nil
            || markWatched != nil || alreadyWatched != nil || modal != nil else { return nil }

        func visible(_ tag: String?) -> Bool {
            guard let tag else { return false }
            let classes = (attribute("class", in: tag) ?? "").split(separator: " ")
            return !classes.contains("hidden")
        }

        var state = LibraryPageState()
        state.csrfToken = firstMatch("<meta[^>]*name=\"csrf-token\"[^>]*content=\"([^\"]+)\"", in: html)
            ?? firstMatch("<meta[^>]*content=\"([^\"]+)\"[^>]*name=\"csrf-token\"", in: html)
        if visible(alreadyWatched) {
            state.reviewStatus = .watched
        } else if visible(alreadyWatchlist) {
            state.reviewStatus = .watchlist
        }
        if let addWatchlist {
            state.watchlistURL = attribute("data-url", in: addWatchlist)
            if let type = attribute("data-action-type", in: addWatchlist) { state.watchlistActionType = type }
        }
        if let watchedSource = markWatched ?? watchedButton {
            state.watchedURL = attribute("data-url", in: watchedSource)
            if let type = attribute("data-action-type", in: watchedSource) { state.watchedActionType = type }
        }
        // The site's create call is one endpoint for both statuses; if
        // only one button printed its URL, it serves both.
        if state.watchlistURL == nil { state.watchlistURL = state.watchedURL }
        if state.watchedURL == nil { state.watchedURL = state.watchlistURL }
        if let removeButton { state.removeURL = attribute("data-url", in: removeButton) }
        if let modal { state.changeURL = attribute("data-change-url", in: modal) }
        if let container = firstMatch("(<[^>]*id=\"lists-container\"[^>]*>)", in: html) {
            state.listsURL = attribute("data-url", in: container)
        }
        if let saveButton = firstMatch("(<[^>]*id=\"save-list-btn\"[^>]*>)", in: html) {
            state.createListURL = attribute("data-url", in: saveButton)
            if let mode = attribute("data-mode", in: saveButton) { state.createListMode = mode }
        }
        return state
    }

    /// Rows of the save-to-list picker, parsed from the HTML fragment
    /// the lists endpoint returns: one checkbox input per list, its
    /// data-list-id, checked state, and the label text after it.
    static func listOptions(in fragment: String) -> [SyncListOption] {
        var results: [SyncListOption] = []
        var seen = Set<String>()
        guard let regex = try? NSRegularExpression(pattern: "<input[^>]*>", options: [.caseInsensitive]) else { return [] }
        let ns = fragment as NSString
        for match in regex.matches(in: fragment, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            guard let listID = attribute("data-list-id", in: tag), seen.insert(listID).inserted else { continue }
            let checked = tag.range(of: #"(^|\s)checked(\s|=|>|$)"#, options: .regularExpression) != nil
            let tail = ns.substring(from: match.range.location + match.range.length)
            var name = stripTags(String(tail.prefix(300))).trimmingCharacters(in: .whitespacesAndNewlines)
            // The label reads "名称 (数量)" and the next row's text
            // follows in the same fragment: cut at the first count.
            if let range = name.range(of: #"\s*[\(（]\d+[\)）]"#, options: .regularExpression) {
                name = String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            if name.count > 40 { name = String(name.prefix(40)) }
            if name.isEmpty { name = "清单 \(listID)" }
            results.append(SyncListOption(listID: listID, name: name, checked: checked))
        }
        return results
    }

    /// A cast profile page: identity from the <title> segments and
    /// the page's own control wiring (the `model` controller's
    /// follow/collect buttons, the cast-profile details fragment URL,
    /// the cast-review element's data attributes). Nothing is guessed;
    /// absent pieces stay nil.
    static func castProfile(in html: String) -> CastProfile {
        var profile = CastProfile()
        profile.signedIn = isSignedIn(html: html)
        profile.csrfToken = firstMatch("<meta[^>]*name=\"csrf-token\"[^>]*content=\"([^\"]+)\"", in: html)
            ?? firstMatch("<meta[^>]*content=\"([^\"]+)\"[^>]*name=\"csrf-token\"", in: html)

        // Title: "喜多川みら, きたがわみら, mira kitagawa | AVFan".
        if let title = firstMatch("<title>([^<]+)</title>", in: html) {
            let head = title.components(separatedBy: "|").first ?? title
            let parts = head.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let first = parts.first { profile.name = first }
            if parts.count > 1 { profile.reading = parts[1] }
            if parts.count > 2 { profile.romaji = parts[2] }
        }
        if profile.name.isEmpty, let h1 = firstMatch("<h1[^>]*>([\\s\\S]*?)</h1>", in: html) {
            profile.name = stripTags(h1)
        }

        // Avatar: the page's /avatars/ image (alt carries the name
        // when present; the first one is the profile picture).
        if let avatar = firstMatch("<img[^>]+src=\"([^\"]*/avatars/[^\"]+)\"", in: html) {
            profile.avatarURL = unescape(avatar)
        }

        // Social links (X / Twitter and friends).
        var seenSocial = Set<String>()
        if let regex = try? NSRegularExpression(pattern: "<a[^>]+href=\"(https?://(?:twitter\\.com|x\\.com)/[^\"]+)\"", options: [.caseInsensitive]) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let href = ns.substring(with: match.range(at: 1))
                guard seenSocial.insert(href).inserted else { continue }
                let handle = href.components(separatedBy: "/").last.map { "@\($0)" } ?? "X"
                profile.socialLinks.append(NamedLink(name: handle, href: href, kind: "social"))
            }
        }

        if let countText = firstMatch(#"(\d+)\s*部作品"#, in: stripTags(html)) {
            profile.worksCount = Int(countText)
        }

        // The `model` controller's four buttons.
        func modelTag(_ target: String) -> String? {
            firstMatch("(<[^>]*data-model-target=\"\(target)\"[^>]*>)", in: html)
        }
        func visible(_ tag: String?) -> Bool {
            guard let tag else { return false }
            return !(attribute("class", in: tag) ?? "").split(separator: " ").contains("hidden")
        }
        let follow = modelTag("btnFollow")
        let unfollow = modelTag("btnUnfollow")
        let collect = modelTag("btnCollect")
        let uncollect = modelTag("btnUncollect")
        if let follow {
            profile.followURL = attribute("data-url", in: follow)
            profile.modelName = attribute("data-model", in: follow)
            profile.modelID = attribute("data-model-id", in: follow)
        }
        if let unfollow { profile.unfollowURL = attribute("data-url", in: unfollow) }
        if let collect {
            profile.collectURL = attribute("data-url", in: collect)
            if profile.modelName == nil { profile.modelName = attribute("data-model", in: collect) }
            if profile.modelID == nil { profile.modelID = attribute("data-model-id", in: collect) }
        }
        if let uncollect { profile.uncollectURL = attribute("data-url", in: uncollect) }
        profile.isFollowing = visible(unfollow)
        profile.isCollected = visible(uncollect)

        // 详细资料： the cast-profile element's fragment URL value.
        if let tag = firstMatch("(<[^>]*data-controller=\"[^\"]*cast-profile[^\"]*\"[^>]*>)", in: html) {
            profile.detailsURL = attribute("data-cast-profile-url-value", in: tag)
        }

        // 短评： the cast-review element carries create URL + cast id.
        if let tag = firstMatch("(<[^>]*data-controller=\"[^\"]*cast-review[^\"]*\"[^>]*>)", in: html) {
            profile.reviewCreateURL = attribute("data-create-url", in: tag)
            profile.reviewCastSqid = attribute("data-cast-sqid", in: tag)
            profile.reviewListURL = attribute("data-cast-review-list-url-value", in: tag)
            profile.ownReviewID = attribute("data-review-id", in: tag)
            profile.ownReviewDestroyURL = attribute("data-destroy-url", in: tag)
        }
        return profile
    }

    /// The collect wiring for the page's own subject (a list page's
    /// 收藏 button for the list itself): the `model` controller's
    /// btnCollect/btnUncollect tags, same contract as castProfile.
    static func listCollectState(in html: String) -> ListCollectState {
        var state = ListCollectState()
        state.csrfToken = firstMatch("<meta[^>]*name=\"csrf-token\"[^>]*content=\"([^\"]+)\"", in: html)
        state.signedIn = isSignedIn(html: html)
        func modelTag(_ target: String) -> String? {
            firstMatch("(<[^>]*data-model-target=\"\(target)\"[^>]*>)", in: html)
        }
        func visible(_ tag: String?) -> Bool {
            guard let tag else { return false }
            return !(attribute("class", in: tag) ?? "").split(separator: " ").contains("hidden")
        }
        let collect = modelTag("btnCollect")
        let uncollect = modelTag("btnUncollect")
        if let collect {
            state.collectURL = attribute("data-url", in: collect)
            state.modelName = attribute("data-model", in: collect)
            state.modelID = attribute("data-model-id", in: collect)
        }
        if let uncollect { state.uncollectURL = attribute("data-url", in: uncollect) }
        state.isCollected = visible(uncollect)
        return state
    }

    /// Label/value rows from an HTML fragment (the cast details
    /// panel): table rows first, then definition lists, then list
    /// items split on their colon.
    static func infoRows(in fragment: String) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let regex = try? NSRegularExpression(pattern: "<tr[^>]*>([\\s\\S]*?)</tr>", options: [.caseInsensitive]) {
            let ns = fragment as NSString
            for match in regex.matches(in: fragment, range: NSRange(location: 0, length: ns.length)) {
                let cells = allMatches("<t[hd][^>]*>([\\s\\S]*?)</t[hd]>", in: ns.substring(with: match.range(at: 1)))
                    .map { stripTags($0) }
                if cells.count >= 2, !cells[0].isEmpty {
                    rows.append((cells[0], cells[1]))
                }
            }
        }
        if rows.isEmpty, let regex = try? NSRegularExpression(pattern: "<dt[^>]*>([\\s\\S]*?)</dt>\\s*<dd[^>]*>([\\s\\S]*?)</dd>", options: [.caseInsensitive]) {
            let ns = fragment as NSString
            for match in regex.matches(in: fragment, range: NSRange(location: 0, length: ns.length)) {
                let label = stripTags(ns.substring(with: match.range(at: 1)))
                let value = stripTags(ns.substring(with: match.range(at: 2)))
                if !label.isEmpty { rows.append((label, value)) }
            }
        }
        if rows.isEmpty {
            for item in allMatches("<li[^>]*>([\\s\\S]*?)</li>", in: fragment) {
                let text = stripTags(item)
                if let range = text.range(of: "：") ?? text.range(of: ":") {
                    let label = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let value = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !label.isEmpty { rows.append((label, value)) }
                } else if !text.isEmpty {
                    rows.append(("", text))
                }
            }
        }
        return rows
    }

    /// Short-review items from the cast-review list fragment. Blocks
    /// are delimited by the like controllers; each block's longest
    /// text is the review body, its first anchor the author, and a
    /// date-like string the meta line. Falls back to no items when
    /// the fragment has no recognizable blocks (the view then shows
    /// the fragment's plain text lines instead).
    static func castReviews(in fragment: String) -> [CastReviewItem] {
        guard let regex = try? NSRegularExpression(
            pattern: "(<[^>]*data-controller=\"cast-review-like\"[^>]*>)",
            options: [.caseInsensitive]
        ) else { return [] }
        let ns = fragment as NSString
        let matches = regex.matches(in: fragment, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }
        var items: [CastReviewItem] = []
        var blockStart = 0
        for match in matches {
            // The item's content precedes its like button: the block
            // runs from the previous like tag's end to this tag.
            let block = ns.substring(with: NSRange(location: blockStart, length: match.range.location - blockStart))
            let tag = ns.substring(with: match.range(at: 1))
            blockStart = match.range.location + match.range.length
            let likeURL = attribute("data-cast-review-like-url-value", in: tag)
            var author = "匿名"
            if let anchorRegex = try? NSRegularExpression(pattern: "<a[^>]+href=\"[^\"]+\"[^>]*>([\\s\\S]*?)</a>", options: [.caseInsensitive]) {
                let blockNS = block as NSString
                if let anchor = anchorRegex.firstMatch(in: block, range: NSRange(location: 0, length: blockNS.length)) {
                    let name = stripTags(blockNS.substring(with: anchor.range(at: 1)))
                    if !name.isEmpty { author = name }
                }
            }
            let text = stripTags(block)
            let meta = firstMatch(#"(\d{4}-\d{2}-\d{2}|\d+\s*(?:天|小时|分钟)前)"#, in: text)
            var body = text
            if author != "匿名", let range = body.range(of: author) { body.removeSubrange(range) }
            if let meta, let range = body.range(of: meta) { body.removeSubrange(range) }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            items.append(CastReviewItem(author: author, body: body, meta: meta, likeURL: likeURL))
        }
        return items
    }

    /// The signed-in user's own lists, from the /user/lists page:
    /// anchors into user/lists/<id> with their names.
    static func userLists(in html: String) -> [NamedLink] {
        var results: [NamedLink] = []
        var seen = Set<String>()
        guard let regex = try? NSRegularExpression(pattern: "<a[^>]+href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>", options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: match.range(at: 1))
            let stripped = stripLocale(href)
            guard stripped.hasPrefix("user/lists/") else { continue }
            let name = stripTags(ns.substring(with: match.range(at: 2))).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(stripped).inserted else { continue }
            results.append(NamedLink(name: name, href: href, kind: "userlist"))
        }
        return results
    }

    /// The detail page's own preview trailer: the JSON-LD VideoObject
    /// contentUrl when it points at a preview host (DMM's pv CDN), any
    /// d1.avfan.com mp4, or any DMM /pv/ mp4 in the page. Full watch
    /// streams are watchStreams' job; this is the media strip's cell.
    static func trailerURL(in html: String) -> String? {
        // The trailer trigger itself declares the exact source the
        // site's own player attaches (an mp4 or an HLS playlist) —
        // that wins over the structured-data URL.
        if let declared = firstMatch("data-trailer-player-src-value=\"([^\"]+)\"", in: html) {
            let url = unescape(declared).trimmingCharacters(in: .whitespacesAndNewlines)
            if url.hasPrefix("http") { return url }
        }
        let text = html.replacingOccurrences(of: "\\/", with: "/")
        func isTrailer(_ raw: String) -> String? {
            let value = unescape(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value), let host = url.host?.lowercased() else { return nil }
            let path = url.path.lowercased()
            guard path.hasSuffix(".mp4") else { return nil }
            if host == "d1.avfan.com" { return value }
            if host.contains("dmm.co.jp"), path.contains("/pv/") { return value }
            return nil
        }
        if let content = firstMatch(#"contentUrl"\s*:\s*"([^"]+)""#, in: text), let hit = isTrailer(content) {
            return hit
        }
        for raw in allMatches(#"(https?://[^\s"'<>]+\.mp4(?:\?[^\s"'<>]*)?)"#, in: text) {
            if let hit = isTrailer(raw) { return hit }
        }
        return nil
    }

    /// Sample stills embedded in the detail page: DMM sample images
    /// (…jp-N.jpg on the DMM image hosts) and avfan-hosted samples.
    /// Anything else on the page (ads, covers of other titles, avatars)
    /// is not a still of this movie. Page order, de-duplicated, the
    /// movie's own cover excluded.
    static func previewImages(in html: String, cover: String?) -> [String] {
        let text = html.replacingOccurrences(of: "\\/", with: "/")
        var results: [String] = []
        var seen = Set<String>()
        for raw in allMatches(#"(https?://[^\s"'<>\\]+)"#, in: text) {
            let value = unescape(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value), let host = url.host?.lowercased() else { continue }
            let path = url.path
            let lower = path.lowercased()
            let isDMMSample = (host.contains("dmm.co.jp") || host.contains("awsimgsrc"))
                && lower.range(of: #"jp-\d+\.(jpg|jpeg|png)$"#, options: .regularExpression) != nil
            let isAvfanSample = host == "c1.avfan.com" && lower.contains("/samples/")
            guard isDMMSample || isAvfanSample else { continue }
            if let cover, value == cover { continue }
            if seen.insert(value).inserted {
                results.append(value)
                if results.count >= 24 { break }
            }
        }
        return results
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
