import Foundation
import Combine

/// The external database — the same one AVDB uses (build 38,
/// ported from AVDB's ExternalLibrary): a self-hosted server
/// (default: the owner's VPS) queried per movie number for
/// extra download links.
/// GET {base}/api/v1/articles/torrents?keyword=<number>
/// with an X-API-Key header; the token lives in the keychain
/// and no request is sent while disabled or tokenless.

struct ExternalLink: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String?
    let downloadURL: String
    let sizeMB: Double?
    let seeders: Int?
    let chinese: Bool?
    let uncensored: Bool?
    let uhd: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title
        case downloadURL = "download_url"
        case sizeMB = "size_mb"
        case seeders, chinese
        case uncensored = "uc"
        case uhd
    }

    var isMagnet: Bool { downloadURL.lowercased().hasPrefix("magnet:") }
}

private struct ExternalLinkEnvelope: Decodable {
    let data: [ExternalLink]?
}

enum ExternalLibraryError: LocalizedError {
    case invalidURL
    case invalidToken
    case endpointNeedsToken
    case transport
    case http(Int)
    case schema

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "服务器根地址无效。"
        case .invalidToken: return "令牌含无效字符。"
        case .endpointNeedsToken: return "更换服务器须重新填写令牌，或先清除旧令牌。"
        case .transport: return "外部数据库连接失败。"
        case .http(let code): return "外部数据库返回 HTTP \(code)。"
        case .schema: return "外部数据库响应格式无效。"
        }
    }
}

@MainActor
final class ExternalLibrarySettings: ObservableObject {
    static let shared = ExternalLibrarySettings()
    static let defaultBaseURL = "http://163.47.40.207:8000"

    @Published private(set) var baseURL: String
    @Published private(set) var enabled: Bool
    @Published private(set) var hasToken = false
    @Published private(set) var revision: UInt = 0

    private let defaults: UserDefaults
    private let prefix = "avfan.externalLibrary."
    private let tokenAccount = "avfan.externalLibrary.token"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        baseURL = defaults.string(forKey: "avfan.externalLibrary.baseURL") ?? Self.defaultBaseURL
        enabled = defaults.bool(forKey: "avfan.externalLibrary.enabled")
        refreshStatus()
    }

    static func normalizedURL(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = URLComponents(string: value),
              let scheme = p.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = p.host, !host.isEmpty,
              p.user == nil, p.password == nil, p.query == nil, p.fragment == nil,
              p.path.isEmpty || p.path == "/",
              p.port.map({ (1...65535).contains($0) }) ?? true,
              p.url?.host != nil else { throw ExternalLibraryError.invalidURL }
        var normalized = p
        normalized.scheme = scheme
        normalized.path = ""
        guard let result = normalized.url?.absoluteString else { throw ExternalLibraryError.invalidURL }
        return result
    }

    func refreshStatus() {
        hasToken = !(KeychainStore.get(account: tokenAccount) ?? "").isEmpty
    }

    func token() -> String? { KeychainStore.get(account: tokenAccount) }

    func save(baseURL raw: String, enabled: Bool, replacementToken: String) throws {
        let url = try Self.normalizedURL(raw)
        if !replacementToken.isEmpty {
            guard replacementToken.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw ExternalLibraryError.invalidToken
            }
        }
        if url != baseURL && replacementToken.isEmpty && token() != nil {
            throw ExternalLibraryError.endpointNeedsToken
        }
        if !replacementToken.isEmpty { KeychainStore.set(replacementToken, account: tokenAccount) }
        baseURL = url
        self.enabled = enabled
        defaults.set(url, forKey: prefix + "baseURL")
        defaults.set(enabled, forKey: prefix + "enabled")
        changed()
    }

    func clearToken() {
        KeychainStore.remove(account: tokenAccount)
        changed()
    }

    private func changed() {
        revision &+= 1
        ExternalLibraryClient.shared.cancelRequests()
        refreshStatus()
    }
}

final class ExternalRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Reject ALL redirects: the API key never leaves the
        // configured endpoint (same rule as AVDB).
        completionHandler(nil)
    }
}

@MainActor
final class ExternalLibraryClient {
    static let shared = ExternalLibraryClient()
    private var session: URLSession?

    func cancelRequests() {
        session?.invalidateAndCancel()
        session = nil
    }

    private func transport() -> URLSession {
        if let session { return session }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let created = URLSession(configuration: config, delegate: ExternalRedirectBlocker(), delegateQueue: nil)
        session = created
        return created
    }

    /// Extra download links for a movie number. Throws on any
    /// failure; returns [] only for a successful empty answer.
    func fetchLinks(for number: String) async throws -> [ExternalLink] {
        let settings = ExternalLibrarySettings.shared
        let keyword = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.enabled, !keyword.isEmpty else { return [] }
        guard let token = settings.token(), !token.isEmpty else { return [] }
        let generation = settings.revision
        let base = try ExternalLibrarySettings.normalizedURL(settings.baseURL)
        var parts = URLComponents(string: base + "/api/v1/articles/torrents")
        parts?.queryItems = [URLQueryItem(name: "keyword", value: keyword)]
        guard let url = parts?.url else { throw ExternalLibraryError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(token, forHTTPHeaderField: "X-API-Key")
        do {
            let (data, response) = try await transport().data(for: request)
            try Task.checkCancellation()
            guard generation == settings.revision else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse else { throw ExternalLibraryError.transport }
            guard http.statusCode == 200 else { throw ExternalLibraryError.http(http.statusCode) }
            guard let envelope = try? JSONDecoder().decode(ExternalLinkEnvelope.self, from: data),
                  let links = envelope.data else { throw ExternalLibraryError.schema }
            return links
        } catch {
            if Task.isCancelled || generation != settings.revision || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let error = error as? ExternalLibraryError { throw error }
            throw ExternalLibraryError.transport
        }
    }
}
