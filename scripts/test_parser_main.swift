import Foundation

func fixture(_ name: String) throws -> String {
    let candidates = [
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Fixtures/\(name)"),
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)"),
    ]
    for url in candidates where FileManager.default.isReadableFile(atPath: url.path) {
        return try String(contentsOf: url, encoding: .utf8)
    }
    throw NSError(domain: "AVFanParserTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
enum ParserTests {
    static func main() {
        do {
            try run()
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        let homeHTML = try fixture("home.html")
        let home = HTMLParser.home(from: homeHTML)
        expect(!home.sections.isEmpty, "home should have sections")
        expect(home.allCards.count >= 20, "home should parse many cards, got \(home.allCards.count)")
        expect(home.allCards.contains { $0.pathID == "AiESpzU0" }, "featured NHDTC-266 path")
        expect(home.allCards.contains { $0.code == "NHDTC-266" }, "featured code NHDTC-266")
        expect(home.allCards.contains { $0.code == "IPZZ-936" }, "home includes IPZZ-936")
        expect(home.allCards.contains { $0.coverURL?.contains("c1.avfan.com") == true }, "covers on c1.avfan.com")
        expect(home.sections.contains { $0.title.contains("在线观看") || !$0.cards.isEmpty }, "watch or catalog section")
        // Build 13: the homepage's main list is marked and exposed
        // separately from the rails (it auto-loads and filters).
        expect(home.sections.contains { $0.isMainList }, "home marks the main list section")
        expect(!home.listCards.isEmpty, "home listCards populated, got \(home.listCards.count)")
        expect(home.listCards.allSatisfy { lc in home.allCards.contains { $0.pathID == lc.pathID } },
               "listCards are a subset of allCards")

        let movieHTML = try fixture("movie-ipzz-936.html")
        let movieURL = URL(string: "https://avfan.com/zh-CN/movies/s6bNHCTN")
        let detail = HTMLParser.movieDetail(from: movieHTML, url: movieURL)
        expect(detail.pathID == "s6bNHCTN", "detail path id, got \(detail.pathID)")
        expect(detail.code == "IPZZ-936", "detail 番号, got \(detail.code ?? "nil")")
        expect(detail.title.contains("篠崎"), "detail title")
        expect(detail.coverURL?.contains("c1.avfan.com") == true, "detail cover, got \(detail.coverURL ?? "nil")")
        expect(detail.coverURL?.contains(".mp4") != true, "detail cover must not be a preview video")
        // A stray high-score image from another title (promo / affiliate
        // art anywhere in the page) must not override the declared cover.
        let poisoned = movieHTML + "<img src=\"https://pics.dmm.co.jp/digital/video/zzzz99999/zzzz99999ps.jpg\">"
        let poisonedDetail = HTMLParser.movieDetail(from: poisoned, url: movieURL)
        expect(poisonedDetail.coverURL?.contains("4jOrgf") == true, "declared og:image beats stray DMM promo, got \(poisonedDetail.coverURL ?? "nil")")
        expect(detail.makers.contains { $0.name.contains("アイデアポケット") }, "maker")
        expect(detail.casts.contains { $0.name.contains("篠崎沙帆") }, "cast")
        expect(detail.magnets.count >= 8, "magnet count \(detail.magnets.count)")
        expect(detail.magnets.contains { $0.url.contains("btih:9000548d96673add6c69c18898516bda936fa5e0") }, "first magnet hash")
        expect(detail.magnets.contains { $0.sizeText?.contains("GB") == true }, "magnet size text")
        expect(detail.magnets.contains { $0.tags.contains("中文字幕") }, "cn sub tag")
        expect(HTMLParser.hasCatalogItems(movieHTML), "detail has catalog items")

        let rankHTML = try fixture("ranking-24h.html")
        let rank = HTMLParser.ranking(from: rankHTML)
        expect(rank.cards.count >= 15, "ranking cards \(rank.cards.count)")
        expect(rank.cards.contains { $0.pathID == "L08ykOzh" }, "rank first path")
        expect(rank.cards.contains { $0.code == "MIUM-1442" }, "rank code from split title link, got \(rank.cards.first?.code ?? "nil") / \(rank.cards.first?.title ?? "")")
        expect(rank.title.contains("24") || rank.title.contains("排行"), "ranking title \(rank.title)")

        let empty = try fixture("list-empty-shell.html")
        expect(!HTMLParser.hasCatalogItems(empty), "JS shell should be treated as empty")
        expect(HTMLParser.movieCards(in: empty).isEmpty, "JS shell has no cards")
        expect(HTMLParser.isBlocked("Just a moment... cf-browser-verification", status: 200), "cloudflare challenge is blocked")
        expect(HTMLParser.isBlocked("ok", status: 403), "403 is blocked")
        expect(HTMLParser.isBlocked("ok", status: 429), "429 is blocked")
        expect(!HTMLParser.isBlocked("<html>avfan</html>", status: 200), "200 html not blocked")

        let search = HTMLParser.searchURLCheck()
        expect(search, "search URL helper")

        // HQ cover preference: official front portrait beats c1 jacket already in the HTML.
        let mixed = """
        <a href="/zh-CN/movies/s6bNHCTN"><img src="https://c1.avfan.com/covers/4j/4jOrgf.jpg"></a>
        <meta property="og:image" content="https://pics.dmm.co.jp/digital/video/ipzz00936/ipzz00936ps.jpg">
        """
        let preferred = CoverURLPolicy.preferred(in: mixed)
        expect(preferred?.contains("ipzz00936ps.jpg") == true, "prefer official ps.jpg, got \(preferred ?? "nil")")

        let jacket = FrontPosterPolicy.cropRect(width: 800, height: 538, source: "https://c1.avfan.com/covers/4j/4jOrgf.jpg")
        expect(jacket != nil, "800x538 avfan cover is a jacket")
        expect(Int(jacket?.width ?? -1) == 377, "front width 0.70*538=377, got \(jacket?.width ?? -1)")
        expect(Int(jacket?.origin.x ?? -1) == 423, "front is right-aligned, x=423, got \(jacket?.origin.x ?? -1)")

        let portrait = FrontPosterPolicy.cropRect(width: 800, height: 538, source: "https://pics.dmm.co.jp/digital/video/ipzz00936/ipzz00936ps.jpg")
        expect(portrait == nil, "official ps.jpg is already a front portrait and must not be cropped as a jacket")

        // Hot-cast rankings: one anchor wraps photo + nested name element.
        // The parser must read the name from the whole anchor block (the old
        // first-text-node read found only whitespace and returned nobody).
        let castsHTML = """
        <h2>上周热门演员</h2>
        <div class="grid">
          <a href="/zh-CN/casts/AbCd1234" class="cast-cell">
            <img src="https://c1.avfan.com/casts/ab/abcd1234.jpg" alt="">
            <div class="name">彩月七緒</div>
          </a>
          <a href="/zh-CN/casts/EfGh5678"><span><img data-src="https://c1.avfan.com/casts/ef/efgh5678.jpg"></span><p>瀬戸環奈</p></a>
          <a href="/zh-CN/casts/AbCd1234"><img src="https://c1.avfan.com/casts/ab/dup.jpg"><div>彩月七緒</div></a>
        </div>
        """
        let castRank = HTMLParser.ranking(from: castsHTML)
        expect(castRank.people.count == 2, "hot casts people deduped, got \(castRank.people.count)")
        expect(castRank.people.first?.name == "彩月七緒", "hot casts first name, got \(castRank.people.first?.name ?? "nil")")
        expect(castRank.people.first?.imageURL?.contains("abcd1234.jpg") == true, "hot casts avatar, got \(castRank.people.first?.imageURL ?? "nil")")
        expect(castRank.people.last?.name == "瀬戸環奈", "hot casts second name, got \(castRank.people.last?.name ?? "nil")")

        // AVDB HQ cover sources: CID construction, MGS patterns, DMM upgrade.
        expect(DMMCID.candidates(number: "MIDA-860").contains("mida00860"), "MIDA-860 cid, got \(DMMCID.candidates(number: "MIDA-860"))")
        expect(DMMCID.candidates(number: "IPZZ-936").contains("ipzz00936"), "IPZZ-936 cid")
        expect(DMMCID.candidates(number: "FC2-PPV-1234567").isEmpty, "FC2 has no DMM cid")
        expect(DMMCoverURLs.digital("mida00860").first == "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/mida00860/mida00860ps.jpg", "digital ps first")
        expect(DMMCoverURLs.upgrade("https://pics.dmm.co.jp/digital/video/ipzz00936/ipzz00936pl.jpg").first?.contains("awsimgsrc") == true, "pics pl upgrades to awsimgsrc")
        expect(MGSCoverURLs.candidates(number: "ABF-123").first == "https://image.mgstage.com/images/prestige/abf/123/pf_e_abf-123.jpg", "MGS pf_e, got \(MGSCoverURLs.candidates(number: "ABF-123"))")
        expect(MGSCoverURLs.candidates(number: "MIDA-860").isEmpty, "MGS only for known maker prefixes")
        expect(DMMImageValidation.classify(width: 147, height: 200, bytes: 2732, source: "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/x/xps.jpg") == .placeholder, "147x200 is the NOW placeholder")
        expect(DMMImageValidation.classify(width: 745, height: 1081, bytes: 300_000, source: "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/mida00860/mida00860ps.jpg") == .portrait, "745x1081 ps is a portrait")
        expect(DMMImageValidation.classify(width: 1600, height: 1081, bytes: 500_000, source: "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/mida00860/mida00860pl.jpg") == .jacket, "1600x1081 pl is a jacket")

        // Ranking sub-categories come from the page's own links (build 5):
        // same-base-path anchors/options, minus the current variant, minus
        // pagination, minus other boards.
        let fanzaHTML = """
        <h2>FANZA排行榜</h2>
        <div class="tabs">
          <a href="/zh-CN/rankings/fanza_ranking?t=summary">满分(2D)</a>
          <a href="/zh-CN/rankings/fanza_ranking?t=vr">满分(VR)</a>
          <a href="/zh-CN/rankings/fanza_ranking?t=daily">日热销</a>
          <a href="/zh-CN/rankings/fanza_ranking?t=weekly">周热销</a>
          <a href="/zh-CN/rankings/fanza_ranking?t=monthly">月热销</a>
          <a href="/zh-CN/rankings/fanza_ranking?page=2">2</a>
          <a href="/zh-CN/rankings/mgs_ranking?t=daily">别榜</a>
        </div>
        """
        let fanzaTabs = HTMLParser.rankingTabs(in: fanzaHTML, basePath: "rankings/fanza_ranking", currentPath: "rankings/fanza_ranking?t=summary")
        expect(fanzaTabs.map(\.name) == ["满分(VR)", "日热销", "周热销", "月热销"], "fanza tabs, got \(fanzaTabs.map(\.name))")
        expect(fanzaTabs.first?.href.contains("t=vr") == true, "fanza tab href kept")

        let topHTML = """
        <select>
          <option value="/zh-CN/rankings/top_movies">总榜</option>
          <option value="/zh-CN/rankings/top_movies?t=censored">有码榜</option>
          <option value="/zh-CN/rankings/top_movies?t=fc2">FC2榜</option>
        </select>
        """
        let topTabs = HTMLParser.rankingTabs(in: topHTML, basePath: "rankings/top_movies", currentPath: "rankings/top_movies")
        expect(topTabs.map(\.name) == ["有码榜", "FC2榜"], "top300 category options, got \(topTabs.map(\.name))")

        // Pagination -> infinite scroll (build 5).
        let listHTML = """
        <a href="/zh-CN/casts/AbCd1234?page=1">1</a>
        <a href="/zh-CN/casts/AbCd1234?page=2">2</a>
        <a href="/zh-CN/casts/AbCd1234?page=3">3</a>
        <a href="/zh-CN/casts/AbCd1234?page=2">下一页</a>
        """
        expect(HTMLParser.nextPagePath(in: listHTML, currentPage: 1)?.contains("page=2") == true, "next from page 1")
        expect(HTMLParser.nextPagePath(in: listHTML, currentPage: 2)?.contains("page=3") == true, "next from page 2 via numbered link")
        expect(HTMLParser.nextPagePath(in: listHTML, currentPage: 3) == nil, "no page 4 means last page")
        expect(HTMLParser.nextPagePath(in: "<a href=\"/x?page=9\" rel=\"next\">go</a>", currentPage: 1)?.contains("page=9") == true, "rel=next wins")

        // News list + article and the series index (build 6), modeled on
        // the site's observed structure: news rows link cover + title
        // anchors to /news/<id> with category/date/comment meta beside
        // them; series rows are plain text links to /series/<id>.
        let newsListHTML = """
        <div class="news-list">
          <div class="news-item">
            <a href="/zh-CN/news/OISx5H0P"><img src="https://c1.avfan.com/news/cawb070.jpg"></a>
            <span>新片情報</span>
            <a href="/zh-CN/news/OISx5H0P">(CAWB-070)短髮界的最強王牌！菜々野なのは可愛社新招牌？</a>
            <span>一劍浣春秋</span><span>2026-11-15</span><span>2 评论</span>
          </div>
          <div class="news-item">
            <a href="/zh-CN/news/Kt1689zG"><img data-src="https://c1.avfan.com/news/b.jpg"></a>
            <span>八卦</span>
            <a href="/zh-CN/news/Kt1689zG">業界八卦標題在這裡</a>
            <span>2026-11-14</span>
          </div>
        </div>
        <a href="/zh-CN/news?page=2">Next &gt;</a>
        """
        let news = HTMLParser.newsItems(in: newsListHTML)
        expect(news.count == 2, "news items, got \(news.count)")
        expect(news[0].pathID == "OISx5H0P", "news id")
        expect(news[0].title.contains("CAWB-070"), "news title is the longest anchor text, got \(news[0].title)")
        expect(news[0].category == "新片情報", "news category, got \(String(describing: news[0].category))")
        expect(news[0].date == "2026-11-15", "news date, got \(String(describing: news[0].date))")
        expect(news[0].commentCount == 2, "news comments, got \(String(describing: news[0].commentCount))")
        expect(news[0].coverURL?.contains("cawb070.jpg") == true, "news cover from src")
        expect(news[1].coverURL?.contains("/b.jpg") == true, "news cover from data-src")
        expect(HTMLParser.nextPagePath(in: newsListHTML, currentPage: 1)?.contains("page=2") == true, "news pagination")

        let articleHTML = """
        <html><head><title>x</title></head><body>
        <nav>AVFan / 资讯 / 新片情報</nav>
        <h1>(CAWB-070)短髮界的最強王牌！</h1>
        <div class="meta">一劍浣春秋 2026-11-15 浏览 1 评论 2</div>
        <div class="content">
        <p>第一段正文，介紹這部作品的看點。</p>
        <p><img src="https://c1.avfan.com/news/still1.jpg"></p>
        <p>第二段正文，繼續介紹劇情與女優。</p>
        <img data-src="https://c1.avfan.com/news/still2.jpg">
        <p>作品名：短髮界的最強王牌 品番：CAWB-070 發行日：2026/12/01</p>
        </div>
        <h2>相关影片</h2>
        <div><a href="/zh-CN/movies/P4zyzr1D"><img src="https://c1.avfan.com/x.jpg" alt="CAWB-070 標題"></a></div>
        <h2>相关女优</h2>
        <a href="/zh-CN/casts/9v9LAg93">菜々野なの</a>
        <h2>同分类资讯</h2>
        <a href="/zh-CN/news/8hKziU9k">另一篇新片情報標題</a>
        </body></html>
        """
        let article = HTMLParser.newsArticle(from: articleHTML, url: URL(string: "https://avfan.com/zh-CN/news/OISx5H0P")!)
        expect(article.title.contains("CAWB-070"), "article title, got \(article.title)")
        expect(article.category == "新片情報", "article category, got \(String(describing: article.category))")
        expect(article.date == "2026-11-15", "article date, got \(String(describing: article.date))")
        expect(article.blocks.count == 5, "article blocks = 3 text + 2 images, got \(article.blocks.count)")
        expect(article.relatedMovies.first?.pathID == "P4zyzr1D", "article related movie")
        expect(article.relatedCasts.first?.name == "菜々野なの", "article related cast")
        expect(article.relatedNews.first?.pathID == "8hKziU9k", "article related news")

        let seriesHTML = """
        <div class="tabs">
          <a href="/zh-CN/series?t=asian">亚洲</a>
          <a href="/zh-CN/series?t=western">欧美</a>
        </div>
        <ul>
          <li><a href="/zh-CN/series/fOIgPiUO">2人っきりにしてみたら…</a></li>
          <li><a href="/zh-CN/series/L6TOzhqv">中出し人妻不倫旅行</a></li>
        </ul>
        <a href="/zh-CN/series?page=2">Next &gt;</a>
        """
        let series = HTMLParser.seriesItems(in: seriesHTML)
        expect(series.count == 2, "series items (t= tabs excluded), got \(series.count)")
        expect(series[0].name == "2人っきりにしてみたら…", "series name, got \(series[0].name)")
        expect(series[1].href.contains("L6TOzhqv"), "series href")

        // Build 11: pagination map + page construction.
        let pagerHTML = """
        <div class="pagination"><a href="/zh-CN/tags?t=censored&amp;page=1">1</a>
        <a href="/zh-CN/tags?t=censored&amp;page=2">2</a>
        <a href="/zh-CN/tags?t=censored&amp;page=40">40</a></div>
        """
        let pageMap = HTMLParser.pageMap(in: pagerHTML)
        expect(pageMap.count == 3 && pageMap[2]?.contains("page=2") == true && pageMap[40] != nil,
               "pageMap extracts numbered pages, got \(pageMap)")
        expect(HTMLParser.withPage("/zh-CN/tags?t=censored", page: 3).contains("page=3"),
               "withPage appends page=")
        expect(HTMLParser.withPage("/zh-CN/tags?t=censored&page=2", page: 5).contains("page=5"),
               "withPage replaces page=")
        expect(!HTMLParser.withPage("/zh-CN/tags?t=censored&page=2", page: 5).contains("page=2"),
               "withPage drops the old page")

        // Build 11: cast index cards (avatar + name + works count).
        let castIndexHTML = """
        <a href="/zh-CN/casts/AbCdEfGh"><img src="https://c1.avfan.com/avatars/a.jpg"><div>テスト女優</div><span>128 部作品</span></a>
        <a href="/zh-CN/casts/ZzYyXxWw"><img data-src="https://c1.avfan.com/avatars/b.jpg"><div>第二女優</div></a>
        """
        let castCards = HTMLParser.castCards(in: castIndexHTML)
        expect(castCards.count == 2, "cast cards count, got \(castCards.count)")
        expect(castCards.first?.name == "テスト女優", "cast name, got \(castCards.first?.name ?? "nil")")
        expect(castCards.first?.countText?.contains("128") == true, "cast count line")
        expect(castCards.first?.avatarURL?.contains("a.jpg") == true, "cast avatar")
        expect(castCards.last?.avatarURL?.contains("b.jpg") == true, "cast avatar data-src")

        // Build 11: 番号前缀 links from a page's own anchors.
        let prefixHTML = """
        <a href="/zh-CN/number_letters">番号前缀</a>
        <a href="/zh-CN/number_letters/JUR">JUR</a>
        <a href="/zh-CN/number_letters/SNOS">SNOS</a>
        <a href="/zh-CN/number_letters/JUR">JUR</a>
        """
        let prefixes = HTMLParser.prefixLinks(in: prefixHTML)
        expect(prefixes.count == 2 && prefixes.first?.name == "JUR",
               "prefix links deduped, index excluded, got \(prefixes.map(\.name))")

        // Build 11: the site's filter/sort form, parsed from its inputs.
        let filterHTML = """
        <form><label><input type="checkbox" name="f" value="all" checked>全部综合</label>
        <label><input type="checkbox" name="f" value="magnet">有磁链</label>
        <label><input type="checkbox" name="f" value="subtitle">有字幕</label>
        <label><input type="radio" name="sort" value="release" checked>最新发行</label>
        <label><input type="radio" name="sort" value="score">最高评分</label></form>
        """
        let form = HTMLParser.listFilterForm(in: filterHTML)
        expect(form != nil && form!.groups.count == 2, "filter form groups, got \(String(describing: form))")
        expect(form!.groups.first?.options.count == 3, "filter options count")
        expect(form!.groups.first?.options.first?.selected == true, "filter preselected option")
        expect(form!.groups.last?.isRadio == true && form!.groups.last?.title == "排序", "sort group detected")
        let applied = HTMLParser.applyingFilters("/zh-CN/number_letters/JUR?f=all&page=4",
                                                  form: form!,
                                                  selections: ["f": ["magnet"], "sort": ["score"]])
        expect(applied.contains("f=magnet") && applied.contains("sort=score") && !applied.contains("page="),
               "applying filters replaces params and resets paging, got \(applied)")
        expect(HTMLParser.listFilterForm(in: "<p>no form here</p>") == nil, "no form, no filter UI")

        // Build 13: the homepage filter panel — four groups carrying
        // the site's own headings （影片类型 / 筛选 / 排序 / 布局）.
        let homeFilterHTML = """
        <form><label><input type="checkbox" name="t" value="all" checked>全部类型</label>
        <label><input type="checkbox" name="t" value="censored">有码</label>
        <label><input type="checkbox" name="t" value="uncensored">无码</label>
        <label><input type="checkbox" name="t" value="western">欧美</label>
        <label><input type="checkbox" name="t" value="fc2">FC2</label>
        <label><input type="checkbox" name="t" value="anime">动漫</label>
        <label><input type="checkbox" name="t" value="chinese">华语</label>
        <label><input type="checkbox" name="f" value="all">全部综合</label>
        <label><input type="checkbox" name="f" value="magnet" checked>有磁链</label>
        <label><input type="checkbox" name="f" value="subtitle">有字幕</label>
        <label><input type="radio" name="s" value="magnet" checked>最新磁链</label>
        <label><input type="radio" name="s" value="release">最新发行</label>
        <label><input type="radio" name="s" value="playable">最新可播</label>
        <label><input type="radio" name="layout" value="1">1列</label>
        <label><input type="radio" name="layout" value="2" checked>2列</label></form>
        """
        let homeForm = HTMLParser.listFilterForm(in: homeFilterHTML)
        expect(homeForm != nil && homeForm!.groups.count == 4,
               "homepage panel groups, got \(String(describing: homeForm?.groups.count))")
        expect(homeForm!.groups.map(\.title) == ["影片类型", "筛选", "排序", "布局"],
               "homepage panel headings, got \(homeForm!.groups.map(\.title))")
        expect(homeForm!.groups.last?.isLayoutGroup == true, "layout group detected")
        expect(homeForm!.layoutColumns(selections: homeForm!.defaultSelections) == 2,
               "layout default is 2 columns")
        expect(homeForm!.defaultSelections["f"] == ["magnet"], "preselected filter kept")

        // Build 13: auto-load next-page derivation.
        expect(HTMLParser.autoNextPath(in: pagerHTML, page: 1, path: "/zh-CN/tags?t=censored")?.contains("page=2") == true,
               "autoNext uses the numbered next link")
        expect(HTMLParser.autoNextPath(in: pagerHTML, page: 40, path: "/zh-CN/tags?t=censored")?.contains("page=41") == true,
               "autoNext bumps page= when a pagination bar exists")
        expect(HTMLParser.autoNextPath(in: "<p>no paging</p>", page: 1, path: "/x") == nil,
               "autoNext is nil without pagination")

        let signedHTML = "<a href=\"/zh-CN/sign_out\">退出登录</a>"
        expect(HTMLParser.isSignedIn(html: signedHTML), "sign_out means signed in")
        expect(HTMLParser.signOutURL(in: signedHTML)?.contains("sign_out") == true, "sign_out url")
        expect(HTMLParser.containsSignInLink("<a href=\"/zh-CN/sign_in\">登录</a>"), "sign_in link")

        print("PASS: home, detail magnets, ranking merge, hot casts, HQ cover sources, empty shell, block detection, cover policy, login signals, ranking tabs, pagination, news, series, detail cover identity, page map, cast cards, prefix links, filter form, homepage panel, auto-next, home main list")
    }
}

extension HTMLParser {
    static func searchURLCheck() -> Bool {
        // Locked search path documented in SiteClient: /search?q=&st=all, no language prefix.
        let sample = "https://avfan.com/search?q=IPZZ-936&st=all"
        return sample.contains("/search?q=") && sample.contains("st=all") && !sample.contains("/zh-CN/search")
    }
}
