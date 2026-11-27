import Foundation

// Build 60: AVBase (www.avbase.net) joins the rankings tab as an
// external board — 最新作品 / 按发售日 / 番号搜索. AVBase is a Next.js
// site: every page embeds its data as JSON in
// <script id="__NEXT_DATA__">, lists under props.pageProps.works and
// the detail record under props.pageProps.work. This parser is a
// faithful port of the field contract documented in the owner's
// avbase.js Forward module (v1.8.0): work extraction
// (avExtractWorks), the avPickProduct completeness score, the
// avAggregateId code normalization and the two-format avNormDate.
//
// It deliberately reuses AvbaseMetadata.props / .string from
// CataloguePoster.swift — the app's existing, tested __NEXT_DATA__
// extraction for the same site — instead of duplicating it. Only the
// list-shaped mapping is new here.
//
// Covers are NOT read from AVBase: entries carry no cover at all and
// the rankings grid resolves the code through the shared HQ chain
// (HQCoverResolver / DMMCoverResolver, official DMM/MGS portrait
// first, matched AVFan card cover as fallback), per the owner's
// build-60 rule. AVBase's own product images never reach the UI.
//
// Foundation-only and side-effect free so the CI parser-test binary
// exercises it directly (scripts/test_parser_main.swift).

struct AVBaseWork: Equatable {
    /// Bare catalog number (MBMP-173) — the aggregation/match key.
    var code: String
    /// Site-internal code: "prefix:work_id" when a maker prefix
    /// exists (mbm:MBMP-173), otherwise the bare number.
    var siteCode: String
    var title: String
    /// Release date normalized to yyyy-MM-dd (avNormDate).
    var releaseDate: String?
    var actresses: [String] = []
    var genres: [String] = []
    /// Minutes from the picked product's iteminfo.volume (avParseMinutes).
    var durationMinutes: Int?
    /// Synopsis from the picked product's iteminfo.description.
    var summary: String?
}

struct AVBaseListPage: Equatable {
    var works: [AVBaseWork]
    /// The page's declared result total ("共 N 件"), when present.
    var total: Int?
}

enum AVBaseParser {

    // MARK: - Page entry points

    /// Parses a full AVBase HTML page. Nil when the page carries no
    /// usable __NEXT_DATA__ (challenge interstitials, error pages) —
    /// the client treats that as "challenged" and falls back.
    static func page(html: String) -> AVBaseListPage? {
        guard let props = AvbaseMetadata.props(html) else { return nil }
        return page(props: props)
    }

    static func page(props: [String: Any]) -> AVBaseListPage {
        AVBaseListPage(works: extractWorks(props).compactMap(mapWork),
                       total: readTotal(props))
    }

    // MARK: - Work extraction (avExtractWorks / avLooksLikeWork)

    static func looksLikeWork(_ value: Any?) -> [String: Any]? {
        guard let dict = value as? [String: Any] else { return nil }
        guard AvbaseMetadata.string(dict["work_id"]) != nil
                || AvbaseMetadata.string(dict["workId"]) != nil else { return nil }
        guard dict["title"] is String || dict["products"] is [Any] else { return nil }
        return dict
    }

    /// Preferred keys first (works / worksList / items / list);
    /// otherwise the largest work-like array anywhere in pageProps.
    static func extractWorks(_ props: [String: Any]) -> [[String: Any]] {
        for key in ["works", "worksList", "items", "list"] {
            if let array = props[key] as? [Any] {
                let only = array.compactMap(looksLikeWork)
                if !only.isEmpty { return only }
            }
        }
        var best: [[String: Any]] = []
        for (_, value) in props {
            guard let array = value as? [Any] else { continue }
            let only = array.compactMap(looksLikeWork)
            if only.count > best.count { best = only }
        }
        return best
    }

    /// avReadTotal: total / totalCount / total_count / count /
    /// totalItems, as a number or a numeric string.
    static func readTotal(_ props: [String: Any]) -> Int? {
        for key in ["total", "totalCount", "total_count", "count", "totalItems"] {
            guard let raw = props[key] else { continue }
            if let number = raw as? NSNumber {
                let value = number.intValue
                if value >= 0 { return value }
            }
            if let text = raw as? String, let value = Int(text), value >= 0 {
                return value
            }
        }
        return nil
    }

    // MARK: - Product pick (avProductScore / avPickProduct)

