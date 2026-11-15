import Foundation

struct NamedLink: Identifiable, Hashable, Codable {
    var name: String
    var href: String
    var kind: String?

    var id: String { href + "|" + name }
}

struct MovieCard: Identifiable, Hashable, Codable {
    var pathID: String
    var href: String
    var code: String?
    var title: String
    var coverURL: String?
    var date: String?
    var ratingText: String?
    var badges: [String]
    var canPlay: Bool

    var id: String { pathID }

    var displayCode: String { code ?? pathID }
    var displayTitle: String {
        if let code, !title.isEmpty, !title.contains(code) {
            return title
        }
        return title.isEmpty ? displayCode : title
    }
}

struct HomeSection: Identifiable, Hashable {
    var title: String
    var cards: [MovieCard]
    var moreHref: String?
    var id: String { title }
}

struct HomePage {
    var sections: [HomeSection]
    var allCards: [MovieCard] {
        var seen = Set<String>()
        var out: [MovieCard] = []
        for section in sections {
            for card in section.cards where seen.insert(card.pathID).inserted {
                out.append(card)
            }
        }
        return out
    }
}

struct MagnetItem: Identifiable, Hashable {
    var url: String
    var name: String
    var sizeText: String?
    var sizeKB: Int?
    var fileCount: Int?
    var date: String?
    var tags: [String]

    var id: String { url }

    var displayMeta: String {
        var parts: [String] = []
        if let date, !date.isEmpty { parts.append(date) }
        if let fileCount { parts.append("\(fileCount)个文件") }
        if let sizeText, !sizeText.isEmpty { parts.append(sizeText) }
        return parts.joined(separator: " · ")
    }
}

struct MovieDetail: Hashable {
    var pathID: String
    var pageURL: String
    var code: String?
    var title: String
    var coverURL: String?
    var summary: String?
    var releaseDate: String?
    var duration: String?
    var rating: Double?
    var ratingCount: Int?
    var makers: [NamedLink]
    var publishers: [NamedLink]
    var directors: [NamedLink]
    var series: [NamedLink]
    var casts: [NamedLink]
    var tags: [NamedLink]
    var magnets: [MagnetItem]

    var displayCode: String { code ?? pathID }
    var displayTitle: String { title.isEmpty ? displayCode : title }
}

struct RankingPage {
    var title: String
    var cards: [MovieCard]
    var people: [NamedLink]
}

struct BookmarkItem: Identifiable, Hashable, Codable {
    var pathID: String
    var href: String
    var code: String?
    var title: String
    var coverURL: String?
    var addedAt: Date

    var id: String { pathID }

    var asCard: MovieCard {
        MovieCard(
            pathID: pathID,
            href: href,
            code: code,
            title: title,
            coverURL: coverURL,
            date: nil,
            ratingText: nil,
            badges: [],
            canPlay: false
        )
    }
}

enum SiteLocale: String, CaseIterable, Identifiable {
    case zhCN = "zh-CN"
    case zhTW = "zh-TW"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case th = "th"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .zhCN: return "简体中文"
        case .zhTW: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .th: return "ไทย"
        }
    }
}

enum RankingKind: String, CaseIterable, Identifiable {
    case last24h = "last_24hrs"
    case last7d = "last_7days"
    case last30d = "last_30days"
    case weekCasts = "last_week_hot_casts"
    case monthCasts = "last_month_hot_casts"
    case top300 = "top_movies"
    case yearly = "top_movies_yearly"
    case fanza = "fanza_ranking"
    case mgstage = "mgs_ranking"
    case fc2Yearly = "fc2_yearly_movies"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .last24h: return "24小时热门影片"
        case .last7d: return "7日热门影片"
        case .last30d: return "30日热门影片"
        case .weekCasts: return "上周热门演员"
        case .monthCasts: return "上月热门演员"
        case .top300: return "TOP300"
        case .yearly: return "TOP300年榜"
        case .fanza: return "FANZA排行榜"
        case .mgstage: return "MGSTAGE排行榜"
        case .fc2Yearly: return "FC2年榜"
        }
    }

    var path: String {
        switch self {
        case .mgstage: return "rankings/mgs_ranking?t=summary"
        case .fc2Yearly: return "rankings/fc2_yearly_movies?year=2025"
        default: return "rankings/\(rawValue)"
        }
    }

    var isCastList: Bool {
        self == .weekCasts || self == .monthCasts
    }
}

enum CatalogShortcut: String, CaseIterable, Identifiable {
    case censored, uncensored, western, anime, fc2, watch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .censored: return "有码"
        case .uncensored: return "无码"
        case .western: return "欧美"
        case .anime: return "动漫"
        case .fc2: return "FC2"
        case .watch: return "在线观看"
        }
    }

    func path(locale: SiteLocale) -> String {
        switch self {
        case .watch:
            return "/\(locale.rawValue)/watch"
        default:
            return "/\(locale.rawValue)/tags?cts=has_magnets&t=\(rawValue)"
        }
    }
}

enum FetchSource: String {
    case urlSession
    case wkWebView
    case cache
}

enum SiteClientError: Error, LocalizedError {
    case blocked(status: Int, url: URL)
    case emptyPage(url: URL)
    case invalidURL
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .blocked(let status, _):
            return "站点返回 \(status)，已停止该直连路径"
        case .emptyPage:
            return "页面没有可解析的条目"
        case .invalidURL:
            return "无效的地址"
        case .transport(let message):
            return message
        }
    }
}
