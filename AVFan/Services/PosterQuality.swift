//
//  PosterQuality.swift
//  AVFan
//
//  AVDB's DetailPosterQuality, ported: a candidate cover is scored by
//  the usable portrait it yields — the decoded bitmap after the front
//  crop for jackets, the bitmap itself for original portraits. Only
//  fixed provenance names are derived from the source host. Rendering
//  never upscales; scores keep native effective pixels.
//

import Foundation

enum PosterProvenance {
    static func label(for source: String) -> String {
        switch URL(string: source)?.host?.lowercased() {
        case "tp.spfcas.com", "c0.jdbstatic.com": return "JavDB"
        case "pics.dmm.co.jp", "awsimgsrc.dmm.co.jp": return "DMM"
        case "m.media-amazon.com", "images-na.ssl-images-amazon.com": return "Amazon"
        case "www.tenhow.net": return "Tenhow"
        case "www.javbus.com": return "JavBus"
        case "image.mgstage.com": return "MGS"
        case "pic.duga.jp": return "DUGA"
        default: return "原始封面/未知来源"
        }
    }
}

struct PosterQuality: Equatable, Sendable {
    let source: String
    /// Effective portrait dimensions (after the front crop when the
    /// source is a jacket).
    let width: Int
    let height: Int
    let originalPortrait: Bool

    var score: Double { min(Double(width) / 0.7, Double(height)) }

    /// 0 = publisher / store original, 1 = other, 2 = JavDB re-host.
    var officialRank: Int {
        switch PosterProvenance.label(for: source) {
        case "DMM", "MGS", "Amazon", "Tenhow", "DUGA": return 0
        case "JavDB": return 2
        default: return 1
        }
    }

    /// Portrait geometry is NOT a semantic classification. 376×538
    /// proven jacket fronts pass, 147×200 thumbnails never do.
    static func eligible(width: Int, height: Int) -> Bool {
        guard width >= 360, height >= 500 else { return false }
        return (0.5...0.82).contains(Double(width) / Double(height))
    }

    static func winner(_ values: [PosterQuality]) -> PosterQuality? {
        let eligible = values.filter { eligible(width: $0.width, height: $0.height) }
        guard let maximum = eligible.map(\.score).max() else { return nil }
        // An untouched portrait within 5% of the maximum linear
        // resolution is preferable to a derived front.
        let originals = eligible.filter { $0.originalPortrait && $0.score >= maximum * 0.95 }
        // Among derived fronts within 5% (e.g. the same jacket cropped
        // from DMM at 0.69 vs a re-host at 0.70), the official source wins.
        let near = eligible.filter { $0.score >= maximum * 0.95 }
        return (originals.isEmpty ? near : originals).sorted {
            if $0.officialRank != $1.officialRank { return $0.officialRank < $1.officialRank }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.originalPortrait != $1.originalPortrait { return $0.originalPortrait }
            return $0.source < $1.source
        }.first
    }
}
