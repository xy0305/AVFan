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
    /// Called when the media element reports an error or never
    /// becomes playable (build 24: the owner hit the bare WebKit
    /// error glyph with no explanation).
    var onPlaybackError: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onPlaybackError: onPlaybackError)
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
        function fail(){ try { window.webkit.messageHandlers.trailer.postMessage('error'); } catch(e) {} }
        v.addEventListener('error', fail, true);
        setTimeout(function(){ if (v.readyState < 2) fail(); }, 15000);
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
        private var reported = false

        init(onPlaybackError: (() -> Void)?) {
            self.onPlaybackError = onPlaybackError
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !reported else { return }
            reported = true
            DispatchQueue.main.async { [weak self] in self?.onPlaybackError?() }
        }
    }
}
