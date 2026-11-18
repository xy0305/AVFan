import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Picks a cover URL that is already present in fetched public HTML.
/// Prefers official DMM / FANZA front portraits, then official jackets,
/// then c1.avfan.com covers. Never invents or rewrites hosts.
enum CoverURLPolicy {
    static func preferred(from candidates: [String]) -> String? {
        let unique = uniqued(candidates.compactMap(normalized(_:)))
        guard !unique.isEmpty else { return nil }
        return unique.max(by: { score($0) < score($1) })
    }

    static func collect(from html: String) -> [String] {
        var found: [String] = []
        let patterns = [
            "<img[^>]+src=\"([^\"]+)\"",
            "<img[^>]+data-src=\"([^\"]+)\"",
            "<img[^>]+data-original=\"([^\"]+)\"",
            "srcset=\"([^\"]+)\"",
            "<img[^>]+src='([^']+)'",
            "<img[^>]+data-src='([^']+)'",
            "<img[^>]+data-original='([^']+)'",
            "srcset='([^']+)'",
            "property=\"og:image\"\\s+content=\"([^\"]+)\"",
            "content=\"([^\"]+)\"[^>]*property=\"og:image\"",
            "thumbnailUrl\"\\s*:\\s*\"([^\"]+)\"",
            "(https?://[^\"'\\s<>]+(?:c1\\.avfan\\.com|dmm\\.co\\.jp|dmm\\.com|fanza\\.tv|awsimgsrc)[^\"'\\s<>]*)",
        ]
        for pattern in patterns {
            found.append(contentsOf: HTMLParser.allMatches(pattern, in: html))
        }
        var expanded: [String] = []
        for item in found {
            if item.contains(" ") || item.contains(",") {
                for part in item.split(whereSeparator: { $0 == "," }) {
                    let url = part.trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: " ").first.map(String.init) ?? ""
                    if !url.isEmpty { expanded.append(url) }
                }
            } else {
                expanded.append(item)
            }
        }
        return uniqued(expanded.compactMap(normalized(_:)))
    }

    static func preferred(in html: String, fallback: String? = nil) -> String? {
        var candidates = collect(from: html)
        if let fallback { candidates.append(fallback) }
        return preferred(from: candidates)
    }

    static func isOfficialStoreImage(_ value: String) -> Bool {
        guard looksLikeImage(value), !looksLikeVideo(value) else { return false }
        let host = hostOf(value)
        return host.contains("dmm.co.jp") || host.contains("dmm.com")
            || host.contains("fanza") || host.contains("awsimgsrc")
    }

    /// Official front-only portraits (DMM `ps.jpg` and similar), not the full jacket.
    static func isOfficialFrontPortrait(_ value: String) -> Bool {
        guard isOfficialStoreImage(value) else { return false }
        let lower = value.lowercased()
        if lower.contains("ps.jpg") || lower.contains("ps.jpeg") || lower.contains("ps.webp") { return true }
        if lower.contains("/digital/video/") && lower.contains("jp-") { return true }
        return false
    }

    static func isAvfanCover(_ value: String) -> Bool {
        let host = hostOf(value)
        return host.contains("avfan.com") && value.lowercased().contains("/covers/")
    }

    static func isLikelyJacketURL(_ value: String) -> Bool {
        if isOfficialFrontPortrait(value) { return false }
        if isAvfanCover(value) { return true }
        if isOfficialStoreImage(value) {
            let lower = value.lowercased()
            if lower.contains("pl.jpg") || lower.contains("pl.jpeg") || lower.contains("pl.webp") { return true }
            if lower.contains("pb_e_") { return true }
            return true
        }
        return false
    }

    private static func score(_ value: String) -> Int {
        if isOfficialFrontPortrait(value) { return 400 }
        if isOfficialStoreImage(value) { return 300 }
        if isAvfanCover(value) { return 200 }
        if looksLikeImage(value) { return 50 }
        return 0
    }

    static func looksLikeImage(_ value: String) -> Bool {
        if looksLikeVideo(value) { return false }
        let lower = value.lowercased()
        return lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains(".png")
            || lower.contains(".webp") || lower.contains("/covers/")
    }

    static func looksLikeVideo(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains(".mp4") || lower.contains(".m4v") || lower.contains(".m3u8")
            || lower.contains("/pv/") || lower.contains("/hls/")
    }

    private static func normalized(_ raw: String) -> String? {
        var value = HTMLParser.unescape(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if value.hasPrefix("//") { value = "https:" + value }
        if value.hasPrefix("/") { value = "https://avfan.com" + value }
        guard value.hasPrefix("http://") || value.hasPrefix("https://") else { return nil }
        if value.contains("gdario.com") || value.contains("/assets/") { return nil }
        if looksLikeVideo(value) { return nil }
        guard looksLikeImage(value) || isAvfanCover(value) else { return nil }
        return value
    }

    private static func hostOf(_ value: String) -> String {
        URL(string: value)?.host?.lowercased() ?? ""
    }

    /// Build 45 “same file”: the same artwork URL, or a higher-resolution
    /// fetch of that same file (pics.dmm.co.jp ↔ awsimgsrc.dmm.co.jp with
    /// the same path and the same ps/pl kind). A ps portrait and a pl
    /// jacket are different files. Different avfan cover hashes are
    /// different files.
    static func isSameFile(_ a: String?, _ b: String?) -> Bool {
        guard let a, !a.isEmpty, let b, !b.isEmpty else { return false }
        if a == b { return true }
        guard let ia = fileIdentity(a), let ib = fileIdentity(b) else { return false }
        return ia == ib
    }

    /// Normalized identity for “is this the same artwork file?”.
    static func fileIdentity(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var value = trimmed
        if value.hasPrefix("//") { value = "https:" + value }
        guard let url = URL(string: value), let host = url.host?.lowercased() else {
            return value.lowercased()
        }
        var path = url.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        let family: String
        if host == "pics.dmm.co.jp" || host == "awsimgsrc.dmm.co.jp" {
            family = "dmm"
            if host == "awsimgsrc.dmm.co.jp", path.hasPrefix("/pics_dig") {
                path = String(path.dropFirst("/pics_dig".count))
            }
        } else {
            family = host
        }
        return family + ":" + path.lowercased()
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values where seen.insert(value).inserted {
            out.append(value)
        }
        return out
    }
}

