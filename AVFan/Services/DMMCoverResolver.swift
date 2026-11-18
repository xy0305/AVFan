//
//  DMMCoverResolver.swift
//  AVFan (ported from AVDB Build 282–285)
//
//  Robust DMM / FANZA HQ cover retrieval, plus the MGStage (MGS) official
//  cover patterns from AVDB's DetailPosterPolicy. CID resolution order:
//  cached exact mapping → label→prefix table (seeded + learned, persisted)
//  → zero-pad variants. URL patterns: awsimgsrc pics_dig digital/video ps
//  (portrait single cover, ~745×1081) → awsimgsrc pl (1600×1081 jacket) →
//  mono/movie (awsimgsrc) → pics.dmm.co.jp. Images are validated (real
//  dimensions, NOW-printing placeholders) before they can win.
//  Pure Foundation; exercised by the parser fixture tests.
//

import Foundation

enum DMMCID {
    /// "MILK-311" → ("milk", 311). Labels with a numeric catalog prefix keep it ("13DSVR-100").
    static func parts(_ number: String) -> (label: String, serial: Int)? {
        let s = number.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let m = JRHTML.matches(#"^([0-9]{0,4}[a-z]{2,10})-?0*([0-9]{1,6})$"#, s).first,
              let n = Int(m[2]), n > 0, !m[1].hasPrefix("fc2") else { return nil }
        return (m[1], n)
    }
    /// Strict CID → catalog number. Letter prefix + digits only:
    /// `ipzz00936` → `IPZZ-936`, `mida00860` → `MIDA-860`.
    /// Rejects `h_`-prefixed CIDs (`h_1240milk00311`) and numeric-prefix
    /// CIDs (`1dldss00575`, `63id00200`) — those are not guessed.
    static func numberFromCID(_ cid: String) -> String? {
        let s = cid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("h_") { return nil }
        guard let m = JRHTML.matches(#"^([a-z]{2,10})0*([0-9]{1,6})$"#, s).first,
              let n = Int(m[2]), n > 0 else { return nil }
        return m[1].uppercased() + "-" + String(n)
    }
    static func pad(_ n: Int, _ width: Int) -> String {
        let digits = String(n)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
    static func make(prefix: String, label: String, serial: Int, width: Int = 5) -> String {
        prefix + label + pad(serial, width)
    }
    /// Learn "h_1240" (+ pad width 5) from a real product id such as "h_1240milk00311".
    static func learn(cid: String, number: String) -> (prefix: String, width: Int)? {
        guard let p = parts(number) else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: p.label)
        guard let m = JRHTML.matches("^(h_[0-9]{1,5}|[0-9]{1,4}|[a-z][0-9])?" + escaped + "([0-9]{2,6})$", cid.lowercased()).first,
              Int(m[2]) == p.serial, m[2].count >= 3 else { return nil }
        return (m[1], m[2].count)
    }
    /// Ordered CID guesses for a catalog number (deduplicated, at most four).
    static func candidates(number: String, table: DMMLabelPrefixes = .shared) -> [String] {
        guard let p = parts(number) else { return [] }
        var out: [String] = []
        func add(_ c: String) { if !out.contains(c) { out.append(c) } }
        if let exact = table.cid(for: number) { add(exact) }
        if let rule = table.rule(for: p.label) { add(make(prefix: rule.prefix, label: p.label, serial: p.serial, width: rule.width)) }
        add(make(prefix: "", label: p.label, serial: p.serial))
        add(make(prefix: "", label: p.label, serial: p.serial, width: 3))
        return Array(out.prefix(4))
    }
}

/// Label → DMM digital CID prefix. Seeded from AVDB's 510-title sample
/// (Build 282) and extended on device whenever a constructed image URL
/// validates. Persisted, capped.
final class DMMLabelPrefixes: @unchecked Sendable {
    struct Rule: Codable, Equatable, Sendable { var prefix: String; var width: Int }
    static let shared = DMMLabelPrefixes(defaults: .standard)
    static let rulesKey = "avfan.dmm.labelPrefix.v1"
    static let cidsKey = "avfan.dmm.cidByNumber.v1"
    static let ruleCap = 3000
    static let cidCap = 2000

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private var learned: [String: Rule]
    private var cids: [String: String]
    private var cidOrder: [String]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        learned = (defaults?.data(forKey: Self.rulesKey)).flatMap { try? JSONDecoder().decode([String: Rule].self, from: $0) } ?? [:]
        let stored = (defaults?.data(forKey: Self.cidsKey)).flatMap { try? JSONDecoder().decode([[String]].self, from: $0) } ?? []
        cids = [:]; cidOrder = []
        for pair in stored where pair.count == 2 { cids[pair[0]] = pair[1]; cidOrder.append(pair[0]) }
    }

    func rule(for label: String) -> Rule? {
        let l = label.lowercased()
        return lock.locked { learned[l] } ?? Self.seed[l].map { Rule(prefix: $0.0, width: $0.1) }
    }
    func cid(for number: String) -> String? {
        guard let key = Self.numberKey(number) else { return nil }
        return lock.locked { cids[key] }
    }
    /// Prefix admission for URL identity checks (a known namespace, never an arbitrary one).
    func allows(label: String, prefix: String) -> Bool {
        guard !prefix.isEmpty else { return true }
        return rule(for: label)?.prefix == prefix
    }
    /// Record a verified product id (from a validated image) for future list + detail use.
    @discardableResult
    func learn(cid: String, number: String) -> Bool {
        guard let p = DMMCID.parts(number), let rule = DMMCID.learn(cid: cid, number: number),
              let key = Self.numberKey(number) else { return false }
        let label = p.label
        lock.locked {
            if learned[label] == nil && learned.count >= Self.ruleCap, let any = learned.keys.first { learned[any] = nil }
            // Only the majority form becomes the label rule; odd paddings stay exact mappings.
            if learned[label] == nil || rule.width == 5 { learned[label] = Rule(prefix: rule.prefix, width: rule.width) }
            if cids[key] == nil { cidOrder.append(key) }
            cids[key] = cid.lowercased()
            while cidOrder.count > Self.cidCap { cids[cidOrder.removeFirst()] = nil }
        }
        persist()
        return true
    }
    func reset() { lock.locked { learned = [:]; cids = [:]; cidOrder = [] }; persist() }
    private func persist() {
        guard let defaults else { return }
        let (r, c) = lock.locked { (learned, cidOrder.compactMap { k in cids[k].map { [k, $0] } }) }
        if let data = try? JSONEncoder().encode(r) { defaults.set(data, forKey: Self.rulesKey) }
        if let data = try? JSONEncoder().encode(c) { defaults.set(data, forKey: Self.cidsKey) }
    }
    static func numberKey(_ number: String) -> String? {
        DMMCID.parts(number).map { $0.label + "-" + String($0.serial) }
    }
    /// (prefix, pad width). AVDB Build 282 seed (scripts/dmm282 sample + pre-282 rules).
    static let seed: [String: (String, Int)] = DMMLabelSeed.table
}

enum DMMCoverURLs {
    static let aws = "https://awsimgsrc.dmm.co.jp/pics_dig"
    static let pics = "https://pics.dmm.co.jp"
    /// Portrait single cover first (awsimgsrc ps is the full-resolution front), then the jacket.
    static func digital(_ cid: String) -> [String] {
        ["\(aws)/digital/video/\(cid)/\(cid)ps.jpg", "\(aws)/digital/video/\(cid)/\(cid)pl.jpg"]
    }
    static func mono(_ cid: String) -> [String] {
        ["\(aws)/mono/movie/\(cid)/\(cid)ps.jpg", "\(aws)/mono/movie/\(cid)/\(cid)pl.jpg"]
    }
    static func legacy(_ cid: String) -> [String] {
        ["\(pics)/digital/video/\(cid)/\(cid)pl.jpg", "\(pics)/mono/movie/adult/\(cid)/\(cid)pl.jpg"]
    }
    static func amateur(_ cid: String) -> String { "\(pics)/digital/amateur/\(cid)/\(cid)jp.jpg" }