    /// Completeness score: image_url +4, thumbnail_url +2,
    /// iteminfo.description +1, sample images +1, sample movie +1.
    static func productScore(_ product: [String: Any]) -> Int {
        var score = 0
        if AvbaseMetadata.string(product["image_url"]) != nil { score += 4 }
        if AvbaseMetadata.string(product["thumbnail_url"]) != nil { score += 2 }
        if let item = product["iteminfo"] as? [String: Any],
           AvbaseMetadata.string(item["description"]) != nil { score += 1 }
        if let samples = product["sample_image_urls"] as? [Any], !samples.isEmpty { score += 1 }
        if AvbaseMetadata.string(product["sample_movie_url"]) != nil { score += 1 }
        return score
    }

    /// Products carrying an image form the pool when any exist;
    /// the highest score wins, first one on ties (the JS sort is
    /// stable, and so is this scan).
    static func pickProduct(_ products: [Any]?) -> [String: Any]? {
        let list = (products ?? []).compactMap { $0 as? [String: Any] }
        guard !list.isEmpty else { return nil }
        let withImage = list.filter {
            AvbaseMetadata.string($0["image_url"]) != nil
                || AvbaseMetadata.string($0["thumbnail_url"]) != nil
        }
        let pool = withImage.isEmpty ? list : withImage
        var best: [String: Any]?
        var bestScore = -1
        for item in pool {
            let score = productScore(item)
            if score > bestScore { bestScore = score; best = item }
        }
        return best
    }

    // MARK: - Work mapping (avMapWork, list subset)

    static func mapWork(_ work: [String: Any]) -> AVBaseWork? {
        let workID = AvbaseMetadata.string(work["work_id"])
            ?? AvbaseMetadata.string(work["workId"]) ?? ""
        guard !workID.isEmpty else { return nil }
        let prefix = AvbaseMetadata.string(work["prefix"]) ?? ""
        let siteCode = prefix.isEmpty ? workID : "\(prefix):\(workID)"
        let code = aggregateID(number: workID, code: siteCode)
        guard !code.isEmpty else { return nil }

        let product = pickProduct(work["products"] as? [Any])
        let iteminfo = product?["iteminfo"] as? [String: Any]
        let title = AvbaseMetadata.string(work["title"])
            ?? product.flatMap { AvbaseMetadata.string($0["title"]) }
            ?? code

        // avPeoples: casts[].actor first, then actors[]; deduped,
        // order preserved.
        var actresses: [String] = []
        func pushActor(_ actor: Any?) {
            guard let dict = actor as? [String: Any],
                  let name = AvbaseMetadata.string(dict["name"]) else { return }
            if !actresses.contains(name) { actresses.append(name) }
        }
        for cast in work["casts"] as? [Any] ?? [] {
            pushActor((cast as? [String: Any])?["actor"])
        }
        for actor in work["actors"] as? [Any] ?? [] { pushActor(actor) }

        // avGenres: the site's field is tags; genres is compat only.
        var genres: [String] = []
        func pushGenre(_ genre: Any?) {
            guard let dict = genre as? [String: Any] else { return }
            let name = AvbaseMetadata.string(dict["name"])
                ?? AvbaseMetadata.string(dict["title"])
            if let name, !genres.contains(name) { genres.append(name) }
        }
        for tag in work["tags"] as? [Any] ?? [] { pushGenre(tag) }
        for genre in work["genres"] as? [Any] ?? [] { pushGenre(genre) }

        let releaseDate = normDate(AvbaseMetadata.string(work["min_date"]))
            ?? normDate(product.flatMap { AvbaseMetadata.string($0["date"]) })
        let duration = parseMinutes(iteminfo.flatMap { AvbaseMetadata.string($0["volume"]) })
        let summary = iteminfo.flatMap { AvbaseMetadata.string($0["description"]) }
            .map { clean($0) }
            .flatMap { $0.isEmpty ? nil : $0 }

        return AVBaseWork(code: code, siteCode: siteCode, title: clean(title),
                          releaseDate: releaseDate, actresses: actresses,
                          genres: genres, durationMinutes: duration,
                          summary: summary)
    }

    // MARK: - Normalization (avClean / avAggregateId / avNormDate / avParseMinutes)

