import Foundation
import WebKit

/// Loads a FANZA official list page in a real WKWebView and returns
/// the rendered HTML. This is a dedicated session: it does not go
/// through SiteClient or CookieBridge (those are bound to avfan.com
/// cookies). FANZA/DMM age-check cookies stay in the default
/// WKWebsiteDataStore so later launches can skip the gate.
@MainActor
final class FanzaWebFetcher: NSObject, WKNavigationDelegate {
    static let shared = FanzaWebFetcher()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Snapshot, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var ageHandled = false
    private var targetURL: URL?

    struct Snapshot {
        var html: String
        var datesByCID: [String: Date]
    }

    enum FetchError: LocalizedError {
        case timeout
        case empty
        case cancelled

        var errorDescription: String? {
            switch self {
            case .timeout: return "FANZA 页面加载超时"
            case .empty: return "FANZA 列表页没有解析到作品"
            case .cancelled: return "已被新的页面请求取消"
            }
        }
    }

    func snapshot(for url: URL, timeout: TimeInterval = 25) async throws -> Snapshot {
        await installAgeCookie()
        let webView = preparedWebView()
        targetURL = url
        ageHandled = false
        return try await withCheckedThrowingContinuation { continuation in
            if let previous = self.continuation {
                previous.resume(throwing: FetchError.cancelled)
            }
            self.continuation = continuation
            timeoutTask?.cancel()
            pollTask?.cancel()
            timeoutTask = Task { [weak self] in
                let nanos = UInt64(max(5, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                await MainActor.run { self?.finishOrFail() }
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            request.setValue(SiteClient.mobileSafariUA, forHTTPHeaderField: "User-Agent")
            webView.load(request)
        }
    }

    // MARK: - WebView

    private func preparedWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let hook = WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(hook)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        view.customUserAgent = SiteClient.mobileSafariUA
        view.navigationDelegate = self
        self.webView = view
        return view
    }

    /// The standard FANZA/DMM age cookie. Set through the cookie
    /// store (it is HttpOnly on the official confirm response) so
    /// later loads of video.dmm.co.jp skip the gate.
    private func installAgeCookie() async {
        let expires = Date().addingTimeInterval(30 * 24 * 60 * 60)
        let domains = ["dmm.co.jp", "video.dmm.co.jp", "www.dmm.co.jp"]
        for domain in domains {
            guard let cookie = HTTPCookie(properties: [
                .domain: domain,
                .path: "/",
                .name: "age_check_done",
                .value: "1",
                .secure: true,
                .expires: expires,
            ]) else { continue }
            await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.startPolling()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.fail(error)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.fail(error)
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
                let ready = await self.inspectAndMaybeAcceptAgeGate()
                if ready { return }
            }
        }
    }

    private func inspectAndMaybeAcceptAgeGate() async -> Bool {
        guard continuation != nil, let webView else { return true }
        let currentURL = webView.url
        let html: String
        do {
            let result = try await webView.evaluateJavaScript(Self.htmlScript)
            html = result as? String ?? ""
        } catch {
            return false
        }
        if isAgeGate(url: currentURL, html: html) {
            await handleAgeGate(currentURL: currentURL)
            return false
        }
        if hasProductCards(html) {
            await finish(html: html, webView: webView)
            return true
        }
        return false
    }

    private func isAgeGate(url: URL?, html: String) -> Bool {
        if let path = url?.path.lowercased(), path.contains("age_check") { return true }
        let lower = html.lowercased()
        if lower.contains("年齢認証") || lower.contains("age_check") { return true }
        if lower.contains("under the age of 18") && !hasProductCards(html) { return true }
        return false
    }

    private func hasProductCards(_ html: String) -> Bool {
        html.contains("data-e2eid=\"content-card\"")
            || html.contains("data-e2eid='content-card'")
            || html.range(of: #"/av/content/\?id="#, options: .regularExpression) != nil
    }

    private func handleAgeGate(currentURL: URL?) async {
        if ageHandled { return }
        ageHandled = true
        await installAgeCookie()
        guard let webView else { return }
        let clicked = (try? await webView.evaluateJavaScript(Self.clickConfirmScript) as? Bool) ?? false
        if clicked { return }
        let resume = targetURL ?? currentURL ?? FanzaTodayParser.officialListURL
        let encoded = resume.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resume.absoluteString
        if let confirm = URL(string: "https://www.dmm.co.jp/age_check/=/declared=yes/?rurl=\(encoded)") {
            var request = URLRequest(url: confirm)
            request.setValue(SiteClient.mobileSafariUA, forHTTPHeaderField: "User-Agent")
            webView.load(request)
        }
    }

    private func finish(html: String, webView: WKWebView) async {
        let dates = await collectDates(from: webView)
        timeoutTask?.cancel()
        timeoutTask = nil
        pollTask?.cancel()
        pollTask = nil
        continuation?.resume(returning: Snapshot(html: html, datesByCID: dates))
        continuation = nil
    }

    private func finishOrFail() {
        Task { @MainActor in
            guard let webView, continuation != nil else { return }
            let html = (try? await webView.evaluateJavaScript(Self.htmlScript) as? String) ?? ""
            if hasProductCards(html) {
                await finish(html: html, webView: webView)
            } else {
                fail(isAgeGate(url: webView.url, html: html) ? FetchError.timeout : FetchError.empty)
            }
        }
    }

    private func fail(_ error: Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        pollTask?.cancel()
        pollTask = nil
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func collectDates(from webView: WKWebView) async -> [String: Date] {
        var merged: [String: Date] = [:]
        if let raw = try? await webView.evaluateJavaScript(Self.datesScript) as? [String: String] {
            for (cid, value) in raw {
                if let date = FanzaTodayParser.parseDate(value) {
                    merged[cid.lowercased()] = date
                }
            }
        }
        if let payloads = try? await webView.evaluateJavaScript("window.__avfanFanzaCapture || []") as? [String] {
            for payload in payloads {
                for (cid, date) in dates(fromJSON: payload) {
                    merged[cid] = date
                }
            }
        }
        return merged
    }

    /// Walk captured GraphQL JSON for `id` + `deliveryStartDate` /
    /// `makerReleasedAt` pairs. Kept conservative: only records a
    /// date when the same object also has a FANZA content id.
    private func dates(fromJSON text: String) -> [String: Date] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var out: [String: Date] = [:]
        walkJSON(root, into: &out)
        return out
    }

    private func walkJSON(_ value: Any, into out: inout [String: Date]) {
        if let dict = value as? [String: Any] {
            let cid = ((dict["id"] as? String) ?? "").lowercased()
            if !cid.isEmpty, cid.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil {
                let raw = (dict["deliveryStartDate"] as? String)
                    ?? (dict["makerReleasedAt"] as? String)
                    ?? (dict["deliveryStartAt"] as? String)
                if let raw, let date = FanzaTodayParser.parseDate(raw) {
                    out[cid] = date
                }
            }
            for nested in dict.values { walkJSON(nested, into: &out) }
        } else if let array = value as? [Any] {
            for nested in array { walkJSON(nested, into: &out) }
        }
    }

    private static let htmlScript = "document.documentElement ? document.documentElement.outerHTML : (document.body ? document.body.outerHTML : '')"

    /// Hook fetch/XHR at document start so list GraphQL payloads
    /// (delivery dates that the card may hide once a title is out)
    /// can be merged into the parser.
    private static let captureScript = """
    (function(){
      if (window.__avfanFanzaHooked) return;
      window.__avfanFanzaHooked = true;
      window.__avfanFanzaCapture = [];
      function keep(url, text){
        try {
          if (!text) return;
          if ((url && (url.indexOf('graphql') !== -1 || url.indexOf('api.video.dmm') !== -1))
              || text.indexOf('deliveryStartDate') !== -1
              || text.indexOf('packageImage') !== -1) {
            if (window.__avfanFanzaCapture.length < 12) window.__avfanFanzaCapture.push(text);
          }
        } catch (e) {}
      }
      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function(){
          var args = arguments;
          var url = (typeof args[0] === 'string') ? args[0] : (args[0] && args[0].url) || '';
          return origFetch.apply(this, args).then(function(res){
            try { res.clone().text().then(function(t){ keep(url, t); }); } catch (e) {}
            return res;
          });
        };
      }
      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url){
        this.__avfanUrl = url;
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function(){
        var xhr = this;
        xhr.addEventListener('load', function(){
          try { keep(xhr.__avfanUrl || '', xhr.responseText); } catch (e) {}
        });
        return origSend.apply(this, arguments);
      };
    })();
    """

    /// Read delivery/release dates off the rendered content-card
    /// React fiber when the visible 配信日 row is hidden.
    private static let datesScript = """
    (function(){
      var out = {};
      function fiber(el){
        if (!el) return null;
        var keys = Object.keys(el);
        for (var i = 0; i < keys.length; i++){
          if (keys[i].indexOf('__reactFiber') === 0 || keys[i].indexOf('__reactInternalInstance') === 0) return el[keys[i]];
        }
        return null;
      }
      function pick(node){
        var steps = 0;
        while (node && steps++ < 50){
          var p = node.memoizedProps || node.pendingProps;
          if (p){
            var id = p.id || p.contentId;
            var date = p.deliveryStartAt || p.deliveryStartDate || p.releaseAt || p.makerReleasedAt;
            if (id && date){
              var value = (date instanceof Date) ? date.toISOString() : String(date);
              out[String(id).toLowerCase()] = value;
              return;
            }
          }
          node = node.return;
        }
      }
      var cards = document.querySelectorAll('[data-e2eid="content-card"]');
      for (var i = 0; i < cards.length; i++) pick(fiber(cards[i]));
      return out;
    })()
    """

    private static let clickConfirmScript = """
    (function(){
      function click(el){ if (!el) return false; el.click(); return true; }
      var declared = document.querySelector('a[href*="declared=yes"], button[href*="declared=yes"], a[href*="age_check"]');
      if (click(declared)) return true;
      var nodes = document.querySelectorAll('a, button');
      for (var i = 0; i < nodes.length; i++){
        var t = (nodes[i].innerText || nodes[i].textContent || '').replace(/\\s+/g, '');
        if (t.indexOf('はい') !== -1 || t.indexOf('18歳') !== -1 || t.indexOf('18才') !== -1 || t.indexOf('進入') !== -1 || t.indexOf('同意') !== -1){
          if (click(nodes[i])) return true;
        }
      }
      return false;
    })()
    """
}
