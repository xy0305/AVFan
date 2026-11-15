import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let locale = "avfan.settings.locale"
        static let ageConfirmed = "avfan.settings.ageConfirmed"
        static let hqCoversEnabled = "avfan.hqCoversEnabled"
    }

    @Published var locale: SiteLocale {
        didSet { UserDefaults.standard.set(locale.rawValue, forKey: Keys.locale) }
    }

    @Published var ageConfirmed: Bool {
        didSet { UserDefaults.standard.set(ageConfirmed, forKey: Keys.ageConfirmed) }
    }

    /// AVDB-style HQ cover sources (DMM / MGS official images). On by default.
    @Published var hqCoversEnabled: Bool {
        didSet { UserDefaults.standard.set(hqCoversEnabled, forKey: Keys.hqCoversEnabled) }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Keys.locale), let value = SiteLocale(rawValue: raw) {
            locale = value
        } else {
            locale = .zhCN
        }
        ageConfirmed = UserDefaults.standard.bool(forKey: Keys.ageConfirmed)
        hqCoversEnabled = UserDefaults.standard.object(forKey: Keys.hqCoversEnabled) as? Bool ?? true
    }

    var legalAgeCookie: String? {
        ageConfirmed ? "legal_age=1" : nil
    }
}
