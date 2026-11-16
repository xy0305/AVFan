//
//  HQCoverResolver.swift
//  AVFan
//
//  AVDB's high-resolution cover sources, ported for AVFan and keyed by
//  catalog number (the only identity AVFan shares with those sources):
//  an existing DMM page cover is first upgraded to its awsimgsrc HQ pair,
//  then MGStage official portraits for known maker prefixes, then the
//  DMM/FANZA resolver chain (digital ps → pl, mono, legacy hosts).
//  Every candidate is probe-validated through ImageLoader (real pixel
//  dimensions; NOW-printing placeholders and thumbnails rejected via
//  DMMImageValidation) before it may replace the page cover. Winners are
//  cached per number and their CIDs learned for later lookups.
//  Plain anonymous image GETs only — no site APIs, no credentials.
//

import Foundation
import UIKit

actor HQCoverResolver {
    static let shared = HQCoverResolver()

    static let enabledKey = "avfan.hqCoversEnabled"
    private static let winnersKey = "avfan.hqcover.winners.v1"
    private static let winnerCap = 800
    private static let maxProbes = 8
    private static let negativeTTL: TimeInterval = 6 * 3600

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private var winners: [String: String]
    private var negatives: [String: Date] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]

    private init() {
        winners = (UserDefaults.standard.dictionary(forKey: Self.winnersKey) as? [String: String]) ?? [:]
    }

    /// Synchronous read of the persisted winner cache. Cover decisions
    /// are made from this at load time (see PosterImageModel): a winner
    /// recorded by any earlier probe is used from the first frame in
    /// every view, so the grid and the detail page agree.
    nonisolated static func cachedWinner(for code: String?) -> String? {
        guard let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let key = DMMLabelPrefixes.numberKey(raw) else { return nil }
        let persisted = (UserDefaults.standard.dictionary(forKey: winnersKey) as? [String: String]) ?? [:]
        return persisted[key]
    }

    /// The validated HQ cover URL for a catalog number, or nil when no
    /// source validated (the caller keeps the page cover).
    func winner(for code: String?, pageCover: String?) async -> String? {
        guard Self.enabled else { return nil }
        guard let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let key = DMMLabelPrefixes.numberKey(raw) else { return nil }
        if let cached = winners[key] {
            return cached == pageCover ? nil : cached
        }
        if let neg = negatives[key], Date().timeIntervalSince(neg) < Self.negativeTTL { return nil }
        if let existing = inFlight[key] { return await existing.value }
        let task = Task<String?, Never> {
            await self.resolve(key: key, code: raw, pageCover: pageCover)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func resolve(key: String, code: String, pageCover: String?) async -> String? {
        let candidates = Self.candidates(code: code, pageCover: pageCover)
        let portraits = candidates.filter { Self.isPortraitCandidate($0) }
        let jackets = candidates.filter { !Self.isPortraitCandidate($0) }
        var probes = 0
        for url in portraits + jackets {
            if probes >= Self.maxProbes { break }
            probes += 1
            if url == pageCover { continue }
            guard let image = await ImageLoader.shared.load(url, maxPixelSize: 1600, timeout: 10) else { continue }
            let width = image.cgImage?.width ?? Int(image.size.width)
            let height = image.cgImage?.height ?? Int(image.size.height)
            if Self.validates(url: url, width: width, height: height) {
                recordWinner(key: key, url: url, code: code)
                return url
            }
            DMMJacketOnly.shared.observe(source: url, width: width, height: height)
        }
        negatives[key] = Date()
        return nil
    }

    private func recordWinner(key: String, url: String, code: String) {
        winners[key] = url
        if winners.count > Self.winnerCap {
            for k in winners.keys.prefix(winners.count - Self.winnerCap) { winners[k] = nil }
        }
        UserDefaults.standard.set(winners, forKey: Self.winnersKey)
        if let cid = DMMCoverURLs.cid(url) {
            DMMLabelPrefixes.shared.learn(cid: cid, number: code)
        }
    }

    // MARK: - Candidate construction

    static func candidates(code: String, pageCover: String?) -> [String] {
        var out: [String] = []
        func add(_ s: String) { if !out.contains(s) { out.append(s) } }
        if let pageCover {
            for u in DMMCoverURLs.upgrade(pageCover) { add(u) }
        }
        for u in MGSCoverURLs.candidates(number: code) { add(u) }
        let cids = DMMCID.candidates(number: code)
        for cid in cids {
            for u in DMMCoverURLs.digital(cid) { add(u) }
        }
        if let first = cids.first {
            if let mono = DMMCoverURLs.monoCID(first) {
                for u in DMMCoverURLs.mono(mono) { add(u) }
            }
            for u in DMMCoverURLs.legacy(first) { add(u) }
        }
        return DMMJacketOnly.shared.filter(out)
    }

    private static func isPortraitCandidate(_ url: String) -> Bool {
        url.hasSuffix("ps.jpg") || MGSCoverURLs.isPortraitCandidate(url)
    }

    private static func validates(url: String, width: Int, height: Int) -> Bool {
        if (url as NSString).lastPathComponent.isEmpty { return false }
        if url.contains("image.mgstage.com") {
            // MGS pf_e / pf_o1 are portrait fronts; require a real portrait.
            return width >= 360 && height >= 500 && (0.5...0.85).contains(Double(width) / Double(max(1, height)))
        }
        switch DMMImageValidation.classify(width: width, height: height, bytes: 0, source: url) {
        case .portrait, .jacket: return true
        case .placeholder, .tooSmall: return false
        }
    }
}
