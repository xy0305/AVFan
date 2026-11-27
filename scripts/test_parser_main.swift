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
        expect(detail.prefixLink?.name == "IPZZ" && (detail.prefixLink?.href.contains("/number_letters/IPZZ") == true),
               "IPZZ prefix link from movie-number, got \(String(describing: detail.prefixLink))")
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
        expect(singleRows.count == 1 && singleRows.first?.name == "ntrr" && singleRows.first?.moviesCount == 14, "single-quote list rows, got \(singleRows.map(\.name))")
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

        // Build 39: the REAL site's button shape — data-action
        // ("click->model#follow", with a literal ">" inside the
        // quoted value) comes BEFORE data-model-target. The old
        // <[^>]* tag matching died at that ">", so no account
        // wiring was ever found on real pages (follow/collect
        // reported 页面未提供该入口). Locked against a trimmed
        // real cast page capture plus a follow snippet in the
        // site's exact shape.
        let castToolbar = try fixture("cast-toolbar-real.html")
        let toolbarProfile = HTMLParser.castProfile(in: castToolbar)
        expect(toolbarProfile.collectURL == "/en/user/collections",
               "real cast page collect URL parsed, got \(toolbarProfile.collectURL ?? "nil")")
        expect(toolbarProfile.modelName == "cast" && toolbarProfile.modelID == "kZbfTsDF",
               "real cast page model identity parsed, got \(toolbarProfile.modelName ?? "nil")/\(toolbarProfile.modelID ?? "nil")")
        expect(toolbarProfile.uncollectURL == "/en/user/collections/remove?model=cast&model_id=kZbfTsDF",
               "real cast page uncollect URL parsed and entity-decoded, got \(toolbarProfile.uncollectURL ?? "nil")")
        expect(toolbarProfile.isCollected == false, "real cast page not collected (uncollect hidden)")
        expect(toolbarProfile.csrfToken != nil, "real cast page csrf parsed")
        let realListState = HTMLParser.listCollectState(in: castToolbar)
        expect(realListState.collectURL == "/en/user/collections" && realListState.isCollected == false,
               "list collect state reads the real toolbar too")
        let followSnippet = """
        <div data-controller="model"><button type="button" data-action="click->model#follow" data-model="cast" data-model-id="AbCd1234" data-origin-text="关注" data-loading-text="加载中" data-model-target="btnFollow" data-url="/zh-CN/user/follows">关注</button>
        <button type="button" class="danger-dropdown-button hidden" data-action="click->model#unfollow" data-model-target="btnUnfollow" data-url="/zh-CN/user/follows/remove?model=cast&amp;model_id=AbCd1234">取消关注</button></div>
        """
        let followProfile = HTMLParser.castProfile(in: followSnippet)
        expect(followProfile.followURL == "/zh-CN/user/follows",
               "follow URL parsed past data-action, got \(followProfile.followURL ?? "nil")")
        expect(followProfile.unfollowURL == "/zh-CN/user/follows/remove?model=cast&model_id=AbCd1234",
               "unfollow URL parsed and entity-decoded, got \(followProfile.unfollowURL ?? "nil")")
        expect(followProfile.isFollowing == false, "follow state parsed (unfollow hidden)")

        // Build 40: account collection links for series / makers /
        // directors / labels — plain anchors to /<kind>/<8-char id>.
        let collectionsHTML = """
        <a href="/zh-CN/series/Ab12Cd34">系列甲</a>
        <a href="/zh-CN/makers/Xy99Zz88">制作商乙</a>
        <a href="/zh-CN/directors/Qw12Er34">导演丙</a>
        <a href="/zh-CN/labels/As34Df56">发行商丁</a>
        <a href="/zh-CN/series/Ab12Cd34">系列甲（重复）</a>
        <a href="/zh-CN/movies/Zz11Yy22">不该收的影片链接</a>
        """
        let collectionLinks = HTMLParser.collectionLinks(in: collectionsHTML)
        expect(collectionLinks.map(\.name) == ["系列甲", "制作商乙", "导演丙", "发行商丁"],
               "collection links parsed and deduped, got \(collectionLinks.map(\.name))")
        expect(collectionLinks.map { $0.kind ?? "-" } == ["series", "makers", "directors", "labels"],
               "collection link kinds, got \(collectionLinks.map { $0.kind ?? "-" })")

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

        // 1.3 fixtures: Stimulus leftovers must never appear in comment
        // bodies; JUR-875 related lists merge a cover anchor with the
        // ntrr title row; preview stills drop ad CDNs and thumbs when a
        // large sibling is already on the page; filmography is front-cover only.
        let comments13 = try fixture("comments-fragment.html")
        let parsed13 = HTMLParser.movieComments(in: comments13)
        expect(parsed13.count == 2, "1.3 comments count, got \(parsed13.count)")
        expect(parsed13[0].author == "common_pitch_112", "1.3 comment author, got \(parsed13[0].author)")
        expect(parsed13[0].body.contains("wochovy") == true, "1.3 comment body, got \(parsed13[0].body)")
        expect(parsed13[0].dateText == "11-03", "1.3 comment date, got \(String(describing: parsed13[0].dateText))")
        for item in parsed13 {
            expect(!item.body.contains("comment#"), "comment body has no comment# leftover, got \(item.body)")
            expect(!item.body.contains("data-placeholder"), "comment body has no data-placeholder leftover, got \(item.body)")
            expect(!item.body.contains("data-action"), "comment body has no data-action leftover, got \(item.body)")
            expect(!item.body.contains("openCommentModal"), "comment body has no Stimulus leftover, got \(item.body)")
        }
        expect(parsed13[1].body.contains("黑丝长筒袜") == true, "quote-reply body keeps the reply, got \(parsed13[1].body)")
        expect(parsed13[1].body.contains("乱拍的就是比麦吉") == true, "quote-reply body keeps the quoted text, got \(parsed13[1].body)")
        let cursor13 = HTMLParser.commentsCursor(in: comments13)
        expect(cursor13?.lastId == "700002", "1.3 comments cursor, got \(String(describing: cursor13))")
        let shellComments = HTMLParser.movieComments(in: movieHTML)
        expect(shellComments.isEmpty, "empty #comments shell is not parsed as comments, got \(shellComments)")

        // Build 28: real related-list fragments collected from the
        // site (movie-page Referer, public HTML). DLDSS-575, JUR-875,
        // IPZZ-936, SNOS-347. Parser is written from this markup
        // (a.name.primary-link, works-count, hits-count).
        let listsDLDSS = try fixture("related-lists-dldss575.html")
        let rowsDLDSS = HTMLParser.relatedListRows(in: listsDLDSS)
        expect(rowsDLDSS.count == 1, "DLDSS-575 related lists count, got \(rowsDLDSS.count) \(rowsDLDSS)")
        expect(rowsDLDSS[0].name == "ntrr", "DLDSS-575 list name, got \(rowsDLDSS[0].name)")
        expect(rowsDLDSS[0].moviesCount == 14 && rowsDLDSS[0].viewsCount == 0,
               "DLDSS-575 ntrr is 14部作品 被查看0次, got \(rowsDLDSS[0])")
        expect(rowsDLDSS[0].href.contains("/lists/Yim2aEoC") && !rowsDLDSS[0].href.contains("/api/"),
               "DLDSS-575 list link is not an /api/ path, got \(rowsDLDSS[0].href)")

        let listsJUR = try fixture("related-lists-jur875.html")
        let rowsJUR = HTMLParser.relatedListRows(in: listsJUR)
        expect(rowsJUR.count == 4, "JUR-875 related lists count, got \(rowsJUR.count) \(rowsJUR)")
        expect(rowsJUR.map(\.name) == ["若菜れいか", "哈喽呀看", "调教女1", "hcham"],
               "JUR-875 list names, got \(rowsJUR.map(\.name))")
        expect(rowsJUR[0].moviesCount == 25 && rowsJUR[0].viewsCount == 0, "JUR-875 first counts, got \(rowsJUR[0])")
        expect(rowsJUR[3].moviesCount == 179, "JUR-875 hcham count, got \(rowsJUR[3])")

        let listsIPZZ = try fixture("related-lists-ipzz936.html")
        let rowsIPZZ = HTMLParser.relatedListRows(in: listsIPZZ)
        expect(rowsIPZZ.count == 4, "IPZZ-936 related lists count, got \(rowsIPZZ.count)")
        expect(rowsIPZZ.map(\.name) == ["哈喽呀看", "有碼肥臀", "日本无码", "hcham"],
               "IPZZ-936 list names, got \(rowsIPZZ.map(\.name))")
        expect(rowsIPZZ[0].moviesCount == 28 && rowsIPZZ[2].moviesCount == 69, "IPZZ-936 counts")

        let listsSNOS = try fixture("related-lists-snos347.html")
        let rowsSNOS = HTMLParser.relatedListRows(in: listsSNOS)
        expect(rowsSNOS.count == 4, "SNOS-347 related lists count, got \(rowsSNOS.count) \(rowsSNOS)")
        expect(rowsSNOS[0].name == "母狗调教" && rowsSNOS[0].moviesCount == 215 && rowsSNOS[0].viewsCount == 15,
               "SNOS-347 first row, got \(rowsSNOS[0])")
        expect(rowsSNOS[1].name == "痴汉公交" && rowsSNOS[1].moviesCount == 17, "SNOS-347 second row, got \(rowsSNOS[1])")
        expect(HTMLParser.fragmentNextPage(in: listsSNOS) == 2, "SNOS-347 real fragment next page, got \(String(describing: HTMLParser.fragmentNextPage(in: listsSNOS)))")

        let listsEmpty = try fixture("related-lists-empty.html")
        expect(HTMLParser.relatedListRows(in: listsEmpty).isEmpty,
               "尚无内容 is a successful empty list, got \(HTMLParser.relatedListRows(in: listsEmpty))")

        let dldssPartial = try fixture("movie-dldss575-partial.html")
        let dldssDetail = HTMLParser.movieDetail(from: dldssPartial, url: URL(string: "https://avfan.com/zh-CN/movies/7XcoFgaf")!)
        expect(dldssDetail.prefixLink?.name == "DLDSS" && (dldssDetail.prefixLink?.href.contains("/number_letters/DLDSS") == true),
               "DLDSS prefix comes from movie-number, not the sidebar, got \(String(describing: dldssDetail.prefixLink))")
        expect(dldssDetail.relatedListsURL == "/zh-CN/lists/related?movie_id=7XcoFgaf",
               "DLDSS-575 related lists url, got \(dldssDetail.relatedListsURL ?? "nil")")
        expect(HTMLParser.hasTrailerAffordance(in: dldssPartial) == true,
               "logged-out 预告片 tile is a trailer affordance")
        expect(dldssDetail.trailerURL == "https://cc3001.dmm.co.jp/pv/CyAsExldrgefJ9dbL-StoYJox5J8QAQwz8va45VBviUfx307yIafqv6-81Yz16bd8/1dldss00575mmb.mp4",
               "DLDSS-575 public trailer is the JSON-LD DMM sample, got \(String(describing: dldssDetail.trailerURL))")

        let mixedTrailer = """
        <script type="application/ld+json">{"contentUrl":"https://cc3001.dmm.co.jp/pv/abc/jur00875mmb.mp4"}</script>
        <a data-trailer-player-src-value="https://d1.avfan.com/trailers/jur875.m3u8">预告片</a>
        """
        expect(HTMLParser.trailerURL(in: mixedTrailer) == "https://d1.avfan.com/trailers/jur875.m3u8",
               "avfan-hosted signed-in trailer wins over a DMM sample, got \(String(describing: HTMLParser.trailerURL(in: mixedTrailer)))")
        expect(HTMLParser.trailerURL(in: "<video src=\"https://avfan.com/api/play.m3u8\"></video>") == nil,
               "trailer parser rejects /api/ HLS URLs")

        let preview13 = try fixture("preview-with-ad.html")
        let stills13 = HTMLParser.previewImages(in: preview13, cover: "https://c1.avfan.com/covers/jr/jur875.jpg")
        expect(!stills13.contains(where: { $0.contains("gdario.com") }), "ad CDN excluded, got \(stills13)")
        expect(stills13.contains("https://c1.avfan.com/samples/jr/jur875/l_1.jpg"), "large sample kept, got \(stills13)")
        expect(!stills13.contains("https://c1.avfan.com/samples/jr/jur875/s_1.jpg"), "thumb dropped when large sibling is on the page, got \(stills13)")
        expect(stills13.contains("https://pics.dmm.co.jp/digital/video/jur00875/jur00875jp-1.jpg"), "DMM jp still kept, got \(stills13)")
        expect(HTMLParser.trailerURL(in: preview13) == "https://cc3001.dmm.co.jp/pv/abc/jur00875mmb.mp4",
               "preview trailer URL, got \(String(describing: HTMLParser.trailerURL(in: preview13)))")
        expect(HTMLParser.trailerURL(in: "<video src=\"https://avfan.com/api/play.mp4\"></video>") == nil,
               "trailer parser rejects /api/ media URLs")
        expect(HTMLParser.watchStreams(in: "https://avfan.com/api/stream.m3u8", pageURL: "https://avfan.com/zh-CN/movies/x").isEmpty,
               "watch streams reject /api/ paths")

        let filo = try fixture("filmography-cards.html")
        let filoCards = HTMLParser.sectionCards(in: filo, heading: "还出演过")
        expect(filoCards.count == 3, "filmography count, got \(filoCards.count)")
        expect(filoCards.map(\.displayCode) == ["DLDSS-478", "SONE-346", "SONE-297"],
               "filmography codes, got \(filoCards.map(\.displayCode))")
        expect(filoCards.allSatisfy { ($0.coverURL ?? "").contains("/covers/") },
               "filmography uses front covers only, got \(filoCards.map { $0.coverURL ?? "nil" })")

        let filoReal = try fixture("filmography-dldss575.html")
        let filoStarred = HTMLParser.sectionCards(in: filoReal, heading: "还出演过")
        expect(filoStarred.count == 6, "real DLDSS-575 filmography count, got \(filoStarred.count)")
        expect(Array(filoStarred.map(\.displayCode).prefix(3)) == ["DLDSS-478", "SONE-346", "SONE-297"],
               "real filmography first three codes, got \(filoStarred.map(\.displayCode))")
        expect(filoStarred.allSatisfy { ($0.coverURL ?? "").contains("/covers/") },
               "real filmography covers present, got \(filoStarred.map { $0.coverURL ?? "nil" })")
        expect(filoStarred[0].coverURL == "https://c1.avfan.com/covers/np/NPlstW.jpg",
               "DLDSS-478 front cover, got \(filoStarred[0].coverURL ?? "nil")")
        expect(filoStarred[1].coverURL == "https://c1.avfan.com/covers/io/IoD5hv.jpg",
               "SONE-346 front cover, got \(filoStarred[1].coverURL ?? "nil")")
        expect(filoStarred[2].coverURL == "https://c1.avfan.com/covers/ft/Ft7ZGX.jpg",
               "SONE-297 front cover, got \(filoStarred[2].coverURL ?? "nil")")
        let filoRelated = HTMLParser.sectionCards(in: filoReal, heading: "相关作品")
        expect(filoRelated.count == 6, "real related-works count, got \(filoRelated.count)")
        expect(filoRelated.allSatisfy { ($0.coverURL ?? "").contains("/covers/") },
               "related-works covers present, got \(filoRelated.map { $0.coverURL ?? "nil" })")

        // Build 41: a bare mention anchor (a text reference to
        // a movie inside prose) must not claim that movie's id
        // with the following markup's content, and must not
        // block the movie's real card later in the section.
        let mentionHTML = """
        <span class="sub-tab-item">还出演过</span>
        <p>评论里提到 <a href="/zh-CN/movies/Mntn1234">这部旧作</a> 不错</p>
        <a href="/zh-CN/movies/Real5678" title="[REAL-001] Real Title" class="history-link">
          <div><img src="https://c1.avfan.com/covers/rr/real.jpg"></div>
          <div><strong>REAL-001</strong></div>
        </a>
        <a href="/zh-CN/movies/Mntn1234" title="[MENT-002] Mention Title" class="history-link">
          <div><img src="https://c1.avfan.com/covers/mm/mention.jpg"></div>
          <div><strong>MENT-002</strong></div>
        </a>
        """
        let mentionCards = HTMLParser.sectionCards(in: mentionHTML, heading: "还出演过")
        expect(mentionCards.map(\.displayCode) == ["REAL-001", "MENT-002"],
               "mention anchor does not steal or block cards, got \(mentionCards.map(\.displayCode))")
        expect(mentionCards.last?.coverURL?.contains("/covers/mm/mention.jpg") == true,
               "the mentioned movie keeps its own cover, got \(mentionCards.last?.coverURL ?? "nil")")

        // Build 45 (LOCK-1.3-build45 D): in a strip of standard
        // history-link cards — one anchor wrapping its own img and
        // its own code, the live structure — every card's
        // (pathID, code, coverURL) triple must come from that same
        // anchor node, position by position.
        let tripleHTML = """
        <span class="sub-tab-item">还出演过</span>
        <a class="history-link" href="/zh-CN/movies/Gana3371" title="[GANA-3371] First Title">
          <div><img src="https://c1.avfan.com/covers/ga/gana.jpg"></div>
          <div><strong>GANA-3371</strong></div>
        </a>
        <a class="history-link" href="/zh-CN/movies/Nghj062x" title="[NGHJ-062] Second Title">
          <div><img src="https://c1.avfan.com/covers/ng/nghj.jpg"></div>
          <div><strong>NGHJ-062</strong></div>
        </a>
        <a class="history-link" href="/zh-CN/movies/Shyn148x" title="[SHYN-148] Third Title">
          <div><img src="https://c1.avfan.com/covers/sh/shyn.jpg"></div>
          <div><strong>SHYN-148</strong></div>
        </a>
        """
        let tripleCards = HTMLParser.sectionCards(in: tripleHTML, heading: "还出演过")
        expect(tripleCards.count == 3, "triple strip count, got \(tripleCards.count)")
        expect(tripleCards.map(\.pathID) == ["Gana3371", "Nghj062x", "Shyn148x"],
               "triple pathIDs from their own anchors, got \(tripleCards.map(\.pathID))")
        expect(tripleCards.map(\.displayCode) == ["GANA-3371", "NGHJ-062", "SHYN-148"],
               "triple codes from their own anchors, got \(tripleCards.map(\.displayCode))")
        expect(tripleCards.map { $0.coverURL ?? "nil" } == [
            "https://c1.avfan.com/covers/ga/gana.jpg",
            "https://c1.avfan.com/covers/ng/nghj.jpg",
            "https://c1.avfan.com/covers/sh/shyn.jpg"],
               "triple covers from their own anchors, got \(tripleCards.map { $0.coverURL ?? "nil" })")
        // The real filmography fixture's cards likewise carry a
        // distinct, non-empty pathID each — no shared or borrowed id.
        expect(filoStarred.allSatisfy { !$0.pathID.isEmpty }
               && Set(filoStarred.map(\.pathID)).count == filoStarred.count,
               "real filmography pathIDs distinct and non-empty, got \(filoStarred.map(\.pathID))")

        // Build 46: a spliced card must be impossible. A bare
        // anchor whose image trails OUTSIDE the anchor (in the
        // markup that follows it) is skipped entirely — it may
        // not wear the next movie's cover/code under its own id.
        // The real card later in the section still parses intact.
        let spliceHTML = """
        <span class="sub-tab-item">还出演过</span>
        <a href="/zh-CN/movies/B0BB405x">BOBB-405</a>
        <img src="https://c1.avfan.com/covers/do/doks.jpg" alt="DOKS-666 題">
        <strong>DOKS-666</strong>
        <a href="/zh-CN/movies/D0KS666x" title="[DOKS-666] t"><div><img src="https://c1.avfan.com/covers/do/doks.jpg"></div><strong>DOKS-666</strong></a>
        """
        let spliceCards = HTMLParser.sectionCards(in: spliceHTML, heading: "还出演过")
        expect(!spliceCards.contains { $0.pathID == "B0BB405x" },
               "spliced BOBB-405 card must not exist, got \(spliceCards.map(\.pathID))")
        expect(spliceCards.contains { $0.pathID == "D0KS666x" && $0.code == "DOKS-666"
                                      && ($0.coverURL ?? "").contains("doks.jpg") },
               "the real DOKS-666 card survives intact, got \(spliceCards.map { "\($0.pathID)|\($0.code ?? "nil")|\($0.coverURL ?? "nil")" })")

        // Build 46: a real archived detail page (MDB-970, EN
        // template) — the strips' (pathID, code, cover) triples
        // hold on genuine markup, not only on synthetic fragments.
        // The EN page's section slicing is inexact (the cut list is
        // the Chinese headings), so these assert containment.
        let mdb970 = try fixture("movie-mdb-970-en.html")
        let mdbStarred = HTMLParser.sectionCards(in: mdb970, heading: "also starred")
        expect(mdbStarred.contains { $0.pathID == "CpeDvBbd" && $0.code == "IPX-320"
                                     && ($0.coverURL ?? "").contains("IxXhAv.jpg") },
               "MDB-970 also-starred IPX-320 triple, got \(mdbStarred.map { "\($0.pathID)|\($0.code ?? "nil")|\($0.coverURL ?? "nil")" })")
        expect(mdbStarred.contains { $0.pathID == "cPJcrj3C" && $0.code == "DSVR-1812" },
               "MDB-970 also-starred DSVR-1812 pairing, got \(mdbStarred.map { "\($0.pathID)|\($0.code ?? "nil")" })")
        let mdbRelated = HTMLParser.sectionCards(in: mdb970, heading: "Related movies")
        expect(mdbRelated.contains { $0.pathID == "cpSVj3Cj" && $0.code == "MDB-410" },
               "MDB-970 related MDB-410 pairing, got \(mdbRelated.map { "\($0.pathID)|\($0.code ?? "nil")" })")

        // Build 46: the page's canonical link names its own movie.
        expect(HTMLParser.canonicalPathID(in: mdb970) == "02WHNm6i",
               "MDB-970 canonical id, got \(String(describing: HTMLParser.canonicalPathID(in: mdb970)))")
        expect(HTMLParser.canonicalPathID(in: "<link href=\"https://avfan.com/en/movies/AbCd1234\" rel=\"canonical\" />") == "AbCd1234",
               "canonical with href before rel")
        expect(HTMLParser.canonicalPathID(in: "<html><head><title>x</title></head>") == nil,
               "no canonical link, no id")

        // Build 47/48: same-file identity (build 45 definition).
        let picsPL = "https://pics.dmm.co.jp/digital/video/abc00001/abc00001pl.jpg"
        let awsPL = "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/abc00001/abc00001pl.jpg"
        let awsPS = "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/abc00001/abc00001ps.jpg"
        let avfanA = "https://c1.avfan.com/covers/np/NPlstW.jpg"
        let avfanB = "https://c1.avfan.com/covers/io/IoD5hv.jpg"
        expect(CoverURLPolicy.isSameFile(picsPL, picsPL), "identical URLs are the same file")
        expect(CoverURLPolicy.isSameFile(picsPL, awsPL), "pics.dmm pl and awsimgsrc pl are the same file")
        expect(CoverURLPolicy.isSameFile(awsPL, picsPL), "same-file check is symmetric")
        expect(!CoverURLPolicy.isSameFile(awsPS, awsPL), "ps portrait and pl jacket are different files")
        expect(!CoverURLPolicy.isSameFile(avfanA, avfanB), "different avfan cover hashes are different files")
        expect(!CoverURLPolicy.isSameFile(avfanA, picsPL), "avfan cover and DMM jacket are different files")
        expect(!CoverURLPolicy.isSameFile(nil, picsPL), "nil is not the same file")
        expect(!CoverURLPolicy.isSameFile("", picsPL), "empty URL is not the same file")

        // Build 31: hot searches come from the site's
        // /hot_searches JSON ({keywords: [...]}) — the panel
        // renders them client-side; they are in no page's HTML.
        let hotJSON: [String: Any] = ["keywords": ["snos", "jur", "mida", " 神木丽 ", "snos", "", "巨乳"]]
        let hot31 = HTMLParser.hotSearchKeywords(hotJSON)
        expect(hot31 == ["snos", "jur", "mida", "神木丽", "巨乳"], "hot keywords cleaned and deduped, got \(hot31)")
        expect(HTMLParser.hotSearchKeywords(nil).isEmpty, "nil JSON, no keywords")
        expect(HTMLParser.hotSearchKeywords(["other": 1]).isEmpty, "missing keywords key, no keywords")

        // Build 52: JAV Ranking boards parse javranking.cc's own
        // pages on device — video cards (article.video-card), the
        // JSON-LD ItemList (actors / sublist index) and ?page=N
        // pagination. Fixtures are real captured markup.
        let jrExplore = try fixture("jr-explore.html")
        let jrExploreCards = HTMLParser.javRankingVideoCards(in: jrExplore)
        expect(jrExploreCards.count >= 3, "jr explore cards, got \(jrExploreCards.count)")
        expect(jrExploreCards.first?.path == "/zh-hans/videos/25850/",
               "jr explore first path, got \(jrExploreCards.first?.path ?? "nil")")
        expect(jrExploreCards.first?.code == "FC2-4909883",
               "jr explore first code, got \(jrExploreCards.first?.code ?? "nil")")
        expect(jrExploreCards.first?.coverURL == "https://static.javranking.cc/video/cover/25850.webp",
               "jr explore first cover, got \(jrExploreCards.first?.coverURL ?? "nil")")
        expect(HTMLParser.javRankingHasNextPage(in: jrExplore, current: 1),
               "jr explore has a page 2")
        expect(!HTMLParser.javRankingHasNextPage(in: jrExplore, current: 5),
               "jr explore has no page 6 link")
        expect(!HTMLParser.javRankingHasNextPage(in: jrExplore, current: 165),
               "jr explore page=1665 must not count as a page=166 link")
        expect(HTMLParser.javRankingHasNextPage(in: jrExplore, current: 1664),
               "jr explore has a page 1665")

        let jrWeekly = try fixture("jr-dmm-weekly.html")
        let jrWeeklyItems = HTMLParser.javRankingItemList(in: jrWeekly)
        expect(jrWeeklyItems.count >= 3, "jr weekly item list, got \(jrWeeklyItems.count)")
        expect(jrWeeklyItems.first?.path == "/zh-hans/videos/33523/",
               "jr weekly item path, got \(jrWeeklyItems.first?.path ?? "nil")")
        expect(jrWeeklyItems.first?.name.hasPrefix("SNOS-463 ") == true,
               "jr weekly item name carries the code prefix, got \(jrWeeklyItems.first?.name ?? "nil")")
        let jrWeeklyCards = HTMLParser.javRankingVideoCards(in: jrWeekly)
        expect(jrWeeklyCards.count >= 3, "jr dmm weekly cards, got \(jrWeeklyCards.count)")
        expect(jrWeeklyCards.first?.code == "SNOS-463",
               "jr weekly first code, got \(jrWeeklyCards.first?.code ?? "nil")")
        expect(jrWeeklyCards.first?.path == "/zh-hans/videos/33523/",
               "jr weekly first path, got \(jrWeeklyCards.first?.path ?? "nil")")
        expect(jrWeeklyCards.first?.coverURL == "https://static.javranking.cc/video/cover/33523.webp",
               "jr weekly first cover, got \(jrWeeklyCards.first?.coverURL ?? "nil")")
        // The aria label carries badge suffixes ("即将发行. 当前榜单
        // #1"); the title must be the JSON-LD name minus its code
        // prefix.
        expect(jrWeeklyCards.first?.title == "我的专属公主 #1 #免费性爱 #免费性爱 #女大学生 #圈子 #巨乳 Tano Yuu 三件套写真",
               "jr weekly title from JSON-LD, got \(jrWeeklyCards.first?.title ?? "nil")")
        expect(jrWeeklyCards.first?.title.hasPrefix("SNOS-463") == false,
               "jr weekly title has no code prefix")

        let jrActors = try fixture("jr-awarded-actors.html")
        let jrActorItems = HTMLParser.javRankingItemList(in: jrActors)
        expect(jrActorItems.count >= 6, "jr awarded actors, got \(jrActorItems.count)")
        expect(jrActorItems.first?.position == 1 && jrActorItems.first?.name == "凉森玲梦",
               "jr first actor, got \(jrActorItems.first?.name ?? "nil")")
        expect(jrActorItems.first?.path == "/zh-hans/actors/actor-KxPb/",
               "jr first actor path, got \(jrActorItems.first?.path ?? "nil")")

        let jrIndex = try fixture("jr-rankings-index.html")
        let jrSubItems = HTMLParser.javRankingItemList(in: jrIndex)
        expect(jrSubItems.count >= 8, "jr sublists, got \(jrSubItems.count)")
        expect(jrSubItems.first?.path == "/zh-hans/rankings/javranking-hottest-top250-weekly/",
               "jr first sublist path, got \(jrSubItems.first?.path ?? "nil")")
        expect(jrSubItems.dropFirst().first?.name == "DMM 本周热销榜",
               "jr second sublist, got \(jrSubItems.dropFirst().first?.name ?? "nil")")

        // Build 57: 欧美 / 无码 keep the avfan original cover.
        expect(CatalogCoverPolicy.isWesternDateCode("Blacked.2026.09.10"), "western date-code Blacked.2026.09.10")
        expect(CatalogCoverPolicy.inferredType(code: "Blacked.2026.09.10") == .western, "heuristic stamps western for Blacked.2026.09.10")
        expect(HTMLParser.extractCode(from: "Blacked.2026.09.10") == "Blacked.2026.09.10", "extract western date-code, got \(HTMLParser.extractCode(from: "Blacked.2026.09.10") ?? "nil")")
        expect(CatalogCoverPolicy.inferredType(code: "HEYZO-1234") == .uncensored, "HEYZO is uncensored")
        expect(CatalogCoverPolicy.inferredType(code: "FC2-PPV-1234567") == nil, "FC2-PPV is not uncensored")
        expect(CatalogCoverPolicy.inferredType(code: "FC2-4909883") == nil, "FC2 is not uncensored")
        expect(!CatalogCoverPolicy.usesOriginalAvfanCover(explicit: nil, code: "FC2-PPV-1234567"), "FC2 does not use the original-cover path")
        expect(CatalogType.parse("无码破解") == nil, "无码破解 is not the 无码 type token")

        expect(detail.catalogType == .censored, "IPZZ-936 is 有码 from movie-info t=censored, got \(String(describing: detail.catalogType))")
        let leakedHTML = movieHTML + "<div id=\"magnets\"><span class=\"tag\">无码破解</span> magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</div>"
        let leakedDetail = HTMLParser.movieDetail(from: leakedHTML, url: movieURL)
        expect(leakedDetail.catalogType == .censored, "无码破解 magnet must not flip a 有码 title, got \(String(describing: leakedDetail.catalogType))")
        expect(!CatalogCoverPolicy.usesOriginalAvfanCover(explicit: leakedDetail.catalogType, code: leakedDetail.code), "有码 + 无码破解 still uses the jacket/HQ path")

        expect(HTMLParser.catalogType(fromPath: "/zh-CN/tags?cts=has_magnets&t=western") == .western, "t=western")
        expect(HTMLParser.catalogType(fromPath: "/zh-CN/tags?cts=has_magnets&t=uncensored") == .uncensored, "t=uncensored")
        expect(HTMLParser.catalogType(fromPath: "https://avfan.com/zh-CN?tfilter=western") == .western, "tfilter=western")
        expect(HTMLParser.catalogType(fromPath: "/zh-CN?tfilter=uncensored") == .uncensored, "tfilter=uncensored")
        expect(HTMLParser.catalogType(fromPath: "/zh-CN?tfilter=censored,western") == nil, "mixed tfilter is not exclusive")
        expect(HTMLParser.catalogType(fromPath: "/zh-CN/tags?cts=has_magnets&t=censored") == .censored, "t=censored")

        let westernList = """
        <a href="/zh-CN/movies/AbCd1234" title="[Blacked.2026.09.10] Hotel Vixen"><img src="https://c1.avfan.com/covers/xx/hotel.jpg" alt="[Blacked.2026.09.10] Hotel Vixen"><strong>Blacked.2026.09.10</strong><span class="text-sm">Hotel Vixen</span></a>
        """
        let stampedWestern = HTMLParser.movieCards(in: westernList, fromPath: "/zh-CN/tags?t=western")
        expect(stampedWestern.contains { $0.catalogType == .western }, "list t=western stamps cards, got \(stampedWestern.map { String(describing: $0.catalogType) })")
        let stampedUncensored = HTMLParser.movieCards(in: "<a href=\"/zh-CN/movies/HeYzO123\" title=\"[HEYZO-1234] sample\"><img src=\"https://c1.avfan.com/covers/xx/heyzo.jpg\" alt=\"HEYZO-1234\"><strong>HEYZO-1234</strong><span class=\"text-sm\">sample</span></a>", fromPath: "/zh-CN/tags?t=uncensored")
        expect(stampedUncensored.contains { $0.catalogType == .uncensored }, "list t=uncensored stamps cards")
        let heuristicWestern = HTMLParser.movieCards(in: westernList)
        expect(heuristicWestern.contains { $0.catalogType == .western }, "heuristic stamps Blacked date-code without list context")

        let jacketOriginal = FrontPosterPolicy.cropRect(width: 800, height: 538, source: "https://c1.avfan.com/covers/4j/4jOrgf.jpg", usesOriginalCover: true)
        expect(jacketOriginal == nil, "original-cover flag skips FrontPosterPolicy even on a 1.5-ratio avfan /covers/ URL")
        let jacketDefault = FrontPosterPolicy.cropRect(width: 800, height: 538, source: "https://c1.avfan.com/covers/4j/4jOrgf.jpg")
        expect(jacketDefault != nil, "same jacket still crops when the original-cover flag is off")

        // Build 58: DMM board goes live — FANZA GraphQL parsing
        // (fixtures trimmed from real api.video.dmm.co.jp responses,
        // 2026-11-18: daily ranks 1–3 and their maker codes).
        let dmmDaily = try fixture("dmm-graphql-daily.json")
        let dmmItems = try DMMRankings.contentItems(data: Data(dmmDaily.utf8), expectedCount: 3)
        expect(dmmItems.map(\.cid) == ["mkmp00659", "mkmp00588", "mdbk00339"],
               "dmm daily cids, got \(dmmItems.map(\.cid))")
        expect(dmmItems.map(\.rank) == [1, 2, 3], "dmm daily ranks in order")
        expect(dmmItems.allSatisfy { !$0.title.isEmpty }, "dmm daily titles present")
        let dmmCodes = try fixture("dmm-graphql-makercodes.json")
        let dmmCodeMap = try DMMRankings.makerCodes(data: Data(dmmCodes.utf8),
                                                    expectedCIDs: ["mkmp00659", "mkmp00588", "mdbk00339"])
        expect(dmmCodeMap == ["mkmp00659": "MKMP-659", "mkmp00588": "MKMP-588", "mdbk00339": "MDBK-339"],
               "dmm maker codes, got \(dmmCodeMap)")
        expect(DMMRankings.manufacturerCode("MKMP-659") == "MKMP-659", "maker code passthrough")
        expect(DMMRankings.manufacturerCode("mkmp-659") == "MKMP-659", "maker code uppercased")
        expect(DMMRankings.manufacturerCode("MKMP659") == nil, "maker code needs the hyphen")
        expect(DMMRankings.manufacturerCode("") == nil, "maker code empty rejected")
        var dmmGateThrew = false
        do {
            _ = try DMMRankings.contentItems(data: Data("{\"errors\":[{\"message\":\"gate\"}]}".utf8),
                                             expectedCount: 3)
        } catch { dmmGateThrew = true }
        expect(dmmGateThrew, "dmm errors payload is an access gate, not an empty board")
        expect(DMMCoverURLs.digital("mkmp00659").first?.contains("awsimgsrc.dmm.co.jp") == true,
               "dmm entry cover is the official FANZA image")

        // Build 60: AVBase board parsing. No real page fixture can
        // be captured from the build machine (its egress gets a
        // Cloudflare 403 from avbase.net), so this page is built to
        // the field structure documented in avbase.js v1.8.0:
        // __NEXT_DATA__ → props.pageProps.works + total, work fields
        // work_id / prefix / title / casts[].actor / tags[].name /
        // min_date / products[].iteminfo{description, volume}.
        let avb60HTML = """
        <html><head><title>AVBase fixture</title></head><body>
        <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"total":42,"works":[{"work_id":"MBMP-173","prefix":"mbm","title":"サンプル作品タイトル","min_date":"Sat Dec 05 2026 09:00:00 GMT+0900 (Japan Standard Time)","casts":[{"actor":{"name":"女優A子"}},{"actor":{"name":"女優B子"}}],"tags":[{"name":"巨乳"},{"name":"単体作品"}],"products":[{"product_id":"mbmp00173","thumbnail_url":"https://example.com/thumb.jpg","iteminfo":{"volume":"90分"}},{"product_id":"mbmp00173","image_url":"https://example.com/cover.jpg","thumbnail_url":"https://example.com/thumb2.jpg","iteminfo":{"description":"あらすじテキスト","volume":"120分"},"sample_image_urls":["https://example.com/s1.jpg"]}]},{"work_id":"IPZZ-936","title":"二作目タイトル","min_date":"2026-11-05","casts":[],"tags":[]},{"foo":"not a work"}],"decoys":[{"work_id":"XXXX-000"}]}},"buildId":"test-build"}</script>
        </body></html>
        """
        let avb60Page = AVBaseParser.page(html: avb60HTML)
        expect(avb60Page != nil, "avbase page parses from __NEXT_DATA__")
        expect(avb60Page?.total == 42, "avbase total, got \(String(describing: avb60Page?.total))")
        expect(avb60Page?.works.count == 2, "avbase works count, got \(avb60Page?.works.count ?? -1)")
        let avb60First = avb60Page?.works.first
        expect(avb60First?.code == "MBMP-173", "avbase bare code is the aggregate id, got \(avb60First?.code ?? "nil")")
        expect(avb60First?.siteCode == "mbm:MBMP-173", "avbase site code keeps the maker prefix, got \(avb60First?.siteCode ?? "nil")")
        expect(avb60First?.releaseDate == "2026-12-05", "avbase JS-date min_date normalized, got \(avb60First?.releaseDate ?? "nil")")
        expect(avb60First?.actresses == ["女優A子", "女優B子"], "avbase casts, got \(avb60First?.actresses ?? [])")
        expect(avb60First?.genres == ["巨乳", "単体作品"], "avbase tags as genres, got \(avb60First?.genres ?? [])")
        expect(avb60First?.durationMinutes == 120, "avbase duration from the picked product, got \(String(describing: avb60First?.durationMinutes))")
        expect(avb60First?.summary == "あらすじテキスト", "avbase summary from the picked product, got \(avb60First?.summary ?? "nil")")
        let avb60Second = avb60Page?.works.last
        expect(avb60Second?.code == "IPZZ-936" && avb60Second?.siteCode == "IPZZ-936",
               "avbase prefix-less work: code == site code")
        expect(avb60Second?.releaseDate == "2026-11-05", "avbase ISO min_date passthrough")
        expect(avb60Second?.durationMinutes == nil, "avbase no products → no duration")
        expect(AVBaseParser.page(html: "<html><body>no data</body></html>") == nil,
               "avbase page without __NEXT_DATA__ is nil (challenged path)")

        // avExtractWorks fallback: no preferred key, the largest
        // work-like array anywhere in pageProps wins.
        let avb60FallbackJSON = "{\"result\":[{\"work_id\":\"SONE-001\",\"title\":\"fallback title\"}],\"noise\":[1,2,3]}"
        let avb60FallbackProps = (try? JSONSerialization.jsonObject(with: Data(avb60FallbackJSON.utf8))) as? [String: Any] ?? [:]
        let avb60Fallback = AVBaseParser.page(props: avb60FallbackProps)
        expect(avb60Fallback.works.map(\.code) == ["SONE-001"], "avbase scan fallback finds the works array, got \(avb60Fallback.works.map(\.code))")
        expect(avb60Fallback.total == nil, "avbase missing total stays nil")

        // avAggregateId / avNormDate / avParseMinutes contracts.
        expect(AVBaseParser.aggregateID(number: nil, code: "mbm:MBMP-173") == "MBMP-173",
               "aggregate id strips the maker prefix")
        expect(AVBaseParser.aggregateID(number: "MBMP 173", code: nil) == "MBMP173",
               "aggregate id strips spaces")
        expect(AVBaseParser.aggregateID(number: "MBMP\u{3000}173", code: nil) == "MBMP173",
               "aggregate id strips full-width spaces")
        expect(AVBaseParser.aggregateID(number: "", code: "") == "", "aggregate id empty")
        expect(AVBaseParser.normDate("2026/11/5") == "2026-11-05", "normDate slash format")
        expect(AVBaseParser.normDate("Dec 5, 2026") == "2026-12-05", "normDate english format")
        expect(AVBaseParser.normDate("Sat Dec 05 2026 09:00:00 GMT+0900 (Japan Standard Time)") == "2026-12-05",
               "normDate JS Date string")
        expect(AVBaseParser.normDate("") == nil && AVBaseParser.normDate("未定") == nil,
               "normDate rejects non-dates")
        expect(AVBaseParser.parseMinutes("120分") == 120, "parseMinutes 分")
        expect(AVBaseParser.parseMinutes("95min") == 95, "parseMinutes min")
        expect(AVBaseParser.parseMinutes("120") == nil, "parseMinutes bare number is nil per the JS contract")

        // avPickProduct: image-less products still form the pool;
        // the description-bearing one (score 1) beats the empty one.
        let avb60PoolWork = AVBaseParser.mapWork([
            "work_id": "ABP-123",
            "title": "pool check",
            "products": [
                ["iteminfo": ["description": "d1", "volume": "30分"]],
                [String: Any](),
            ],
        ])
        expect(avb60PoolWork?.summary == "d1" && avb60PoolWork?.durationMinutes == 30,
               "avbase pick falls back to the full pool without images, got \(String(describing: avb60PoolWork))")
        expect(AVBaseParser.productScore(["image_url": "https://example.com/x.jpg"]) == 4,
               "avbase product score: image_url is +4")

        // Build 61: pagination is judged by actual returns only.
        expect(AVBaseParser.hasMore(pageCount: 30, firstPageCount: 30),
               "avbase hasMore: a full page may have a successor")
        expect(!AVBaseParser.hasMore(pageCount: 29, firstPageCount: 30),
               "avbase hasMore: a short page is the last one")
        expect(!AVBaseParser.hasMore(pageCount: 0, firstPageCount: 30),
               "avbase hasMore: an empty page ends pagination")
        expect(!AVBaseParser.hasMore(pageCount: 10, firstPageCount: 0),
               "avbase hasMore: no observed page size → no next page")

        // Build 61: talent ranking — DOM cards are primary (rank
        // badge and movement on the parent spans, ruby name +
        // furigana, card img as avatar), per the avbase.js contract.
        let avb61RankHTML = """
        <html><head><title>AVBase talents fixture</title></head><body>
        <div class="grid">
          <div class="relative"><span>1</span><span aria-label="前回より2位上昇">↑2</span>
            <article><a href="/talents/女優A子"><img src="/avatars/a.jpg" alt="女優A子"></a>
            <a href="/talents/女優A子"><ruby>女優A子<rt>じょゆうえーこ</rt></ruby></a></article></div>
          <div class="relative"><span>2</span><span aria-label="初登場">初登場</span>
            <article><a href="/talents/女優B子"><img data-src="https://www.avbase.net/avatars/b.jpg"></a>
            <a href="/talents/女優B子"><ruby>女優B子<rt>じょゆうびーこ</rt></ruby></a></article></div>
        </div>
        <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"snapshot":{"items":[]}}}}</script>
        </body></html>
        """
        let avb61Rank = AVBaseParser.talentRanking(html: avb61RankHTML)
        expect(avb61Rank.count == 2, "avbase talent ranking DOM count, got \(avb61Rank.count)")
        expect(avb61Rank.first?.rank == 1 && avb61Rank.first?.name == "女優A子",
               "avbase talent ranking first row, got \(String(describing: avb61Rank.first))")
        expect(avb61Rank.first?.furigana == "じょゆうえーこ",
               "avbase talent ranking furigana from rt, got \(avb61Rank.first?.furigana ?? "nil")")
        expect(avb61Rank.first?.avatarURL == "https://www.avbase.net/avatars/a.jpg",
               "avbase talent ranking avatar absolutized, got \(avb61Rank.first?.avatarURL ?? "nil")")
        expect(avb61Rank.first?.movementText == "上升 2 位",
               "avbase talent ranking movement, got \(avb61Rank.first?.movementText ?? "nil")")
        expect(avb61Rank.last?.movementText == "新进榜"
               && avb61Rank.last?.avatarURL == "https://www.avbase.net/avatars/b.jpg",
               "avbase talent ranking second row movement + data-src avatar, got \(String(describing: avb61Rank.last))")

        // Build 61: talent ranking JSON fallback — snapshot.items
        // is names only (talent.primary, else talent.actors[0]).
        let avb61RankFallbackHTML = """
        <html><body><p>no cards here</p>
        <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"snapshot":{"items":[{"talent":{"primary":{"name":"女優C子"}}},{"talent":{"actors":[{"name":"女優D子"}]}}]}}}}</script>
        </body></html>
        """
        let avb61RankFallback = AVBaseParser.talentRanking(html: avb61RankFallbackHTML)
        expect(avb61RankFallback.map(\.name) == ["女優C子", "女優D子"]
               && avb61RankFallback.map(\.rank) == [1, 2]
               && avb61RankFallback.allSatisfy { $0.avatarURL == nil },
               "avbase talent ranking snapshot fallback, got \(avb61RankFallback)")

        // Build 61: talent profile — name/avatar under primary,
        // measurements under meta.basic_info (numbers stringify).
        let avb61Info: [String: Any] = ["birthday": "1998-04-01", "height": 160,
                                        "bust": 88, "waist": 58, "hip": 85,
                                        "cup": "F", "prefectures": "東京都"]
        let avb61Primary: [String: Any] = ["name": "女優A子", "ruby": "じょゆうえーこ",
                                           "image_url": "/avatars/a.jpg"]
        let avb61Talent: [String: Any] = ["primary": avb61Primary,
                                          "meta": ["basic_info": avb61Info] as [String: Any]]
        let avb61TalentProps: [String: Any] = [
            "talent": avb61Talent,
            "works": [["work_id": "IPZZ-936", "title": "talent work", "prefix": "ipzz"]],
            "total": 1,
        ]
        let avb61Profile = AVBaseParser.talentProfile(props: avb61TalentProps)
        expect(avb61Profile?.name == "女優A子", "avbase talent profile name, got \(avb61Profile?.name ?? "nil")")
        expect(avb61Profile?.avatarURL == "https://www.avbase.net/avatars/a.jpg",
               "avbase talent profile avatar, got \(avb61Profile?.avatarURL ?? "nil")")
        expect(avb61Profile?.height == "160",
               "avbase talent profile numeric height stringifies, got \(avb61Profile?.height ?? "nil")")
        expect(avb61Profile?.summary == "假名 じょゆうえーこ\n生年月日 1998-04-01\n出身地 東京都\n身長 160cm\nサイズ B88(F) W58 H85",
               "avbase talent profile summary, got \(avb61Profile?.summary ?? "nil")")
        // The works list rides the same pageProps as the profile.
        let avb61TalentPage = AVBaseParser.page(props: avb61TalentProps)
        expect(avb61TalentPage.works.map(\.code) == ["IPZZ-936"] && avb61TalentPage.total == 1,
               "avbase talent page works, got \(avb61TalentPage)")
        // avFindTalent scan: no direct key, a nested talent-shaped
        // value with profile fields is still found.
        expect(AVBaseParser.talentProfile(props: ["other": avb61Talent])?.name == "女優A子",
               "avbase talent profile scan fallback")
        // A bare name normalizes but invents no profile fields.
        let avb61Bare = AVBaseParser.normTalent(["name": "女優X子"])
        expect(avb61Bare?.name == "女優X子" && avb61Bare?.summary == "",
               "avbase bare talent has an empty summary, got \(String(describing: avb61Bare))")

        print("PASS: home, detail magnets, ranking merge, hot casts, HQ cover sources, empty shell, block detection, cover policy, login signals, ranking tabs, pagination, news, series, detail cover identity, page map, cast cards, prefix links, filter form, homepage panel, auto-next, home main list, movie toolbar, tab hygiene, tab locale guard, drawer shortcuts, poster quality, javbus, tenhow, amazon, avbase catalogue, trailer and stills, library sync parsing, cast profile, comments sanitize, related lists, preview whitelist, filmography, real list fragments, number prefix, avfan trailer preference, hot searches, strip splice guard, real-page strip triples, canonical identity, same-file identity, javranking boards, original-cover types, dmm graphql boards, avbase boards, avbase talents and pagination")
    }
}

extension HTMLParser {
    static func searchURLCheck() -> Bool {
        // Locked search path documented in SiteClient: /search?q=&st=all, no language prefix.
        let sample = "https://avfan.com/search?q=IPZZ-936&st=all"
        return sample.contains("/search?q=") && sample.contains("st=all") && !sample.contains("/zh-CN/search")
    }
}