    /// Upgrade a metadata DMM image (pics pl / ps, any storefront) to the HQ awsimgsrc pair.
    static func upgrade(_ source: String) -> [String] {
        guard let url = URL(string: source), let host = url.host,
              host == "pics.dmm.co.jp" || host == "awsimgsrc.dmm.co.jp" else { return [] }
        let path = host == "awsimgsrc.dmm.co.jp" ? String(url.path.dropFirst("/pics_dig".count)) : url.path
        if let m = JRHTML.matches(#"^/digital/video/([a-z0-9_]+)/([a-z0-9_]+)(?:ps|pl)\.jpg$"#, path).first, m[1] == m[2] {
            return digital(m[1])
        }
        if let m = JRHTML.matches(#"^/mono/movie/(?:adult/|japanese/)?([a-z0-9_]+)/([a-z0-9_]+)(?:ps|pl)\.jpg$"#, path).first, m[1] == m[2] {
            return mono(m[1])
        }
        return []
    }
    /// CID named by a DMM image path, if any.
    static func cid(_ source: String) -> String? {
        guard let url = URL(string: source) else { return nil }
        let path = url.path
        return JRHTML.matches(#"/(?:digital/(?:video|amateur)|mono/movie(?:/adult|/japanese)?)/([a-z0-9_]+)/([a-z0-9_]+)(?:ps|pl|jp)\.jpg$"#, path)
            .first.flatMap { $0[1] == $0[2] ? $0[1] : nil }
    }
    /// AVDB Build 284: DVD (mono) CID for a digital CID: same namespace, serial without the
    /// 5-digit pad (ipx00706 → ipx706, h_1240milk00311 → h_1240milk311).
    static func monoCID(_ digital: String) -> String? {
        guard let m = JRHTML.matches(#"^([a-z0-9_]*?[a-z])0*([0-9]{1,6})$"#, digital).first, let n = Int(m[2]), n > 0 else { return nil }
        return m[1] + DMMCID.pad(n, 3)
    }
    /// AVDB Build 284: same-image alternates tried inside one selection slot when a DMM URL
    /// fails: other host, then the DVD storefront. Never a different title.
    static func fallbacks(for source: String) -> [String] {
        guard let url = URL(string: source), url.host == "awsimgsrc.dmm.co.jp" || url.host == "pics.dmm.co.jp",
              let cid = cid(source) else { return [] }
        let kind = url.lastPathComponent.hasSuffix("pl.jpg") ? "pl" : (url.lastPathComponent.hasSuffix("ps.jpg") ? "ps" : "")
        guard !kind.isEmpty else { return [] }
        let isDigital = url.path.contains("/digital/video/")
        var out: [String] = []
        if isDigital {
            if kind == "pl" { out.append("\(pics)/digital/video/\(cid)/\(cid)pl.jpg") }
            if let mono = monoCID(cid) {
                out.append("\(aws)/mono/movie/\(mono)/\(mono)\(kind).jpg")
                if kind == "pl" { out.append("\(pics)/mono/movie/adult/\(mono)/\(mono)pl.jpg") }
            }
        } else if kind == "pl" {
            out.append("\(pics)/mono/movie/adult/\(cid)/\(cid)pl.jpg")
        }
        return out.filter { $0 != source }
    }
    static func isJacket(_ source: String) -> Bool {
        guard let url = URL(string: source), ["pics.dmm.co.jp", "awsimgsrc.dmm.co.jp"].contains(url.host ?? "") else { return false }
        return url.lastPathComponent.hasSuffix("pl.jpg")
    }
}

enum DMMImageValidation {
    enum Kind: Equatable { case portrait, jacket, placeholder, tooSmall }
    /// DMM answers missing works with a redirect to now_printing.jpg (or a 404 with the same
    /// 2,732-byte body), with a 147×200 ps or a portrait 590×800 "NOW PRINTING" pl.
    static func isPlaceholderURL(_ url: URL?) -> Bool {
        guard let path = url?.path.lowercased() else { return false }
        return path.contains("now_printing") || path.contains("/noimage/")
    }
    static func classify(width: Int, height: Int, bytes: Int, source: String, finalURL: URL? = nil) -> Kind {
        if isPlaceholderURL(finalURL) || bytes == 2732 { return .placeholder }
        if (width == 147 && height == 200) || (width == 590 && height == 800 && source.hasSuffix("pl.jpg")) { return .placeholder }
        let ratio = Double(width) / Double(max(1, height))
        if source.hasSuffix("pl.jpg") {
            if ratio < 1 { return .placeholder }           // a jacket is never portrait
            return width >= 760 && (1.35...1.65).contains(ratio) ? .jacket : .tooSmall
        }
        return width >= 360 && height >= 500 && (0.5...0.82).contains(ratio) ? .portrait : .tooSmall
    }
    /// AVDB Build 285: front width / jacket height (0.703 standard, 0.69 for h_1240 MILK).
    static let standardFrontRatio = 0.703
    static let milkFrontRatio = 0.69
    static func frontRatio(source: String) -> Double {
        let cid = DMMCoverURLs.cid(source) ?? URL(string: source)?.lastPathComponent.lowercased() ?? ""
        return cid.hasPrefix("h_1240") ? milkFrontRatio : standardFrontRatio
    }
    /// Right-hand front of a DMM jacket.
    static func frontCrop(width: Int, height: Int, source: String = "") -> (x: Int, width: Int)? {
        let ratio = Double(width) / Double(max(1, height))
        guard (1.35...1.65).contains(ratio) else { return nil }
        let w = Int((Double(height) * frontRatio(source: source)).rounded())
        return w < width ? (width - w, w) : nil
    }
}

/// AVDB Build 285: CIDs whose digital ps is only the 147×200 thumbnail (jacket-only titles).
/// Persisted (UserDefaults, 14-day TTL) so the ps probe no longer wastes selection slots.
final class DMMJacketOnly: @unchecked Sendable {
    static let shared = DMMJacketOnly()
    static let defaultsKey = "avfan.dmm.jacketOnly.v1"
    static let ttl: TimeInterval = 14 * 86400
    static let capacity = 2000
    private let lock = NSLock()
    private var entries: [String: Double]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double]) ?? [:]
    }
    func contains(_ cid: String, now: Date = Date()) -> Bool {
        lock.locked {
            guard let t = entries[cid.lowercased()] else { return false }
            return now.timeIntervalSince1970 - t < Self.ttl
        }
    }
    func learn(_ cid: String, now: Date = Date()) {
        let snapshot: [String: Double] = lock.locked {
            entries[cid.lowercased()] = now.timeIntervalSince1970
            if entries.count > Self.capacity {
                for (k, _) in entries.sorted(by: { $0.value < $1.value }).prefix(entries.count - Self.capacity) { entries[k] = nil }
            }
            return entries
        }
        defaults.set(snapshot, forKey: Self.defaultsKey)
    }
    /// A 147×200 digital ps from awsimgsrc / pics marks the CID as jacket-only.
    func observe(source: String, width: Int, height: Int) {
        guard width == 147, height == 200, source.hasSuffix("ps.jpg"), source.contains("/digital/video/"),
              let cid = DMMCoverURLs.cid(source) else { return }
        learn(cid)
    }
    /// Drop the known-tiny ps from a candidate list (the pl jacket stays).
    func filter(_ urls: [String]) -> [String] {
        urls.filter { url in
            guard url.hasSuffix("ps.jpg"), let cid = DMMCoverURLs.cid(url) else { return true }
            return !contains(cid)
        }
    }
}

