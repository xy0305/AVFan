import SwiftUI
import WebKit

struct InAppWebView: View {
    let url: URL
    var title: String = "网页"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebViewRepresentable(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
        }
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = SiteClient.mobileSafariUA
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// A bare <video> element in a WebView, for trailer playback: the
/// WebKit media stack (with the app's site session cookies) plays
/// sources the native players cannot, with the video element's own
/// controls and no surrounding page.
struct TrailerVideoWebView: UIViewRepresentable {
    let url: URL
    let poster: String?
    let baseURL: URL?
    /// Called ONLY on a real media error (build 25: build 24's
    /// 15-second readyState timeout false-fired on slow loads and
    /// the overlay then claimed login was the problem while the
    /// owner was already logged in).
    var onPlaybackError: (() -> Void)? = nil
    /// Called when the media can actually play; clears a failure.
    var onPlaybackReady: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onPlaybackError: onPlaybackError, onPlaybackReady: onPlaybackReady)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "trailer")
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = SiteClient.mobileSafariUA
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        let posterAttr = poster.map { " poster=\"\(escape($0))\"" } ?? ""
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>html,body{margin:0;padding:0;height:100%;background:#000}video{width:100%;height:100%;object-fit:contain;display:block}</style>
        </head><body><video src="\(escape(url.absoluteString))"\(posterAttr) controls autoplay playsinline></video>
        <script>
        var v = document.querySelector('video');
        function post(m){ try { window.webkit.messageHandlers.trailer.postMessage(m); } catch(e) {} }
        function fail(){ post('error'); }
        function ok(){ post('ok'); }
        v.addEventListener('error', fail, true);
        v.addEventListener('canplay', ok);
        v.addEventListener('playing', ok);
        setTimeout(function(){ if (v.error || (v.readyState === 0 && v.networkState === 3)) fail(); }, 30000);
        </script>
        </body></html>
        """
        view.loadHTMLString(html, baseURL: baseURL)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onPlaybackError: (() -> Void)?
        let onPlaybackReady: (() -> Void)?
        private var errorReported = false

        init(onPlaybackError: (() -> Void)?, onPlaybackReady: (() -> Void)?) {
            self.onPlaybackError = onPlaybackError
            self.onPlaybackReady = onPlaybackReady
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body as? String
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if body == "ok" {
                    self.errorReported = false
                    self.onPlaybackReady?()
                } else if !self.errorReported {
                    self.errorReported = true
                    self.onPlaybackError?()
                }
            }
        }
    }
}
