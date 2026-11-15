import SwiftUI
import WebKit

/// Native avfan login: SwiftUI form first; the real submit happens in a
/// WKWebView that injects the typed values into the site's sign-in page.
/// Captcha is completed in that WebView. The full page is only used if
/// injection cannot find the form fields. `/sessions` is never called as an API.
struct SiteLoginView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var ageConfirmed = false
    @State private var phase: LoginPhase = .form
    @State private var statusMessage: String?
    @State private var fallbackReason: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch phase {
                case .form:
                    formContent
                case .submitting, .captcha, .fallback:
                    webContent
                case .success:
                    successContent
                }
            }
            .background(AVFanTheme.pageBackground)
            .navigationTitle(phase == .form ? "登录 AVFan" : (phase == .fallback ? "网站登录页" : "完成验证"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if phase == .captcha || phase == .fallback || phase == .submitting {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("改用网页") {
                            phase = .fallback
                            fallbackReason = "已改为完整登录页"
                        }
                    }
                }
            }
        }
        .onAppear {
            ageConfirmed = settings.ageConfirmed
        }
    }

    private var formContent: some View {
        Form {
            Section {
                TextField("邮箱或用户名", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                SecureField("密码（不少于 6 个字符）", text: $password)
                    .textContentType(.password)
            } header: {
                Text("账号")
            } footer: {
                Text("登录会打开网站的真实登录页并填入上面的内容。应用不会自行向 /sessions 发请求。")
                    .font(.caption)
            }

            Section("年龄确认") {
                Toggle("已确认已达法定成年年龄", isOn: $ageConfirmed)
                Text("确认后会写入与网页相同的 legal_age cookie，并记在本机。115 登录不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("登录") { startLogin() }
                    .disabled(!canSubmit)
                    .font(.headline)
            }
        }
        .scrollContentBackground(.hidden)
        .liquidGlassList()
    }

    private var webContent: some View {
        VStack(spacing: 0) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(AVFanTheme.pageBackground)
            }
            SiteLoginWebView(
                url: session.signInURL(locale: settings.locale),
                username: username,
                password: password,
                revealImmediately: phase == .fallback,
                onEvent: handleWebEvent
            )
            .opacity(phase == .submitting ? 0 : 1)
            if phase == .submitting {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在打开网站登录页…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var successContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("已登录")
                .font(AVFanTheme.titleFont)
            if !session.displayName.isEmpty {
                Text(session.displayName)
                    .foregroundStyle(.secondary)
            }
            Button("完成") { dismiss() }
                .glassChromeButton(prominent: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlassPage()
    }

    private var canSubmit: Bool {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return ageConfirmed && !name.isEmpty && password.count >= 6
    }

    private func startLogin() {
        guard canSubmit else {
            statusMessage = "请先填写账号、密码，并确认已成年。"
            return
        }
        settings.ageConfirmed = true
        statusMessage = "正在打开网站登录页并填入账号…"
        phase = .submitting
        Task { await CookieBridge.applyLegalAge(true) }
    }

    private func handleWebEvent(_ event: SiteLoginWebEvent) {
        switch event {
        case .injectionFailed:
            fallbackReason = "无法在页面上找到登录表单，已改为完整网页。"
            statusMessage = fallbackReason
            phase = .fallback
        case .needsCaptcha:
            statusMessage = "请在下方输入图片验证码，然后点页面上的「登录」。"
            phase = .captcha
        case .filled:
            statusMessage = "账号已填入。如需验证码，请在页面上完成后再登录。"
            phase = .captcha
        case .signedIn(let name, let signOut):
            session.markSignedIn(displayName: name, signOutURL: signOut)
            Task {
                await CookieBridge.exportWebKitToShared()
                await SiteClient.shared.clearCache()
            }
            statusMessage = nil
            phase = .success
        case .stillOnLogin(let message):
            if phase != .fallback {
                phase = .captcha
            }
            if let message, !message.isEmpty {
                statusMessage = message
            }
        case .pageError(let message):
            statusMessage = message
            if phase == .submitting { phase = .fallback }
        }
    }
}

private enum LoginPhase {
    case form, submitting, captcha, fallback, success
}

enum SiteLoginWebEvent {
    case injectionFailed
    case needsCaptcha
    case filled
    case signedIn(name: String?, signOut: String?)
    case stillOnLogin(String?)
    case pageError(String)
}

private struct SiteLoginWebView: UIViewRepresentable {
    let url: URL
    let username: String
    let password: String
    let revealImmediately: Bool
    let onEvent: (SiteLoginWebEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(username: username, password: password, onEvent: onEvent)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = SiteClient.mobileSafariUA
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        var request = URLRequest(url: url)
        request.setValue(SiteClient.mobileSafariUA, forHTTPHeaderField: "User-Agent")
        view.load(request)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.username = username
        context.coordinator.password = password
        context.coordinator.onEvent = onEvent
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var username: String
        var password: String
        var onEvent: (SiteLoginWebEvent) -> Void
        weak var webView: WKWebView?
        private var injected = false
        private var finishedSignIn = false

        init(username: String, password: String, onEvent: @escaping (SiteLoginWebEvent) -> Void) {
            self.username = username
            self.password = password
            self.onEvent = onEvent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                await CookieBridge.exportWebKitToShared()
                await inspect(webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onEvent(.pageError(error.localizedDescription))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onEvent(.pageError(error.localizedDescription))
        }

        @MainActor
        private func inspect(_ webView: WKWebView) async {
            let url = webView.url
            let html = (try? await webView.evaluateJavaScript("document.documentElement.outerHTML")) as? String ?? ""
            if HTMLParser.isSignedIn(html: html) || isSignedInURL(url) {
                guard !finishedSignIn else { return }
                finishedSignIn = true
                onEvent(.signedIn(name: HTMLParser.signedInDisplayName(in: html),
                                  signOut: HTMLParser.signOutURL(in: html)))
                return
            }

            let onLogin = url?.path.contains("sign_in") == true || html.contains("session_email_or_username")
            if onLogin, !injected {
                injected = true
                let result = await inject(into: webView)
                switch result {
                case "missing-fields":
                    onEvent(.injectionFailed)
                case "captcha":
                    onEvent(.needsCaptcha)
                case "filled":
                    onEvent(.filled)
                default:
                    onEvent(.injectionFailed)
                }
                return
            }

            if onLogin {
                let message = HTMLParser.stripTags(
                    HTMLParser.firstMatch("class=\"[^\"]*(?:alert|error|flash)[^\"]*\"[^>]*>([\\s\\S]{0,200})</", in: html) ?? ""
                )
                onEvent(.stillOnLogin(message.isEmpty ? nil : message))
            }
        }

        private func isSignedInURL(_ url: URL?) -> Bool {
            guard let url else { return false }
            let path = url.path
            if path.contains("sign_in") || path.contains("sign_up") || path.contains("sessions") { return false }
            let homes = ["/"] + SiteLocale.allCases.map { "/" + $0.rawValue }
            return homes.contains(path) || path.hasSuffix("/account") || path.contains("/profile")
        }

        @MainActor
        private func inject(into webView: WKWebView) async -> String {
            let payload: [String: String] = ["user": username, "pass": password]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else {
                return "missing-fields"
            }
            let script = """
            (function() {
              var p = \(json);
              var user = document.getElementById('session_email_or_username')
                || document.querySelector('input[name="session[email_or_username]"]')
                || document.querySelector('input[autocomplete="username"]')
                || document.querySelector('input[type="email"]');
              var pass = document.getElementById('session_password')
                || document.querySelector('input[name="session[password]"]')
                || document.querySelector('input[type="password"]');
              if (!user || !pass) return 'missing-fields';
              function fill(el, val) {
                el.focus();
                el.value = val;
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              }
              fill(user, p.user);
              fill(pass, p.pass);
              var captcha = document.getElementById('input_rucaptcha')
                || document.querySelector('input[name="_rucaptcha"]')
                || document.querySelector('img.rucaptcha-image')
                || document.querySelector('.cf-turnstile')
                || document.querySelector('iframe[src*="captcha"]');
              if (captcha) {
                try { captcha.scrollIntoView({ block: 'center' }); } catch (e) {}
                return 'captcha';
              }
              return 'filled';
            })();
            """
            do {
                let result = try await webView.evaluateJavaScript(script)
                return (result as? String) ?? "missing-fields"
            } catch {
                return "missing-fields"
            }
        }
    }
}
