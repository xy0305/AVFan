import Foundation
import Combine
import WebKit

/// avfan website session (native form + WKWebView submit).
/// Never mixed with the 115 Keychain accounts.
@MainActor
final class SiteSession: ObservableObject {
    static let shared = SiteSession()

    private enum Keys {
        static let signedIn = "avfan.session.signedIn"
        static let displayName = "avfan.session.displayName"
        static let signOutURL = "avfan.session.signOutURL"
    }

    @Published var isSignedIn: Bool {
        didSet { UserDefaults.standard.set(isSignedIn, forKey: Keys.signedIn) }
    }

    @Published var displayName: String {
        didSet { UserDefaults.standard.set(displayName, forKey: Keys.displayName) }
    }

    @Published var signOutURL: String? {
        didSet { UserDefaults.standard.set(signOutURL, forKey: Keys.signOutURL) }
    }

    private init() {
        isSignedIn = UserDefaults.standard.bool(forKey: Keys.signedIn)
        displayName = UserDefaults.standard.string(forKey: Keys.displayName) ?? ""
        signOutURL = UserDefaults.standard.string(forKey: Keys.signOutURL)
    }

    func signInURL(locale: SiteLocale) -> URL {
        URL(string: "https://avfan.com/\(locale.rawValue)/sign_in")!
    }

    func markSignedIn(displayName: String?, signOutURL: String?) {
        isSignedIn = true
        if let displayName, !displayName.isEmpty { self.displayName = displayName }
        if let signOutURL, !signOutURL.isEmpty { self.signOutURL = signOutURL }
    }

    func markSignedOut() {
        isSignedIn = false
        displayName = ""
        signOutURL = nil
    }

    func applyPageSignals(html: String, url: URL?) {
        if let found = HTMLParser.signOutURL(in: html) {
            signOutURL = found
        }
        if HTMLParser.isSignedIn(html: html) {
            isSignedIn = true
            if let name = HTMLParser.signedInDisplayName(in: html), !name.isEmpty {
                displayName = name
            }
        } else if let url, url.path.contains("sign_in") || url.path.contains("sign_up") {
            // Stay on the login page does not by itself log the user out.
        } else if html.contains("href=\"") && HTMLParser.containsSignInLink(html) && !HTMLParser.isSignedIn(html: html) {
            if isSignedIn && signOutURL == nil {
                // Public header still offers 登录 — treat as signed out.
                isSignedIn = false
                displayName = ""
            }
        }
    }

    func signOut(locale: SiteLocale) async {
        await CookieBridge.exportWebKitToShared()
        if let raw = signOutURL, let url = URL(string: HTMLParser.absoluteURL(raw, locale: locale)) {
            _ = try? await WebViewFetcher.shared.html(for: url, ageCookie: AppSettings.shared.legalAgeCookie)
        }
        await CookieBridge.clearSiteCookies()
        await CookieBridge.applyLegalAge(AppSettings.shared.ageConfirmed)
        markSignedOut()
        await SiteClient.shared.clearCache()
    }
}
