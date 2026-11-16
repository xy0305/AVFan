//
//  HQCoverResolver.swift
//  AVFan
//
//  AVDB's high-resolution cover chain, ported for AVFan and keyed by
//  catalog number (the only identity AVFan shares with those sources):
//
//  - Baseline candidates built from the number alone: an existing DMM
//    page cover upgraded to its awsimgsrc HQ pair, MGStage official
//    portraits for known maker prefixes, the DMM/FANZA resolver chain
//    (digital ps → pl, mono, legacy hosts).
//  - Discovery, running alongside the baseline: Tenhow actor pages
//    matched by their linked FANZA record (the record's own image,
//    the exact-ASIN Amazon HQ front, and the record's exact DMM
//    pair), and the avbase catalogue record for the number (its bound
//    DMM pair plus DUGA / MGS package extras).
//  - Supplemental: the JavBus detail page's identity-checked main
//    jacket.
//  - Selection is AVDB's scored winner, not first-hit: every decoded
//    candidate is measured by the usable portrait it yields (front
//    crop for jackets), filtered by DetailPosterPolicy eligibility,
//    and ranked by score with official-source preference. At most 6
//    image decodes, 2 at a time, inside a 12-second budget.
//
//  Winners are cached per number and their CIDs learned for later
//  lookups. Plain anonymous GETs only — no site APIs, no credentials,
//  no cookies. Sources that exist only inside JavDB's own API payload
//  have no AVFan equivalent and are not synthesized.
//

import Foundation
import UIKit