/// AVDB-style DVD-front crop window (Build 332 geometry).
/// Pure numbers: the front of a standard jacket is the right-aligned ~0.70·height slice.
enum FrontPosterPolicy {
    static func cropRect(width: Int, height: Int, source: String, validatedJacket: Bool = false, usesOriginalCover: Bool = false) -> CGRect? {
        if usesOriginalCover { return nil }
        guard width > 0, height > 0 else { return nil }
        if CoverURLPolicy.isOfficialFrontPortrait(source) { return nil }
        let known = CoverURLPolicy.isLikelyJacketURL(source) || validatedJacket
        guard known else { return nil }
        let ratio = Double(width) / Double(height)
        // Standard DVD jacket only; never slice arbitrary landscape photos.
        guard (1.35...1.65).contains(ratio) else { return nil }
        let measured = CoverURLPolicy.isOfficialStoreImage(source)
        let frontRatio = measured ? 0.703 : 0.70
        let frontWidth = Int((Double(height) * frontRatio).rounded())
        guard frontWidth > 0, frontWidth < width else { return nil }
        return CGRect(x: width - frontWidth, y: 0, width: frontWidth, height: height)
    }
}

/// Build 57: 欧美 / 无码 titles keep the avfan page cover as-is — no
/// FrontPosterPolicy crop and no HQCoverResolver swap. Type comes from
/// explicit list context, then a parsed detail-page type, then a tight
/// code/maker heuristic used only when the type is still unknown.
enum CatalogCoverPolicy {
    static func usesOriginalAvfanCover(_ type: CatalogType?) -> Bool {
        type == .western || type == .uncensored
    }

    static func usesOriginalAvfanCover(explicit: CatalogType?, code: String?, makers: [String] = []) -> Bool {
        usesOriginalAvfanCover(resolvedType(explicit: explicit, code: code, makers: makers))
    }

    static func resolvedType(explicit: CatalogType?, code: String?, makers: [String] = []) -> CatalogType? {
        if let explicit { return explicit }
        return inferredType(code: code, makers: makers)
    }

    /// Heuristic only: western `studio.YYYY.MM.DD` codes, or well-known
    /// uncensored makers. FC2 / FC2-PPV never counts as 无码 here.
    static func inferredType(code: String?, makers: [String] = []) -> CatalogType? {
        if isWesternDateCode(code) { return .western }
        if isUncensoredMaker(code: code, makers: makers) { return .uncensored }
        return nil
    }

    static func isWesternDateCode(_ code: String?) -> Bool {
        guard let code, !code.isEmpty else { return false }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(
            of: #"^[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)*\.\d{4}\.\d{2}\.\d{2}$"#,
            options: .regularExpression
        ) != nil
    }

    static func isFC2(_ code: String?) -> Bool {
        guard let code else { return false }
        let n = code.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "")
        return n.hasPrefix("fc2")
    }

    private static let uncensoredMarkers = [
        "1pondo", "一本道",
        "caribbeancom", "caribbean", "カリビアンコム", "カリビアン",
        "heyzo",
        "tokyohot", "tokyo-hot", "tokyo_hot", "東京熱", "东京热",
        "pacopacomama", "10musume", "muramura",
        "kin8tengoku", "gachinco", "heydouga",
    ]

    static func isUncensoredMaker(code: String?, makers: [String]) -> Bool {
        if isFC2(code) { return false }
        let parts = ([code].compactMap { $0 } + makers)
        for raw in parts {
            let n = normalizeMarker(raw)
            if n.hasPrefix("fc2") { continue }
            for marker in uncensoredMarkers {
                if n.contains(normalizeMarker(marker)) { return true }
            }
        }
        return false
    }

    private static func normalizeMarker(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
    }
}

extension MovieCard {
    var usesOriginalAvfanCover: Bool {
        CatalogCoverPolicy.usesOriginalAvfanCover(explicit: catalogType, code: code)
    }

    var hqCoverCode: String? { usesOriginalAvfanCover ? nil : code }
}

extension MovieDetail {
    var usesOriginalAvfanCover: Bool {
        CatalogCoverPolicy.usesOriginalAvfanCover(explicit: catalogType, code: code, makers: makers.map(\.name))
    }
}

extension BookmarkItem {
    var usesOriginalAvfanCover: Bool {
        CatalogCoverPolicy.usesOriginalAvfanCover(explicit: catalogType, code: code)
    }
}
