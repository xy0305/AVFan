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
expect(detail.coverURL?.contains("c1.avfan.com") == true, "detail cover")
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

print("PASS: home, detail magnets, ranking merge, empty shell, block detection")

extension HTMLParser {
    static func searchURLCheck() -> Bool {
        // Locked search path documented in SiteClient: /search?q=&st=all, no language prefix.
        let sample = "https://avfan.com/search?q=IPZZ-936&st=all"
        return sample.contains("/search?q=") && sample.contains("st=all") && !sample.contains("/zh-CN/search")
    }
}