actor HQCoverResolver {
    static let shared = HQCoverResolver()

    static let enabledKey = "avfan.hqCoversEnabled"
    private static let winnersKey = "avfan.hqcover.winners.v1"
    private static let winnerCap = 800
    private static let negativeTTL: TimeInterval = 6 * 3600
    private static let maxDecodes = 6
    private static let totalBudget: TimeInterval = 12

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
    /// source validated (the caller keeps the page cover). `actors`
    /// (display names from the detail page) enables Tenhow discovery.
    func winner(for code: String?, pageCover: String?, actors: [String] = []) async -> String? {
        guard Self.enabled else { return nil }
        guard let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let key = DMMLabelPrefixes.numberKey(raw) else { return nil }
        if let cached = winners[key] {
            return cached == pageCover ? nil : cached
        }
        if let neg = negatives[key], Date().timeIntervalSince(neg) < Self.negativeTTL { return nil }
        if let existing = inFlight[key] { return await existing.value }
        let task = Task<String?, Never> {
            await self.resolve(key: key, code: raw, pageCover: pageCover, actors: actors)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func resolve(key: String, code: String, pageCover: String?, actors: [String]) async -> String? {
        let deadline = ProcessInfo.processInfo.systemUptime + Self.totalBudget
        let baseline = Self.candidates(code: code, pageCover: pageCover)
        // Discovery and the supplemental JavBus lookup run alongside
        // the baseline decodes, never as a serial gate before them.
        async let tenhowFound = Self.discoverTenhow(code: code, actors: actors)
        async let avbaseFound = Self.discoverAvbase(code: code)
        async let javbusFound = Self.discoverJavBus(code: code)

        var pool: [PosterQuality] = []
        // Baseline first, with priority: at most 4 baseline decodes
        // before discovered candidates join the pool.
        let head = Array(baseline.prefix(4))
        pool += await Self.decode(head, discovered: false, deadline: deadline)

        let tenhowURLs = await tenhowFound
        let avbaseURLs = await avbaseFound
        let javbusURLs = await javbusFound
        let discovered = tenhowURLs + avbaseURLs + javbusURLs
        var queue: [String] = []
        for url in discovered + Array(baseline.dropFirst(4)) where !queue.contains(url) && !head.contains(url) {
            queue.append(url)
        }
        let tail = Array(queue.prefix(max(0, Self.maxDecodes - head.count)))
        pool += await Self.decode(tail, discovered: true, deadline: deadline)

        guard let winner = PosterQuality.winner(pool) else {
            negatives[key] = Date()
            return nil
        }
        recordWinner(key: key, url: winner.source, code: code)
        return winner.source == pageCover ? nil : winner.source
    }

    /// Decode a batch two at a time and score what came back.
    private static func decode(_ urls: [String], discovered: Bool, deadline: TimeInterval) async -> [PosterQuality] {
        var out: [PosterQuality] = []
        var index = 0
        while index < urls.count {
            guard ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled else { break }
            let batch = Array(urls[index..<min(index + 2, urls.count)])
            index += batch.count
            let results = await withTaskGroup(of: PosterQuality?.self) { group in
                for url in batch {
                    group.addTask { await Self.quality(for: url, discovered: discovered) }
                }
                var collected: [PosterQuality] = []
                for await quality in group { if let quality { collected.append(quality) } }
                return collected
            }
            out += results
        }
        return out
    }

    private static func quality(for url: String, discovered: Bool) async -> PosterQuality? {
        guard let image = await ImageLoader.shared.load(url, maxPixelSize: 1600, timeout: 6) else { return nil }
        let width = image.cgImage?.width ?? Int(image.size.width)
        let height = image.cgImage?.height ?? Int(image.size.height)
        guard width > 0, height > 0 else { return nil }
        if !discovered {
            // Rule-built candidates keep the placeholder discipline:
            // a DMM NOW-printing placeholder never scores.
            if url.contains("dmm.co.jp") {
                switch DMMImageValidation.classify(width: width, height: height, bytes: 0, source: url) {
                case .placeholder, .tooSmall: return nil
                case .portrait, .jacket: break
                }
            }
            if url.contains("image.mgstage.com"), !PosterQuality.eligible(width: width, height: height) {
                // MGS pf_e / pf_o1 are portrait fronts; anything else is a miss.
                return nil
            }
        }
        DMMJacketOnly.shared.observe(source: url, width: width, height: height)
        if let rect = FrontPosterPolicy.cropRect(width: width, height: height, source: url, validatedJacket: discovered) {
            return PosterQuality(source: url, width: Int(rect.width), height: Int(rect.height), originalPortrait: false)
        }
        if PosterQuality.eligible(width: width, height: height) {
            return PosterQuality(source: url, width: width, height: height, originalPortrait: true)
        }
        return nil
    }

    // MARK: - Discovery

    /// Tenhow: the movie's actors lead to Tenhow actor pages; a record
    /// whose linked FANZA CID is exactly this number yields its image,
    /// the exact-ASIN Amazon HQ front, and the record's exact DMM pair.
    private static func discoverTenhow(code: String, actors: [String]) async -> [String] {
        guard !actors.isEmpty else { return [] }
        let paths = TenhowPoster.pages(identities: actors.map { [$0] })
        var out: [String] = []
        for path in paths {
            guard let url = URL(string: "https://www.tenhow.net" + path),
                  let page = await DiscoveryPageCache.shared.page(url, positiveTTL: 6 * 3600, negativeTTL: 300),
                  let match = try? TenhowPoster.match(html: page.html, number: code) else { continue }
            out += match.images
            for image in match.images {
                if let imageURL = URL(string: image), let asin = AmazonPoster.asin(imageURL),
                   let hq = AmazonPoster.directHQ(asin: asin) {
                    out.append(hq)
                }
            }
            out += match.official
        }
        return out
    }

    /// avbase: the catalogue record bound to this number contributes
    /// its DMM pair and same-work store extras (DUGA / MGS).
    private static func discoverAvbase(code: String) async -> [String] {
        await CataloguePosterService.shared.lookup(number: code)?.images ?? []
    }

    /// JavBus: the detail page's identity-checked main jacket.
    private static func discoverJavBus(code: String) async -> [String] {
        guard let pageURL = JavBusPoster.page(number: code),
              let page = await DiscoveryPageCache.shared.page(pageURL, positiveTTL: 6 * 3600, negativeTTL: 30 * 60),
              let images = try? JavBusPoster.images(html: page.html, number: code, finalURL: page.finalURL) else { return [] }
        return images
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
}

/// HTML page cache for the discovery sources, with per-source TTLs
/// (AVDB: 6h positive; negative 30 min for JavBus, 5 min for Tenhow).
actor DiscoveryPageCache {
    static let shared = DiscoveryPageCache()

    private struct Entry { let page: (html: String, finalURL: URL)?; let expires: Date }
    private var entries: [String: Entry] = [:]

    func page(_ url: URL, positiveTTL: TimeInterval, negativeTTL: TimeInterval) async -> (html: String, finalURL: URL)? {
        let key = url.absoluteString
        if let entry = entries[key] {
            if entry.expires > Date() { return entry.page }
            entries[key] = nil
        }
        let fetched = await CataloguePosterService.fetchPage(url, timeout: 4)
        entries[key] = Entry(page: fetched, expires: Date().addingTimeInterval(fetched == nil ? negativeTTL : positiveTTL))
        if entries.count > 256, let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key {
            entries[oldest] = nil
        }
        return fetched
    }
}