/// Network policy for DMM image probes (kept from AVDB).
enum DMMProbePolicy {
    static let concurrency = 2
    static let retries = 1
    static func backoff(_ attempt: Int) -> TimeInterval { 0.35 * pow(2, Double(attempt)) }
    /// Retry only transient failures (timeouts / 5xx); a 404 is definitive.
    static func shouldRetry(status: Int?) -> Bool { status == nil || (status! >= 500 && status! < 600) || status == 429 }
    static let negativeTTL: TimeInterval = 300
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
}

/// MGStage official cover URLs, constructed from the catalog number exactly
/// as in AVDB's DetailPosterPolicy (only complete catalog numbers of known
/// MGS maker prefixes; pf_e is the portrait front, pf_o1 the alternate).
enum MGSCoverURLs {
    static let makers: [String: String] = [
        "ABF": "prestige", "ABW": "prestige", "ABP": "prestige",
        "CHN": "prestige", "JUFE": "prestige", "MAAN": "prestige",
        "PPT": "prestige", "390JAC": "jackson",
    ]

    static func candidates(number: String) -> [String] {
        let raw = number.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let regex = try? NSRegularExpression(pattern: #"^([A-Z]+|390JAC)-([0-9]{2,5})$"#),
              let m = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let p = Range(m.range(at: 1), in: raw), let n = Range(m.range(at: 2), in: raw),
              let maker = makers[String(raw[p])],
              let index = Int(raw[n]), index > 0 else { return [] }
        let lower = String(raw[p]).lowercased()
        let plain = String(index)
        let number3 = String(repeating: "0", count: max(0, 3 - plain.count)) + plain
        let digits = number3 == plain ? [plain] : [plain, number3]
        return digits.flatMap { d in
            let base = "https://image.mgstage.com/images/\(maker)/\(lower)/\(d)"
            return ["\(base)/pf_e_\(lower)-\(d).jpg", "\(base)/pf_o1_\(lower)-\(d).jpg"]
        }
    }

    static func isPortraitCandidate(_ url: String) -> Bool {
        url.contains("/pf_e_") || url.contains("/pf_o1_")
    }
}

private extension NSLock {
    func locked<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
