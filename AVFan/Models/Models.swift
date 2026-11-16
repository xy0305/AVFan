import Foundation

struct NamedLink: Identifiable, Hashable, Codable {
    var name: String
    var href: String
    var kind: String?
    var imageURL: String? = nil

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
    /// The homepage's main movie list (最新磁链): rendered as the full
    /// auto-loading, filterable grid instead of a capped rail (build 13).
    var isMainList: Bool = false
    var id: String { title }
}

struct HomePage {
    var sections: [HomeSection]
    /// The main list's cards (the non-featured remainder of the page).
    var listCards: [MovieCard] = []
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

struct WatchStream: Identifiable, Hashable {
    var url: String
    var label: String
    var id: String { url }
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
    var watchStreams: [WatchStream] = []
    /// Preview trailer declared by the detail page itself (JSON-LD
    /// contentUrl / DMM preview mp4). Distinct from watchStreams: the
    /// site shows it as the first cell of the media strip.
    var trailerURL: String? = nil
    /// Sample stills shown on the detail page (DMM jp-N images and
    /// avfan-hosted samples), in page order, cover excluded.
    var previewImages: [String] = []
    /// Account-library wiring parsed from the detail page's own markup
    /// （想看/看过/保存至清单）; nil when the page carries no such block.
    var library: LibraryPageState? = nil
    /// Lazy fragment endpoints declared by the detail page's tabs
    /// (build 24): the comments tab loads data-comments-url, the
    /// related-lists tab loads #related-lists' data-url.
    var commentsURL: String? = nil
    var relatedListsURL: String? = nil
    var commentsCount: Int? = nil
    /// Cards under the page's 她/他还出演过 and 相关作品 headings
    /// (six each on the site, no "more" link).
    var alsoStarred: [MovieCard] = []
    var relatedWorks: [MovieCard] = []

    var displayCode: String { code ?? pathID }
    var displayTitle: String { title.isEmpty ? displayCode : title }
}

struct RankingPage {
    var title: String
    var cards: [MovieCard]
    var people: [NamedLink]
}

/// One row of the site's 资讯 (news) list: cover, category label, title,
/// author, date, comment count (build 6).
struct NewsItem: Identifiable, Hashable {
    var pathID: String
    var href: String
    var title: String
    var category: String?
    var author: String?
    var date: String?
    var commentCount: Int?
    var coverURL: String?

    var id: String { pathID }
}

enum NewsBlock: Hashable {
    case text(String)
    case image(String)
}

struct NewsArticle {
    var title: String
    var category: String?
    var author: String?
    var date: String?
    var blocks: [NewsBlock] = []
    var relatedMovies: [MovieCard] = []
    var relatedCasts: [NamedLink] = []
    var relatedNews: [NewsItem] = []
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

/// One entry on the site's cast index pages (build 11): avatar + name +
/// an optional works-count line, linking to that cast's movie list.
struct CastCard: Identifiable, Hashable {
    var name: String
    var href: String
    var avatarURL: String?
    var countText: String?

    var id: String { href }
    /// The 8-char cast id inside the href, used as the catalog path key.
    var pathID: String {
        href.split(separator: "/").last.map(String.init) ?? href
    }
}

/// The site's own list filter/sort panel, parsed from the page's form
/// (build 11). Groups are keyed by the input `name`; options carry the
/// input `value`, its visible label and whether the page shipped it
/// selected. Nothing here is guessed: no form in the HTML, no filter UI.
struct ListFilterOption: Identifiable, Hashable {
    var value: String
    var label: String
    var selected: Bool
    var id: String { value + "|" + label }
}

struct ListFilterGroup: Identifiable, Hashable {
    var name: String
    var isRadio: Bool
    var title: String
    var options: [ListFilterOption]
    var id: String { name }

    /// The site's 布局 group (1列 / 2列 …): a display option, applied
    /// locally to the grid as well as sent with the form.
    var isLayoutGroup: Bool {
        !options.isEmpty && options.allSatisfy {
            $0.label.replacingOccurrences(of: " ", with: "")
                .range(of: "^\\d+列$", options: .regularExpression) != nil
        }
    }
}

struct ListFilterForm: Hashable {
    var groups: [ListFilterGroup]
    /// Set when this form is the site's movie-toolbar component
    /// (build 15): applying it follows the toolbar controller's own
    /// URL rules instead of plain form parameters.
    var toolbar: ToolbarMeta? = nil

