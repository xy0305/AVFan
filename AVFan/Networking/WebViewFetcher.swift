import Foundation
import WebKit

/// Loads a public page in a real WKWebView session and returns the rendered HTML.
/// Used only when URLSession is blocked or the raw HTML has no catalog items.
@MainActor
final class WebViewFetcher: NSObject, WKNavigationDelegate {
    static let shared = WebViewFetcher()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    func html(for url: URL, ageCookie: String?, referer: URL? = nil) async throws -> String {
        if let ageCookie {
            await injectCookie(ageCookie, for: url)
        }
        let webView = preparedWebView()
        return try await withCheckedThrowingContinuation { continuation in
            if let previous = self.continuation {
                previous.resume(throwing: SiteClientError.transport("已被新的页面请求取消"))
            }
            self.continuation = continuation
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await MainActor.run {
                    self?.fail(SiteClientError.transport("网页加载超时"))
                }
            }
            var request = URLRequest(url: url)
            request.setValue(SiteClient.mobileSafariUA, forHTTPHeaderField: "User-Agent")
            if let referer {
                request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            }
            webView.load(request)
        }
    }

    private func preparedWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        view.customUserAgent = SiteClient.mobileSafariUA
        view.navigationDelegate = self
        self.webView = view
        return view
    }

    private func injectCookie(_ cookieHeader: String, for url: URL) async {
        let parts = cookieHeader.split(separator: ";", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, let eq = first.firstIndex(of: "=") else { return }
        let name = String(first[..<eq])
        let value = String(first[first.index(after: eq)...])
        guard let cookie = HTTPCookie(properties: [
            .domain: url.host ?? "avfan.com",
            .path: "/",
            .name: name,
            .value: value,
            .secure: true,
        ]) else { return }
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Give JS-rendered lists a brief moment, then snapshot HTML.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let script = "document.documentElement ? document.documentElement.outerHTML : document.body.outerHTML"
            do {
                let result = try await webView.evaluateJavaScript(script)
                let html = result as? String ?? ""
                finish(html)
            } catch {
                fail(error)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            fail(error)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            fail(error)
        }
    }

    private func finish(_ html: String) {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(returning: html)
        continuation = nil
    }

    private func fail(_ error: Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
