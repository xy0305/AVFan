import Foundation

/// Diagnostic failure type used by the player chrome. Not an online-source catalog.
enum OnlineFailure: Error, LocalizedError, CustomNSError, Equatable {
    static var errorDomain: String { "AVFan.OnlineFailure" }
    var errorCode: Int { 1 }
    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? "请求失败",
         "AVFan.SafeDiagnostic": presentation(at: .unknown)]
    }
    static func bridgedDiagnostic(_ error: NSError) -> PlaybackDiagnostic? {
        guard error.domain == errorDomain || error.domain == "AVDB.OnlineFailure", error.code == 1 else { return nil }
        return (error.userInfo["AVFan.SafeDiagnostic"] as? PlaybackDiagnostic)
            ?? (error.userInfo["AVDB.SafeDiagnostic"] as? PlaybackDiagnostic)
    }
    case noMatch, blocked, tls, parse, timeout, unsafe, resolver, tooLarge, cancelled, unsupported, incomplete, drm, keyUnavailable, http(Int)
    case safe(PlaybackDiagnostic)
    case diagnostic(stage: String, host: String, reason: String)
    var errorDescription: String? {
        switch self {
        case .safe(let value): return value.display
        case .diagnostic: return presentation(at: .unknown).display
        case .noMatch: return "未匹配"
        case .blocked: return "来源拒绝访问或要求验证（未绕过限制）"
        case .drm: return "不支持 DRM / SAMPLE-AES 或专有密钥格式"
        case .keyUnavailable: return "标准 AES-128 密钥不可用或格式无效"
        case .incomplete: return "适配未完成（不是未匹配）"
        case .tls: return "TLS 错误（未降低证书验证）"
        case .parse: return "解析失败"
        case .unsupported: return "暂不支持（媒体协议或来源主机尚未验证）"
        case .timeout: return "请求超时"
        case .unsafe: return "来源地址不在安全范围"
        case .resolver: return "来源域名暂时无法解析（未判定地址不安全，也未固定 DNS）"
        case .tooLarge: return "响应超出大小限制"
        case .cancelled: return "已取消"
        case .http(let status): return "来源 HTTP \(status)"
        }
    }
    static func classify(_ error: Error) -> OnlineFailure {
        if let e = error as? OnlineFailure { return e }
        if error is CancellationError { return .cancelled }
        let system = error as NSError
        if let value = bridgedDiagnostic(system) { return .safe(value) }
        if system.domain == NSURLErrorDomain && system.code == NSURLErrorCancelled { return .cancelled }
        if system.domain == NSURLErrorDomain && system.code == NSURLErrorTimedOut { return .timeout }
        return .safe(.system(error, stage: .unknown))
    }
}