    struct ToolbarMeta: Hashable {
        var basePath: String
        var categoryPaths: [String]
        var defaultType: String
        var defaultFilter: String
        var defaultSort: String
    }

    /// The selections the page itself shipped (its checked inputs).
    var defaultSelections: [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: groups.map { group in
            (group.name, Set(group.options.filter(\.selected).map(\.value)))
        })
    }

    /// Column count chosen in the 布局 group, when the form has one and
    /// an option is selected; nil keeps the grid's adaptive default.
    func layoutColumns(selections: [String: Set<String>]) -> Int? {
        let layouts = groups.filter(\.isLayoutGroup)
        let ordered = layouts.filter { $0.name == "movie-toolbar-grid-mobile" }
            + layouts.filter { $0.name != "movie-toolbar-grid-mobile" }
        for group in ordered {
            guard let value = selections[group.name]?.first,
                  let option = group.options.first(where: { $0.value == value }) else { continue }
            let digits = option.label.filter(\.isNumber)
            if let count = Int(digits), count >= 1 { return count }
        }
        return nil
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


/// The state of a movie in the user's avfan library.
enum ReviewStatus: String, Hashable {
    case none
    case watchlist
    case watched
}

/// Everything the detail page itself declares about the account
/// library actions （想看 / 看过 / 保存至清单）: the CSRF token, the
/// endpoints carried in the buttons' data attributes, and the state
/// the page rendered. All values come from the page's own markup —
/// nothing is guessed. URLs are site-relative paths as printed.
struct LibraryPageState: Hashable {
    var csrfToken: String?
    var reviewStatus: ReviewStatus = .none
    /// POST target + status value for marking 想看.
    var watchlistURL: String?
    var watchlistActionType: String = "watchlist"
    /// POST target + status value for marking 看过.
    var watchedURL: String?
    var watchedActionType: String = "watched"
    /// DELETE target for removing the review, when one exists.
    var removeURL: String?
    /// GET endpoint returning the save-to-list modal's list rows.
    var listsURL: String?
    /// POST target toggling a list's membership for this movie.
    var changeURL: String?
    /// POST target + mode for creating a new list.
    var createListURL: String?
    var createListMode: String = "new"
}

/// One row of the site's save-to-list picker.
struct SyncListOption: Identifiable, Hashable {
    var listID: String
    var name: String
    var checked: Bool

    var id: String { listID }
}


/// A cast's profile page, parsed from the page's own markup: header
/// identity, the model controller's follow/collect wiring, the
/// lazy-loaded details fragment URL, and the short-review wiring.
struct CastProfile: Hashable {
    var name: String = ""
    var reading: String?
    var romaji: String?
    var avatarURL: String?
    var socialLinks: [NamedLink] = []
    var worksCount: Int?
    var csrfToken: String?
    // Follow / collect (the site's `model` controller).
    var followURL: String?
    var unfollowURL: String?
    var collectURL: String?
    var uncollectURL: String?
    var modelName: String?
    var modelID: String?
    var isFollowing: Bool = false
    var isCollected: Bool = false
    /// Lazy fragment with the 详细资料 rows.
    var detailsURL: String?
    /// Short reviews （短评）.
    var reviewCreateURL: String?
    var reviewCastSqid: String?
    var reviewListURL: String?
    var ownReviewID: String?
    var ownReviewDestroyURL: String?
    /// Whether this page was served in the signed-in state. Guest
    /// pages render the follow/collect buttons as login triggers
    /// without the model wiring, so the view needs to know.
    var signedIn: Bool = false
}

/// One movie comment from the detail page's comments fragment:
/// author, body, and the site's short date (MM-DD, no year).
struct MovieComment: Identifiable, Hashable {
    var author: String
    var body: String
    var dateText: String?

    var id: String { author + "|" + body + "|" + (dateText ?? "") }
}

/// One row of the detail page's related-lists fragment.
struct RelatedListRow: Identifiable, Hashable {
    var name: String
    var href: String
    var moviesCount: Int?
    var viewsCount: Int?

    var id: String { href }
}

/// One short review of a cast, parsed from the list fragment.
struct CastReviewItem: Identifiable, Hashable {
    var author: String
    var body: String
    var meta: String?
    var likeURL: String?

    var id: String { author + "|" + body + "|" + (meta ?? "") }
}
