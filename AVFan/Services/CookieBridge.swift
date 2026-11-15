import Foundation
import WebKit

/// Shares avfan session cookies between WKWebView (default data store)
/// and URLSession (`HTTPCookieStorage.shared`) so a native login session
/// is used by later page fetches. 115 credentials are never stored here.
@MainActor
enum CookieBridge {
    static let siteDomain = "avfan.com"

    static func syncOnLaunch() async {
        await importSharedIntoWebKit()
        await exportWebKitToShared()
        await applyLegalAge(AppSettings.shared.ageConfirmed)
    }

    static func exportWebKitToShared() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let storage = HTTPCookieStorage.shared
        for cookie in cookies where isSiteCookie(cookie) {
            storage.setCookie(cookie)
        }
    }

    static func importSharedIntoWebKit() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let existing = HTTPCookieStorage.shared.cookies ?? []
        for cookie in existing where isSiteCookie(cookie) {
            await store.setCookie(cookie)
        }
    }

    static func applyLegalAge(_ confirmed: Bool) async {
        if confirmed {
            await setCookie(name: "legal_age", value: "1")
        } else {
            await deleteCookie(named: "legal_age")
        }
    }

    static func setCookie(name: String, value: String, path: String = "/") async {
        guard let cookie = HTTPCookie(properties: [
            .domain: siteDomain,
            .path: path,
            .name: name,
            .value: value,
            .secure: true,
        ]) else { return }
        HTTPCookieStorage.shared.setCookie(cookie)
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
    }

    static func deleteCookie(named name: String) async {
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] where isSiteCookie(cookie) && cookie.name == name {
            storage.deleteCookie(cookie)
        }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await store.allCookies()
        for cookie in cookies where isSiteCookie(cookie) && cookie.name == name {
            await store.deleteCookie(cookie)
        }
    }

    /// Clears only avfan site cookies. Does not touch the 115 Keychain.
    static func clearSiteCookies() async {
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] where isSiteCookie(cookie) {
            storage.deleteCookie(cookie)
        }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await store.allCookies()
        for cookie in cookies where isSiteCookie(cookie) {
            await store.deleteCookie(cookie)
        }
    }

    static func isSiteCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased()
        return domain == siteDomain || domain.hasSuffix("." + siteDomain) || domain == "." + siteDomain
    }
}
