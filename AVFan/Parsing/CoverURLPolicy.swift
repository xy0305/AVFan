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

    private static func looksLikeImage(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains(".png")
            || lower.contains(".webp") || lower.contains("/covers/")
    }

    private static func normalized(_ raw: String) -> String? {
        var value = HTMLParser.unescape(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if value.hasPrefix("//") { value = "https:" + value }
        if value.hasPrefix("/") { value = "https://avfan.com" + value }
        guard value.hasPrefix("http://") || value.hasPrefix("https://") else { return nil }
        if value.contains("gdario.com") || value.contains("/assets/") { return nil }
        return value
    }

    private static func hostOf(_ value: String) -> String {
        URL(string: value)?.host?.lowercased() ?? ""
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
    static func cropRect(width: Int, height: Int, source: String, validatedJacket: Bool = false) -> CGRect? {
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
