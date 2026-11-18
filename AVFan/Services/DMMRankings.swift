import Foundation

// Build 58: the DMM board goes live. Until now it rode AVDB's
// pre-matched feed (dmm-daily / dmm-weekly, frozen 2026-11-14);
// it now fetches FANZA's official ranking on device, exactly the
// way AVDB does — the verified read-only GraphQL at
// api.video.dmm.co.jp/graphql (AVDB's DMMRankingGraphQL, probed
// 2026-10-27; only the independently confirmed PPVContentRanking
// field shapes are used, introspection is disabled server-side).
//
// Requests are cookie-free ephemeral POSTs, byte-for-byte AVDB's
// approach: no cookies are sent or stored, so neither an avfan
// login nor a FANZA age-check session is involved — the age_check
// gate applies to FANZA's HTML pages, which this loader never
// fetches (AVDB's adult self-declaration is the local consent
// switch for its HTML transports, not a wire requirement here).
//
// The ranking summary carries CIDs only; the maker code
// (メーカー品番) comes from a second verified query
// (ppvContent.makerContentId), never derived from the CID.
// Entries whose maker code cannot be resolved are dropped — an
// AVFan board row is useless without the code it matches by —
// and a wholesale failure fails the whole board (the view shows
// its error state) instead of falling back to the frozen feed.

enum DMMRankingsError: LocalizedError {
    case accessGate
    case malformed
    case incomplete
    case empty

    var errorDescription: String? {
        switch self {
        case .accessGate: return "FANZA 榜单暂时取不到（官方接口未放行），请稍后重试。"
        case .malformed, .incomplete: return "FANZA 榜单数据不完整，请稍后重试。"
        case .empty: return "FANZA 榜单没有解析到可匹配的条目。"
        }
    }
}

struct DMMRankingRow {
    let rank: Int
    let cid: String
    let title: String
    /// Official maker code (メーカー品番), e.g. "MKMP-659".
    let code: String
    /// FANZA official cover (awsimgsrc ps portrait front).
    let coverURL: String?
}

enum DMMRankings {
    static let endpoint = URL(string: "https://api.video.dmm.co.jp/graphql")!

    // MARK: - Term specs (daily / weekly keep the board's terms)

    private struct TermSpec {
        let expectedCount: Int
        let filter: [String: Any]
        let referer: URL
    }

    private static func spec(for term: String) -> TermSpec? {
        switch term {
        case "daily":
            return TermSpec(expectedCount: 20,
                            filter: ["daily": ["floor": "AV"]],
                            referer: URL(string: "https://video.dmm.co.jp/av/ranking/?term=daily")!)
        case "weekly":
            return TermSpec(expectedCount: 100,
                            filter: ["weekly": ["floor": "AV"]],
                            referer: URL(string: "https://video.dmm.co.jp/av/ranking/?term=weekly")!)
        default:
            return nil
        }
    }

    // MARK: - GraphQL payloads (pure; ported from AVDB)

    private static let contentQuery = """
    query AVFanContentRanking($limit: Int!, $offset: Int!, $filter: PPVContentRankingFilterInput) {
      ppvContentRanking(limit: $limit, offset: $offset, filter: $filter) {
        __typename
        items {
          id
          rank
          content {
            id
            title
          }
        }
      }
    }
    """