    /// avClean: whitespace runs collapse to one space, trimmed.
    static func clean(_ value: String?) -> String {
        guard let value else { return "" }
        return value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// avAggregateId: prefer the bare number; drop a "maker:"
    /// prefix (only when the colon is not the first character),
    /// strip all whitespace including full-width spaces, uppercase.
    /// The result is the cross-source identity — never the prefixed
    /// site code.
    static func aggregateID(number: String?, code: String?) -> String {
        let numberText = clean(number)
        let raw = numberText.isEmpty ? clean(code) : numberText
        if raw.isEmpty { return clean(code) }
        var body = raw
        if let colon = raw.firstIndex(of: ":"), colon != raw.startIndex {
            body = String(raw[raw.index(after: colon)...])
        }
        let id = body.components(separatedBy: .whitespaces).joined().uppercased()
        return id.isEmpty ? raw : id
    }

    private static let monthNumbers: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    private static func pad2(_ value: String) -> String {
        value.count == 1 ? "0" + value : value
    }

    private static func pad2(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// avNormDate: the site writes dates two ways —
    /// `2026-11-05` (also / or 年月 separators) and JS Date strings
    /// like `Sat Dec 05 2026 09:00:00 GMT+0900 (Japan Standard Time)`.
    /// Both normalize to yyyy-MM-dd; anything else is nil.
    static func normDate(_ raw: String?) -> String? {
        let text = clean(raw)
        if text.isEmpty { return nil }
        if let match = JRHTML.matches(#"(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})"#, text).first {
            return "\(match[1])-\(pad2(match[2]))-\(pad2(match[3]))"
        }
        if let match = JRHTML.matches(#"([A-Za-z]{3})[a-z]*\s+(\d{1,2}),?\s+(\d{4})"#, text).first,
           let month = monthNumbers[match[1].lowercased()] {
            return "\(match[3])-\(pad2(month))-\(pad2(match[2]))"
        }
        return nil
    }

    /// avParseMinutes: "120分" / "95min" → minutes; a bare number
    /// or anything else is nil (the JS contract, kept as-is).
    static func parseMinutes(_ raw: String?) -> Int? {
        let text = clean(raw)
        guard let match = JRHTML.matches(#"(\d{1,4})\s*(?:分|min)"#, text).first,
              let minutes = Int(match[1]), minutes > 0 else { return nil }
        return minutes
    }

    // MARK: - Pagination rule (build 61)

    /// Whether another page is expected, judged ONLY by what the
    /// current page actually returned (avCollectAllWorks' stop
    /// conditions reduced to one page): a page that came back full
    /// — at least the observed first-page size — may have a
    /// successor; a short or empty page is the last one. Build 60
    /// also trusted the declared total, whose key/shape on
    /// /works/recent is not the one readTotal looks for, so the
    /// total branch is gone: actual returns decide.
    static func hasMore(pageCount: Int, firstPageCount: Int) -> Bool {
        firstPageCount > 0 && pageCount >= firstPageCount
    }

    // MARK: - Talent ranking (build 61, avRankFromHtml / avRankFromProps)

    /// One row of /talents/popular. The JSON snapshot carries names
    /// only; rank badges, movement badges and avatars exist only in
    /// the server-rendered cards, so the DOM parse is primary (the
    /// avbase.js order) and the snapshot is the fallback.
    static func talentRanking(html: String) -> [AVBaseTalentRankEntry] {
        let fromDOM = talentRankingFromDOM(html)
        if !fromDOM.isEmpty { return fromDOM }
        guard let props = AvbaseMetadata.props(html) else { return [] }
        return talentRankingFromProps(props)
    }

    static func talentRankingFromDOM(_ html: String) -> [AVBaseTalentRankEntry] {
        guard let root = try? JRHTML.tree(html) else { return [] }
        var cards: [(parent: JRNode, article: JRNode)] = []
        func collect(_ node: JRNode) {
            for child in node.children {
                if child.tag == "article" { cards.append((node, child)) }
                collect(child)
            }
        }
        collect(root)
        var out: [AVBaseTalentRankEntry] = []
        var seen = Set<String>()
        for (parent, article) in cards {
            let links = article.all {
                $0.tag == "a" && ($0.attrs["href"] ?? "").contains("/talents/")
            }
            guard !links.isEmpty else { continue }
            let img = article.all { $0.tag == "img" }.first
            var name = ""
            var furigana: String?
            if let ruby = article.all({ $0.tag == "ruby" }).first {
                if let rt = ruby.children.first(where: { $0.tag == "rt" }) {
                    let text = clean(rt.text)
                    furigana = text.isEmpty ? nil : text
                }
                name = clean(ruby.children.filter { $0.tag != "rt" }
                    .map(\.text).joined(separator: " "))
            }
            if name.isEmpty, let alt = img?.attrs["alt"] { name = clean(alt) }
            if name.isEmpty { name = clean(links.last?.text) }
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            var rank = 0
            var movement: String?
            for span in parent.children where span.tag == "span" {
                let text = clean(span.text)
                if rank == 0, let value = Int(text), (1...999).contains(value),
                   text == String(value) {
                    rank = value
                    continue
                }
                if movement == nil {
                    movement = rankMovement(label: span.attrs["aria-label"]
                                                ?? span.attrs["title"] ?? "",
                                            glyph: text)
                }
            }
            out.append(AVBaseTalentRankEntry(
                rank: rank == 0 ? out.count + 1 : rank,
                name: name,
                furigana: furigana,
                avatarURL: absoluteURL(img?.attrs["src"] ?? img?.attrs["data-src"]),
                movementText: movement))
        }
        return out.sorted { $0.rank < $1.rank }
    }

    /// avRankMovement: badge label/glyph → display text.
    static func rankMovement(label: String, glyph: String) -> String? {
        let l = clean(label)
        let t = clean(glyph)
        if l.contains("初登場") || t.contains("初登場") { return "新进榜" }
        if let match = JRHTML.matches(#"↑\s*(\d+)"#, t).first { return "上升 \(match[1]) 位" }
        if let match = JRHTML.matches(#"(\d+)\s*位"#, l).first,
           l.contains("上昇") || l.contains("アップ") { return "上升 \(match[1]) 位" }
        if t.contains("↑") || l.contains("上昇") || l.contains("アップ") { return "上升" }
        if let match = JRHTML.matches(#"↓\s*(\d+)"#, t).first { return "下降 \(match[1]) 位" }
        if let match = JRHTML.matches(#"(\d+)\s*位"#, l).first,
           l.contains("下降") || l.contains("ダウン") { return "下降 \(match[1]) 位" }
        if t.contains("↓") || l.contains("下降") || l.contains("ダウン") { return "下降" }
        if l.contains("同順位") || t == "→" || t == "-" { return "持平" }
        return nil
    }

    /// JSON fallback: snapshot.items is just the names in rank
    /// order (talent.primary, else talent.actors[0]) — no avatars,
    /// no movement.
    static func talentRankingFromProps(_ props: [String: Any]) -> [AVBaseTalentRankEntry] {
        var snapshot = props["snapshot"] as? [String: Any]
        if snapshot == nil,
           let superjson = props["_superjson"] as? [String: Any],
           let values = superjson["values"] as? [String: Any] {
            snapshot = values["snapshot"] as? [String: Any]
        }
        let items = snapshot?["items"] as? [Any] ?? []
        var out: [AVBaseTalentRankEntry] = []
        for item in items {
            guard let entry = item as? [String: Any],
                  let talent = entry["talent"] as? [String: Any] else { continue }
            var primary = talent["primary"] as? [String: Any]
            if primary == nil, let actors = talent["actors"] as? [Any] {
                primary = actors.first as? [String: Any]
            }
            guard let name = AvbaseMetadata.string(primary?["name"]) else { continue }
            out.append(AVBaseTalentRankEntry(rank: out.count + 1, name: clean(name),
                                             furigana: nil, avatarURL: nil,
                                             movementText: nil))
        }
        return out
    }

    // MARK: - Talent profile (build 61, avNormTalent / avFindTalent)

    static func talentProfile(html: String) -> AVBaseTalentProfile? {
        guard let props = AvbaseMetadata.props(html) else { return nil }
        return talentProfile(props: props)
    }

    /// avFindTalent: props.talent / .actress / .actor / .person
    /// first; otherwise the first pageProps value that normalizes
    /// AND carries at least one profile field.
    static func talentProfile(props: [String: Any]) -> AVBaseTalentProfile? {
        for key in ["talent", "actress", "actor", "person"] {
            if let raw = props[key] as? [String: Any], let profile = normTalent(raw) {
                return profile
            }
        }
        for (_, value) in props {
            guard let raw = value as? [String: Any],
                  let profile = normTalent(raw) else { continue }
            if profile.birthday != nil || profile.height != nil || profile.bust != nil
                || profile.avatarURL != nil || profile.prefecture != nil {
                return profile
            }
        }
        return nil
    }

    /// avNormTalent: the site's real shape is
    /// { primary: { name, ruby, image_url },
    ///   meta: { basic_info: { birthday, height, bust, waist, hip,
    ///   cup, prefectures }, wikipedia }, actors: [...] } — the name
    /// and avatar live under primary, the measurements under
    /// meta.basic_info; a flat talent.name reads nothing.
    static func normTalent(_ raw: [String: Any]) -> AVBaseTalentProfile? {
        let primary = raw["primary"] as? [String: Any] ?? raw
        let meta = raw["meta"] as? [String: Any] ?? [:]
        let info = meta["basic_info"] as? [String: Any]
            ?? raw["basic_info"] as? [String: Any] ?? [:]
        let name = clean(AvbaseMetadata.string(primary["name"])
            ?? AvbaseMetadata.string(raw["name"]))
        guard !name.isEmpty else { return nil }
        func field(_ key: String) -> String? {
            let value = looseString(info[key]) ?? looseString(raw[key])
            return value.flatMap { clean($0).isEmpty ? nil : clean($0) }
        }
        return AVBaseTalentProfile(
            name: name,
            ruby: field("ruby") ?? AvbaseMetadata.string(primary["ruby"])
                .flatMap { clean($0).isEmpty ? nil : clean($0) },
            avatarURL: absoluteURL(AvbaseMetadata.string(primary["image_url"])
                ?? AvbaseMetadata.string(raw["image_url"])),
            birthday: field("birthday"),
            prefecture: looseString(info["prefectures"])
                .flatMap { clean($0).isEmpty ? nil : clean($0) } ?? field("prefecture"),
            height: field("height"),
            bust: field("bust"),
            waist: field("waist"),
            hip: field("hip"),
            cup: field("cup"))
    }

    // MARK: - Shared helpers

    /// Strings pass through AvbaseMetadata.string; JSON numbers
    /// (height, bust…) stringify instead of dropping.
    static func looseString(_ value: Any?) -> String? {
        if let text = AvbaseMetadata.string(value) { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// avAbsUrl against the AVBase origin.
    static func absoluteURL(_ raw: String?) -> String? {
        let text = clean(raw)
        if text.isEmpty { return nil }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return text }
        if text.hasPrefix("//") { return "https:" + text }
        if text.hasPrefix("/") { return AvbaseMetadata.origin + text }
        return AvbaseMetadata.origin + "/" + text
    }
}

struct AVBaseTalentRankEntry: Equatable {
    var rank: Int
    var name: String
    var furigana: String?
    /// AVBase's own actor image — the only avatar source there is
    /// (the HQ cover chain is for works, not people).
    var avatarURL: String?
    var movementText: String?
}

struct AVBaseTalentProfile: Equatable {
    var name: String
    var ruby: String?
    var avatarURL: String?
    var birthday: String?
    var prefecture: String?
    var height: String?
    var bust: String?
    var waist: String?
    var hip: String?
    var cup: String?

    /// avTalentProfileText, minus the work count (the parser does
    /// not know it; the works page adds it from the list total).
    /// Empty when the page carried no profile fields — the header
    /// then shows the name only, never invented data.
    var summary: String {
        var bits: [String] = []
        if let ruby, !ruby.isEmpty { bits.append("假名 \(ruby)") }
        if let birthday, !birthday.isEmpty { bits.append("生年月日 \(birthday)") }
        if let prefecture, !prefecture.isEmpty { bits.append("出身地 \(prefecture)") }
        if let height, !height.isEmpty {
            bits.append("身長 \(height)\(height.hasSuffix("cm") ? "" : "cm")")
        }
        var size: [String] = []
        if let bust, !bust.isEmpty {
            size.append("B\(bust)\(cup.map { "(\($0))" } ?? "")")
        }
        if let waist, !waist.isEmpty { size.append("W\(waist)") }
        if let hip, !hip.isEmpty { size.append("H\(hip)") }
        if !size.isEmpty { bits.append("サイズ \(size.joined(separator: " "))") }
        return bits.joined(separator: "\n")
    }
}
