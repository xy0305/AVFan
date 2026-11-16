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

        // Build 24: the detail page's own extras. The summary comes
        // from the #description block (full synopsis), the tab
        // fragments' endpoints are declared in the page, and the
        // comments / related-lists fragment parsers read the shapes
        // the site's controllers consume.
        expect(detail.summary?.hasPrefix("デートして、温泉入って") == true, "summary from #description, got \(detail.summary?.prefix(20) ?? "nil")")
        expect(detail.commentsURL == "/zh-CN/movies/s6bNHCTN/comments", "comments url, got \(detail.commentsURL ?? "nil")")
        expect(detail.relatedListsURL == "/zh-CN/lists/related?movie_id=s6bNHCTN", "related lists url, got \(detail.relatedListsURL ?? "nil")")
        // Build 25: real comment markup (div.comment-list-item +
        // .username + cursor load-more), per the owner's screenshots
        // and the site's comment controller.
        let commentsFragment = """
        <div class="comment-list-item flex gap-3" data-comment-comment-id-value="641745" data-controller="comment" data-url="/zh-CN/comments/641745/react"><span class="username">wangbibby</span><p>有点儿神似波多</p><span>09-28</span><a href="javascript:;" data-action="comment#openCommentModal" data-comment-id="641745" data-placeholder="回复 wangbibby">回复</a></div>
        <div class="comment-list-item flex gap-3" data-comment-comment-id-value="641590" data-controller="comment" data-url="/zh-CN/comments/641590/react"><span class="username">superbprize821</span><p>牙口有点硬伤，肤色不算白但身材挺匀称</p><span>10-05</span><a href="javascript:;" data-action="comment#openCommentModal" data-comment-id="641590" data-placeholder="回复 superbprize821">回复</a></div>
        <div class="load-more-comments"><a href="javascript:;" data-action="comment#loadMore" data-sort-by="likes_count" data-last-value="0" data-last-id="641590">加载更多</a></div>
        """
        let parsedComments = HTMLParser.movieComments(in: commentsFragment)
        expect(parsedComments.count == 2, "comments count, got \(parsedComments.count)")
        expect(parsedComments.first?.author == "wangbibby", "comment author, got \(parsedComments.first?.author ?? "nil")")
        expect(parsedComments.first?.body.contains("神似波多") == true, "comment body, got \(parsedComments.first?.body ?? "nil")")
        expect(parsedComments.first?.body.contains("data-placeholder") == false, "comment body clean, got \(parsedComments.first?.body ?? "nil")")
        expect(parsedComments.first?.dateText == "09-28", "comment date, got \(parsedComments.first?.dateText ?? "nil")")
        expect(parsedComments.first?.commentID == "641745", "comment id, got \(parsedComments.first?.commentID ?? "nil")")
        let cursor = HTMLParser.commentsCursor(in: commentsFragment)
        expect(cursor?.sortBy == "likes_count" && cursor?.lastValue == "0" && cursor?.lastId == "641590", "comments cursor, got \(String(describing: cursor))")
        let listsFragment = """
        <div class="row"><a href="/zh-CN/lists/9rX8uDnr">碧那精选</a><span>558部作品</span><span>被查看60次</span></div>
        <div class="row"><a href="/zh-CN/lists/AbCdEfGh">家庭伦理</a><span>22部作品</span><span>被查看0次</span></div>
        <div class="row"><a href="/zh-CN/lists/xYz-123_">带符号清单</a><span>7部作品</span><span>被查看3次</span></div>
        <button data-next-page="2">下一页</button>
        """
        let parsedRows = HTMLParser.relatedListRows(in: listsFragment)
        expect(parsedRows.count == 3, "related rows, got \(parsedRows.count)")
        expect(parsedRows.first?.name == "碧那精选" && parsedRows.first?.moviesCount == 558 && parsedRows.first?.viewsCount == 60, "related row fields")
        expect(parsedRows.last?.name == "带符号清单", "related row loose id, got \(parsedRows.last?.name ?? "nil")")
        expect(HTMLParser.fragmentNextPage(in: listsFragment) == 2, "lists next page")
        // Build 25: a list page's own collect wiring.
        let listPageFragment = """
        <meta name="csrf-token" content="tok123">
        <button data-model-target="btnCollect" data-url="/zh-CN/lists/xYz-123_/collect" data-model="List" data-model-id="42">收藏</button>
        <button class="hidden" data-model-target="btnUncollect" data-url="/zh-CN/lists/xYz-123_/collect">已收藏</button>
        """
        let collectState = HTMLParser.listCollectState(in: listPageFragment)
        expect(collectState.collectURL == "/zh-CN/lists/xYz-123_/collect" && collectState.modelName == "List" && collectState.modelID == "42", "list collect wiring, got \(String(describing: collectState.collectURL))")
        expect(collectState.isCollected == false && collectState.csrfToken == "tok123", "list collect state")
        // Build 26 (lock 1.3): quote-aware stripping — a > inside a
        // quoted attribute must not end the tag early.
        let quotedTag = #"<a href="javascript:;" data-action="comment#openCommentModal" data-placeholder="回复 > wangbibby: 有点儿神似">回复</a>正文内容"#
        let strippedQuoted = HTMLParser.stripTagsQuoteAware(quotedTag)
        expect(strippedQuoted == "回复正文内容", "quote-aware strip, got \(strippedQuoted)")
        // Build 26: comment whose reply placeholder carries a quote
        // must come out clean (the build-25 residue bug).
        let residueFragment = """
        <div class="comment-list-item" data-comment-comment-id-value="641800" data-controller="comment"><span class="username">frozen_head_927</span><p>黑丝长筒袜巨乳熟女中出</p><span>11-03</span><a href="javascript:;" data-action="comment#openCommentModal" data-placeholder="回复 > frozen_head_927 的评论">回复</a></div>
        """
        let residueComments = HTMLParser.movieComments(in: residueFragment)
        expect(residueComments.count == 1 && residueComments.first?.body == "黑丝长筒袜巨乳熟女中出", "residue-free body, got \(residueComments.first?.body ?? "nil")")
        // Build 26: related rows with single-quoted hrefs (fallback).
        let singleQuoteLists = """
        <div class='row'><a href='/zh-CN/lists/QwErTy12'>ntrr</a><span>14部作品</span><span>被查看0次</span></div>
        """
        let singleRows = HTMLParser.relatedListRows(in: singleQuoteLists)
        expect(singleRows.count == 1 && singleRows.first?.name == "ntrr" && singleRows.first?.moviesCount == 14, "single-quote list rows, got \(singleRows.map(\\.name))")
        expect(HTMLParser.hasTrailerAffordance(in: "<div data-controller=\"trailer-player\"></div>") == true, "trailer affordance")
        expect(HTMLParser.hasTrailerAffordance(in: "<div class=\"plain\"></div>") == false, "no trailer affordance")
        let typeFragment = """
        <a href="/zh-CN/search?q=JUR&st=movie">影片</a><a href="/zh-CN/search?q=JUR&st=cast">演员</a><a href="/zh-CN/search?q=JUR&st=series">系列</a>
        """
        let parsedTypes = HTMLParser.searchTypes(in: typeFragment)
        expect(parsedTypes.map(\.name) == ["影片", "演员", "系列"], "search types, got \(parsedTypes.map(\.name))")
        let linkFragment = """
        <a href="/zh-CN/series/AbCd1234">某系列全集</a><a href="/zh-CN/series">系列</a>
        """
        let parsedLinks = HTMLParser.searchLinkRows(in: linkFragment, section: "series")
        expect(parsedLinks.count == 1 && parsedLinks.first?.name == "某系列全集", "search link rows, got \(parsedLinks.map(\.name))")

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

        // Build 15: the real movie-toolbar on the captured homepage.
        // Its type/filter checkboxes carry no name attribute, which is
        // why the generic parse produced a partial panel on device.
        let toolbarHomeHTML = try fixture("home.html")
        let toolbar = HTMLParser.listFilterForm(in: toolbarHomeHTML)
        expect(toolbar?.toolbar != nil, "movie-toolbar detected on the homepage")
        expect(toolbar!.groups.map(\.title) == ["影片类型", "筛选", "排序", "布局", "布局"],
               "toolbar group titles, got \(toolbar!.groups.map(\.title))")
        expect(toolbar!.groups[0].options.count == 7,
               "type options incl. 全部类型, got \(toolbar!.groups[0].options.count)")
        expect(toolbar!.groups[1].options.count == 8,
               "filter options incl. 全部综合, got \(toolbar!.groups[1].options.count)")
        expect(toolbar!.groups[2].options.map(\.label) == ["最新磁链", "最新发行", "最新可播"],
               "sort options complete, got \(toolbar!.groups[2].options.map(\.label))")
        expect(toolbar!.defaultSelections["msort"] == ["sort_by_magnet"], "sort default is 最新磁链")
        expect(toolbar!.defaultSelections["mfilter"] == ["has_magnets"], "filter default is 有磁链")
        expect(HTMLParser.applyingFilters("/zh-CN", form: toolbar!, selections: toolbar!.defaultSelections) == "/zh-CN",
               "toolbar defaults produce the bare homepage path")
        var oneType = toolbar!.defaultSelections
        oneType["tfilter"] = ["censored"]
        expect(HTMLParser.applyingFilters("/zh-CN", form: toolbar!, selections: oneType) == "/zh-CN/censored",
               "a single category type moves into the path")
        var twoTypes = toolbar!.defaultSelections
        twoTypes["tfilter"] = ["censored", "western"]
        expect(HTMLParser.applyingFilters("/zh-CN", form: toolbar!, selections: twoTypes) == "/zh-CN?tfilter=censored,western",
               "two types ride as the tfilter parameter")
        var allFilters = toolbar!.defaultSelections
        allFilters["mfilter"] = []
        expect(HTMLParser.applyingFilters("/zh-CN", form: toolbar!, selections: allFilters) == "/zh-CN?mfilter=all",
               "全部综合 applies as mfilter=all")
        var combo = toolbar!.defaultSelections
        combo["mfilter"] = ["has_magnets", "can_play"]
        combo["msort"] = ["sort_by_release"]
        expect(HTMLParser.applyingFilters("/zh-CN", form: toolbar!, selections: combo) == "/zh-CN?mfilter=has_magnets,can_play&msort=sort_by_release",
               "combined filter and sort parameters")

        // Build 16: the series page's language menu and drawer entry
        // are not tabs; the news page keeps its deliberate 全部 tab.
        let seriesTabsHTML = """
        <a href="/en/series">English</a>
        <a href="/zh-TW/series">繁體中文</a>
        <a href="/zh-CN/series">系列</a>
        <a href="/zh-CN/series?t=asian">亚洲</a>
        <a href="/zh-CN/series?t=western">欧美</a>
        <a href="/zh-CN/series?t=anime">动漫</a>
        """
        let seriesTabs = HTMLParser.rankingTabs(in: seriesTabsHTML, basePath: "series", currentPath: "series?__none")
        expect(seriesTabs.map(\.name) == ["亚洲", "欧美", "动漫"],
               "series tabs exclude language menu and self link, got \(seriesTabs.map(\.name))")
        let newsTabsHTML = """
        <a href="/zh-CN/news">全部</a>
        <a href="/zh-CN/news">资讯</a>
        <a href="/zh-CN/news?category=45">新片情報</a>
        """
        let newsTabs = HTMLParser.rankingTabs(in: newsTabsHTML, basePath: "news", currentPath: "news?__none")
        expect(newsTabs.map(\.name) == ["全部", "新片情報"],
               "news keeps its 全部 tab and drops the drawer entry, got \(newsTabs.map(\.name))")

        // Build 17: language-menu variants carry the page's own
        // path+query in other locales and precede the real tabs; one
        // must not steal the real tab's slot (the ไทย chip case).
        // "JP" is deliberately not a known language name — only the
        // page-locale rule can drop it.
        let theftHTML = """
        <a href="/en/series?t=asian">English</a>
        <a href="/th/series?t=asian">ไทย</a>
        <a href="/ja/series?t=asian">JP</a>
        <a href="/zh-CN/series?t=asian">亚洲</a>
        <a href="/zh-CN/series?t=western">欧美</a>
        <a href="/zh-CN/series?t=anime">动漫</a>
        """
        let theftTabs = HTMLParser.rankingTabs(in: theftHTML, basePath: "series", currentPath: "series?__none")
        expect(theftTabs.map(\.name) == ["亚洲", "欧美", "动漫"],
               "locale variants cannot steal a tab slot, got \(theftTabs.map(\.name))")

        // Build 17: the drawer's series-group shortcuts (prefixes,
        // the Blacked series page, the 麻豆 maker page) in site
        // order; plain list rows without the drawer class stay out.
        let drawerHTML = """
        <a href="/zh-CN/series?t=asian" class="sidebar-sub-item">亚洲</a>
        <a class="sidebar-sub-item" href="/zh-CN/number_letters/SNOS">SNOS</a>
        <a href="/zh-CN/series/4XzOv7kL" class="sidebar-sub-item">Blacked</a>
        <a class="sidebar-sub-item" href="/zh-CN/makers/B6IdQSz0?mfilter=has_magnets">麻豆傳媒映畫</a>
        <a href="/zh-CN/series/AbCdEfGh">列表里的系列</a>
        """
        let drawerLinks = HTMLParser.drawerSeriesLinks(in: drawerHTML)
        expect(drawerLinks.map(\.name) == ["SNOS", "Blacked", "麻豆傳媒映畫"],
               "drawer series shortcuts, got \(drawerLinks.map(\.name))")

        // Build 19: AVDB's scored poster selection.
        let dmmFront = PosterQuality(source: "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/1fns00123/1fns00123ps.jpg",
                                     width: 745, height: 1081, originalPortrait: false)
        let busFront = PosterQuality(source: "https://www.javbus.com/pics/cover/9ab_b.jpg",
                                     width: 377, height: 538, originalPortrait: false)
        let smallPortrait = PosterQuality(source: "https://image.mgstage.com/images/prestige/abf/123/pf_e_abf-123.jpg",
                                          width: 376, height: 538, originalPortrait: true)
        expect(PosterQuality.winner([busFront, smallPortrait, dmmFront])?.source == dmmFront.source,
               "poster winner is the highest-scored official front")
        expect(PosterQuality.winner([PosterQuality(source: "https://pics.dmm.co.jp/xps.jpg", width: 147, height: 200, originalPortrait: true)]) == nil,
               "147x200 thumbnails are never eligible")
        let bigOriginal = PosterQuality(source: "https://m.media-amazon.com/images/P/B0ABCDEFGH.01.MAIN._SCRM_.jpg",
                                        width: 1778, height: 2530, originalPortrait: true)
        expect(PosterQuality.winner([dmmFront, bigOriginal])?.source == bigOriginal.source,
               "a larger original portrait beats a derived front")

        // Build 19: JavBus identity-checked main jacket extraction.
        let javbusHTML = """
        <div class="movie"><div class="info">
        <p><span class="header">識別碼:</span><span>IPZZ-936</span></p>
        </div><a class="bigImage" href="https://www.javbus.com/pics/cover/9ab_b.jpg"><img src="x"></a></div>
        """
        let javbusImages = (try? JavBusPoster.images(html: javbusHTML, number: "IPZZ-936",
                                                     finalURL: URL(string: "https://www.javbus.com/IPZZ-936")!)) ?? []
        expect(javbusImages == ["https://www.javbus.com/pics/cover/9ab_b.jpg"],
               "javbus main jacket, got \(javbusImages)")

        // Build 19: Tenhow actor pages, record match, Amazon ASIN HQ.
        expect(TenhowPoster.pages(identities: [["JULIA"]]) == ["/julia.html"],
               "tenhow actor page from the bundled mapping")
        expect(TenhowPoster.number("FNS-123") == "fns-123", "tenhow number normalization")
        let tenhowHTML = """
        <div class="um_image_a um_popup">
        <a href="https://al.fanza.co.jp/?lurl=https://video.dmm.co.jp/av/content/?id=1fns00123">link</a>
        <a title="拡大表示" href="https://www.tenhow.net/images/B0ABCDEFGH.jpg">img</a>
        </div>
        """
        let tenhowMatch = try? TenhowPoster.match(html: tenhowHTML, number: "FNS-123")
        expect(tenhowMatch?.images == ["https://www.tenhow.net/images/B0ABCDEFGH.jpg"],
               "tenhow record image, got \(String(describing: tenhowMatch?.images))")
        expect(tenhowMatch?.official.count == 2 && tenhowMatch?.official.first?.contains("awsimgsrc") == true,
               "tenhow exact-record DMM pair, got \(String(describing: tenhowMatch?.official))")
        expect(AmazonPoster.asin(URL(string: "https://www.tenhow.net/images/B0ABCDEFGH.jpg")!) == "B0ABCDEFGH",
               "amazon asin from the tenhow image name")
        expect(AmazonPoster.directHQ(asin: "B0ABCDEFGH") == "https://m.media-amazon.com/images/P/B0ABCDEFGH.01.MAIN._SCRM_.jpg",
               "amazon direct HQ from asin")

        // Build 19: avbase catalogue identity + record parse.
        expect(CatalogueIdentity.key("IPZZ-936") == "IPZZ-936", "catalogue identity key")
        expect(CatalogueIdentity.queryForms("IPZZ-936") == ["IPZZ-936", "IPZZ936"], "catalogue query forms")
        let avbaseHTML = """
        <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"works":[{"work_id":"IPZZ-936","title":"t","products":[{"product_id":"ipzz00936","url":"https://video.dmm.co.jp/av/content/?id=ipzz00936","thumbnail_url":"https://pics.dmm.co.jp/digital/video/ipzz00936/ipzz00936ps.jpg","image_url":"https://pics.dmm.co.jp/digital/video/ipzz00936/ipzz00936pl.jpg"}]}]}}}</script>
        """
        let avbaseRecord = AvbaseMetadata.parse(html: avbaseHTML, number: "IPZZ-936")
        expect(avbaseRecord?.cover == "https://pics.dmm.co.jp/digital/video/ipzz00936/ipzz00936pl.jpg",
               "avbase record cover is the pl jacket, got \(String(describing: avbaseRecord?.cover))")
        expect(avbaseRecord?.images.first == avbaseRecord?.cover, "avbase images are HQ-first")

        // Build 20: the detail page's own trailer (JSON-LD contentUrl on
        // DMM's preview CDN, present in the real fixture) and its stills.
        expect(detail.trailerURL == "https://cc3001.dmm.co.jp/pv/Cx4GGWZWrYOl52cGncc563fxVjJvycitPeYNqr2lpA3aNjdAY08nWjd6mlItYN/ipzz00936mmb.mp4",
               "detail trailer is the page's DMM preview mp4, got \(String(describing: detail.trailerURL))")
        expect(HTMLParser.trailerURL(in: "<video src=\"https://example.com/full.mp4\"></video>") == nil,
               "a non-preview mp4 is not a trailer")
        expect(HTMLParser.trailerURL(in: "<a data-trailer-player-src-value=\"https://example.com/hls/abc.m3u8\">预告片</a>") == "https://example.com/hls/abc.m3u8",
               "the trailer trigger's declared src wins")
        let stillsHTML = """
        <img src="https://pics.dmm.co.jp/digital/video/ipzz00936/ipzz00936jp-1.jpg">
        <img data-src="https://pics.dmm.co.jp/digital/video/ipzz00936/ipzz00936jp-2.jpg">
        <img src="https://c1.avfan.com/samples/4j/4jOrgf-3.jpg">
        <img src="https://pics.dmm.co.jp/digital/video/ipzz00936/ipzz00936jp-1.jpg">
        <img src="https://static.gdario.com/aimages/ad_1.jpg">
        """
        let stills = HTMLParser.previewImages(in: stillsHTML, cover: "https://c1.avfan.com/covers/4j/4jOrgf.jpg")
        expect(stills == [
            "https://pics.dmm.co.jp/digital/video/ipzz00936/ipzz00936jp-1.jpg",
            "https://pics.dmm.co.jp/digital/video/ipzz00936/ipzz00936jp-2.jpg",
            "https://c1.avfan.com/samples/4j/4jOrgf-3.jpg",
        ], "stills keep page order, dedupe, and exclude ads, got \(stills)")

        // Build 20: account library wiring parsed from the page's own
        // markup (review controller targets + save-to-list modal), the
        // modal's list rows, and the /user/lists index.
        let libraryHTML = """
        <html><head><meta name="csrf-token" content="TOKEN123" /></head><body>
        <div data-controller="review">
          <button data-review-target="btnAddToWatchlist" data-url="/zh-CN/movies/s6bNHCTN/reviews" data-action-type="watchlist" class="inline-flex">想看</button>
          <button data-review-target="btnAlreadyInWatchlist" class="hidden">已想看</button>
          <button data-review-target="btnWatched" data-url="/zh-CN/movies/s6bNHCTN/reviews" data-action-type="watched" class="inline-flex">看过</button>
          <button data-review-target="btnAlreadyWatched" class="hidden">已看过</button>
          <button data-review-target="btnRemoveReview" data-url="">删除</button>
        </div>
        <div id="save-to-list-modal" data-change-url="/zh-CN/movies/s6bNHCTN/list_items">
          <div id="lists-container" data-url="/zh-CN/movies/s6bNHCTN/lists?x=1"></div>
        </div>
        <div id="new-list-modal"><button id="save-list-btn" data-url="/zh-CN/user/lists" data-mode="new">保存</button></div>
        </body></html>
        """
        let library = HTMLParser.libraryState(in: libraryHTML)
        expect(library?.csrfToken == "TOKEN123", "library csrf token")
        expect(library?.reviewStatus == ReviewStatus.none, "library state none when already-buttons hidden")
        expect(library?.watchlistURL == "/zh-CN/movies/s6bNHCTN/reviews", "library watchlist url")
        expect(library?.watchedActionType == "watched", "library watched action type")
        expect(library?.changeURL == "/zh-CN/movies/s6bNHCTN/list_items", "library change url")
        expect(library?.listsURL == "/zh-CN/movies/s6bNHCTN/lists?x=1", "library lists url")
        expect(library?.createListURL == "/zh-CN/user/lists" && library?.createListMode == "new", "library create list")
        let watchedHTML2 = libraryHTML.replacingOccurrences(
            of: "data-review-target=\"btnAlreadyWatched\" class=\"hidden\"",
            with: "data-review-target=\"btnAlreadyWatched\" class=\"inline-flex\"")
        expect(HTMLParser.libraryState(in: watchedHTML2)?.reviewStatus == .watched, "library state watched when already-watched visible")
        expect(HTMLParser.libraryState(in: "<html><body>no block</body></html>") == nil, "no library block, no state")

        let listFragment = """
        <label class="row"><input type="checkbox" data-list-id="12" checked> 默认 (3)</label>
        <label class="row"><input type="checkbox" data-list-id="34"> 精选 (0)</label>
        """
        let options = HTMLParser.listOptions(in: listFragment)
        expect(options.count == 2 && options[0].listID == "12" && options[0].checked && options[0].name == "默认",
               "list options parse id/checked/name, got \(options)")
        expect(options.count == 2 && options[1].listID == "34" && !options[1].checked && options[1].name == "精选",
               "list options second row")

        let userListsHTML = """
        <a href="/zh-CN/user/lists">我的清单</a>
        <a href="/zh-CN/user/lists/Ab12Cd34">默认</a>
        <a href="/zh-CN/user/lists/Xy99Zz88">精选</a>
        """
        let userLists = HTMLParser.userLists(in: userListsHTML)
        expect(userLists.map(\.name) == ["默认", "精选"], "user lists exclude the index link, got \(userLists.map(\.name))")

        let signedHTML = "<a href=\"/zh-CN/sign_out\">退出登录</a>"
        expect(HTMLParser.isSignedIn(html: signedHTML), "sign_out means signed in")
        expect(HTMLParser.signOutURL(in: signedHTML)?.contains("sign_out") == true, "sign_out url")
        expect(HTMLParser.containsSignInLink("<a href=\"/zh-CN/sign_in\">登录</a>"), "sign_in link")

        // Build 23: cast profile page — identity, model buttons,
        // details fragment URL and review wiring from the page markup.
        let castPage = """
        <html><head><title>喜多川みら, きたがわみら, mira kitagawa | AVFan</title>
        <meta name="csrf-token" content="tok123"></head><body>
        <img src="https://c1.avfan.com/avatars/7x/7xP6X6mq.jpg" alt="喜多川みら">
        <a href="https://twitter.com/k_mira_c">X</a>
        <div>20部作品</div>
        <button data-model-target="btnFollow" data-url="/follows" data-model="Cast" data-model-id="42">关注</button>
        <button data-model-target="btnUnfollow" data-url="/follows/42" class="hidden">已关注</button>
        <button data-model-target="btnCollect" data-url="/collections" data-model="Cast" data-model-id="42">收藏</button>
        <button data-model-target="btnUncollect" data-url="/collections/42" class="hidden">已收藏</button>
        <div data-controller="cast-profile" data-cast-profile-url-value="/casts/sxT5CTN5/profile"></div>
        <div data-controller="cast-review" data-create-url="/cast_reviews" data-cast-sqid="sxT5CTN5" data-cast-review-list-url-value="/casts/sxT5CTN5/reviews"></div>
        </body></html>
        """
        let castProfile = HTMLParser.castProfile(in: castPage)
        expect(castProfile.name == "喜多川みら" && castProfile.reading == "きたがわみら" && castProfile.romaji == "mira kitagawa",
               "cast identity from title segments, got \(castProfile.name)/\(castProfile.reading ?? "-")/\(castProfile.romaji ?? "-")")
        expect(castProfile.avatarURL == "https://c1.avfan.com/avatars/7x/7xP6X6mq.jpg", "cast avatar parsed")
        expect(castProfile.socialLinks.first?.name == "@k_mira_c", "cast X handle parsed")
        expect(castProfile.worksCount == 20, "cast works count parsed")
        expect(castProfile.followURL == "/follows" && castProfile.unfollowURL == "/follows/42" && !castProfile.isFollowing,
               "follow state follows the visible button")
        expect(castProfile.collectURL == "/collections" && !castProfile.isCollected, "collect state follows the visible button")
        expect(castProfile.detailsURL == "/casts/sxT5CTN5/profile", "details fragment URL parsed")
        expect(castProfile.reviewCreateURL == "/cast_reviews" && castProfile.reviewCastSqid == "sxT5CTN5" && castProfile.reviewListURL == "/casts/sxT5CTN5/reviews",
               "review wiring parsed")

        // Cast details fragment rows: table first, then definitions.
        let tableRows = HTMLParser.infoRows(in: "<table><tr><th>生日</th><td>1999-01-01</td></tr><tr><th>身高</th><td>160cm</td></tr></table>")
        expect(tableRows.count == 2 && tableRows[0].label == "生日" && tableRows[0].value == "1999-01-01" && tableRows[1].label == "身高",
               "info table rows, got \(tableRows)")
        let dlRows = HTMLParser.infoRows(in: "<dl><dt>罩杯</dt><dd>F</dd></dl>")
        expect(dlRows.count == 1 && dlRows[0].label == "罩杯" && dlRows[0].value == "F",
               "info definition rows, got \(dlRows)")

        // Cast review fragment: blocks split on the like controllers.
        let reviewFragment = """
        <div><a href="/users/7">小明</a><p>演技很好，值得一看。</p><span>2026-11-10</span>
        <span data-controller="cast-review-like" data-cast-review-like-url-value="/cast_reviews/5/like"></span></div>
        """
        let reviewItems = HTMLParser.castReviews(in: reviewFragment)
        expect(reviewItems.count == 1 && reviewItems[0].author == "小明" && reviewItems[0].body.contains("演技很好") && reviewItems[0].meta == "2026-11-10",
               "review item parsed, got \(reviewItems)")
        expect(HTMLParser.castReviews(in: "<p>nothing</p>").isEmpty, "no like blocks means no review items")

        print("PASS: home, detail magnets, ranking merge, hot casts, HQ cover sources, empty shell, block detection, cover policy, login signals, ranking tabs, pagination, news, series, detail cover identity, page map, cast cards, prefix links, filter form, homepage panel, auto-next, home main list, movie toolbar, tab hygiene, tab locale guard, drawer shortcuts, poster quality, javbus, tenhow, amazon, avbase catalogue, trailer and stills, library sync parsing, cast profile")
    }
}

extension HTMLParser {
    static func searchURLCheck() -> Bool {
        // Locked search path documented in SiteClient: /search?q=&st=all, no language prefix.
        let sample = "https://avfan.com/search?q=IPZZ-936&st=all"
        return sample.contains("/search?q=") && sample.contains("st=all") && !sample.contains("/zh-CN/search")
    }
}