    static func rankingPayload(term: String) throws -> Data {
        guard let spec = spec(for: term) else { throw DMMRankingsError.malformed }
        let body: [String: Any] = [
            "query": contentQuery,
            "operationName": "AVFanContentRanking",
            "variables": [
                "limit": spec.expectedCount,
                "offset": 0,
                "filter": spec.filter
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func makerCodePayload(cids: [String]) throws -> Data {
        var selections: [String] = []
        var variables: [String: Any] = [:]
        var defs: [String] = []
        for (i, cid) in cids.enumerated() {
            defs.append("$id\(i): ID!")
            selections.append("c\(i): ppvContent(id: $id\(i)) { id makerContentId }")
            variables["id\(i)"] = cid
        }
        let query = "query AVFanMakerCodes(\(defs.joined(separator: ", "))) { \(selections.joined(separator: " ")) }"
        return try JSONSerialization.data(withJSONObject: [
            "query": query,
            "operationName": "AVFanMakerCodes",
            "variables": variables
        ])
    }

    // MARK: - Response parsing (pure; ported from AVDB)

    struct ContentItem {
        let rank: Int
        let cid: String
        let title: String
    }

    /// Fail-closed like AVDB: a GraphQL errors payload is an
    /// access gate, and the ranks must be exactly 1...expectedCount.
    static func contentItems(data: Data, expectedCount: Int) throws -> [ContentItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DMMRankingsError.malformed
        }
        if let errors = root["errors"] as? [Any], !errors.isEmpty {
            throw DMMRankingsError.accessGate
        }
        guard let dataObj = root["data"] as? [String: Any],
              let ranking = dataObj["ppvContentRanking"] as? [String: Any],
              let items = ranking["items"] as? [[String: Any]], !items.isEmpty else {
            throw DMMRankingsError.accessGate
        }
        var rows: [ContentItem] = []
        for item in items {
            guard let rank = item["rank"] as? Int,
                  let content = item["content"] as? [String: Any],
                  let cid = (content["id"] as? String) ?? (item["id"] as? String),
                  cid.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil, cid.count <= 100,
                  let title = content["title"] as? String, !title.isEmpty else {
                throw DMMRankingsError.malformed
            }
            rows.append(ContentItem(rank: rank, cid: cid, title: title))
        }
        rows.sort { $0.rank < $1.rank }
        guard rows.map(\.rank) == Array(1...expectedCount) else {
            throw DMMRankingsError.incomplete
        }
        return rows
    }

    static func makerCodes(data: Data, expectedCIDs: [String]) throws -> [String: String] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DMMRankingsError.malformed
        }
        if let errors = root["errors"] as? [Any], !errors.isEmpty {
            throw DMMRankingsError.accessGate
        }
        guard let dataObj = root["data"] as? [String: Any] else {
            throw DMMRankingsError.accessGate
        }
        var out: [String: String] = [:]
        for (i, cid) in expectedCIDs.enumerated() {
            guard let record = dataObj["c\(i)"] as? [String: Any],
                  let id = record["id"] as? String, id == cid,
                  let raw = record["makerContentId"] as? String,
                  let code = manufacturerCode(raw) else { continue }
            out[cid] = code
        }
        return out
    }

    /// Official メーカー品番 / GraphQL makerContentId only.
    /// Never derived from CID (AVDB's DMMRankingCore rule).
    static func manufacturerCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty, code.unicodeScalars.allSatisfy({ $0.isASCII }),
              code.range(of: "^[A-Z0-9]+-[A-Z0-9]+$", options: .regularExpression) != nil else { return nil }
        return code
    }

    // MARK: - Live loading

    static func load(term: String) async throws -> [DMMRankingRow] {
        guard let spec = spec(for: term) else { throw DMMRankingsError.malformed }
        let data = try await post(body: try rankingPayload(term: term), referer: spec.referer)
        let items = try contentItems(data: data, expectedCount: spec.expectedCount)
        let codes = try await makerCodes(cids: items.map(\.cid))
        let rows = items.compactMap { item -> DMMRankingRow? in
            guard let code = codes[item.cid] else { return nil }
            return DMMRankingRow(rank: item.rank, cid: item.cid, title: item.title,
                                 code: code,
                                 coverURL: DMMCoverURLs.digital(item.cid).first)
        }
        guard !rows.isEmpty else { throw DMMRankingsError.empty }
        return rows
    }

    /// Batched ppvContent lookups, 10 CIDs per query, serial —
    /// the same polite pacing AVDB uses.
    private static func makerCodes(cids: [String]) async throws -> [String: String] {
        var out: [String: String] = [:]
        let unique = cids.filter {
            $0.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil && $0.count <= 100
        }
        var index = 0
        while index < unique.count {
            let end = min(index + 10, unique.count)
            let chunk = Array(unique[index..<end])
            index = end
            let body = try makerCodePayload(cids: chunk)
            let data = try await post(body: body,
                                      referer: URL(string: "https://video.dmm.co.jp/av/ranking/?term=weekly")!)
            let part = try makerCodes(data: data, expectedCIDs: chunk)
            for (cid, code) in part { out[cid] = code }
        }
        return out
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// Cookie-free ephemeral POST. Host is fixed to the verified
    /// GraphQL endpoint (AVDB's transport, unchanged).
    private static func post(body: Data, referer: URL) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://video.dmm.co.jp", forHTTPHeaderField: "Origin")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url == endpoint, data.count <= 8_000_000 else {
            throw DMMRankingsError.accessGate
        }
        return data
    }
}
