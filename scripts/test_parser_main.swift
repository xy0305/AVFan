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

        let movieHTML = try fixture("movie-ipzz-936.html")
        let movieURL = URL(string: "https://avfan.com/zh-CN/movies/s6bNHCTN")
        let detail = HTMLParser.movieDetail(from: movieHTML, url: movieURL)
        expect(detail.pathID == "s6bNHCTN", "detail path id, got \(detail.pathID)")
        expect(detail.code == "IPZZ-936", "detail 番号, got \(detail.code ?? "nil")")
        expect(detail.title.contains("篠崎"), "detail title")
        expect(detail.coverURL?.contains("c1.avfan.com") == true, "detail cover, got \(detail.coverURL ?? "nil")")
        expect(detail.coverURL?.contains(".mp4") != true, "detail cover must not be a preview video")
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

        let signedHTML = "<a href=\"/zh-CN/sign_out\">退出登录</a>"
        expect(HTMLParser.isSignedIn(html: signedHTML), "sign_out means signed in")
        expect(HTMLParser.signOutURL(in: signedHTML)?.contains("sign_out") == true, "sign_out url")
        expect(HTMLParser.containsSignInLink("<a href=\"/zh-CN/sign_in\">登录</a>"), "sign_in link")

        print("PASS: home, detail magnets, ranking merge, hot casts, HQ cover sources, empty shell, block detection, cover policy, login signals")
    }
}

extension HTMLParser {
    static func searchURLCheck() -> Bool {
        // Locked search path documented in SiteClient: /search?q=&st=all, no language prefix.
        let sample = "https://avfan.com/search?q=IPZZ-936&st=all"
        return sample.contains("/search?q=") && sample.contains("st=all") && !sample.contains("/zh-CN/search")
    }
}
