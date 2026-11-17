import SwiftUI

/// The 「我的」 tab (build 40, replacing 收藏): a hub mirroring
/// the site's own account menu — 我的 (想看 / 看过 / 关注 /
/// 清单 / 评论和短评 / 提交的磁链) and 收藏的 (演员 / 系列 /
/// 制作商 / 导演 / 发行商 / 番号 / 清单) — plus the app's
/// local bookmarks. Every account entry opens an
/// AccountPageView over the account's own page; the routes
/// were verified to exist (signed-out visits redirect to the
/// sign-in page instead of 404ing).
struct ListsView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var session: SiteSession
    @StateObject private var account = AccountLibraryModel()
    @State private var goSearch = false
    @State private var showLogin = false

    var body: some View {
        List {
            if session.isSignedIn {
                Section("我的") {
                    hubRow("想看", icon: "eye") {
                        AccountPageView(title: "想看", path: "user/reviews?status=watchlist")
                    }
                    hubRow("看过", icon: "checkmark.circle") {
                        AccountPageView(title: "看过", path: "user/reviews?status=watched")
                    }
                    hubRow("关注", icon: "person.crop.circle.badge.checkmark") {
                        AccountPageView(title: "关注", path: "user/follows")
                    }
                    hubRow("评论和短评", icon: "text.bubble") {
                        AccountPageView(title: "评论和短评", path: "user/comments")
                    }
                    hubRow("提交的磁链", icon: "link.badge.plus") {
                        AccountPageView(title: "提交的磁链", path: "user/magnet_submissions")
                    }
                }

                Section("我的清单") {
                    if account.loaded && account.lists.isEmpty {
                        Text("账号里还没有清单。在详情页点「保存至清单」可以新建。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(account.lists) { list in
                        NavigationLink {
                            CatalogListView(title: list.name, path: HTMLParser.stripLocale(list.href))
                        } label: {
                            Text(list.name)
                        }
                    }
                }

                Section("收藏的") {
                    hubRow("演员", icon: "person.2") {
                        AccountPageView(title: "收藏的演员", path: "user/collections?model=cast")
                    }
                    hubRow("系列", icon: "rectangle.stack") {
                        AccountPageView(title: "收藏的系列", path: "user/collections?model=series")
                    }
                    hubRow("制作商", icon: "building.2") {
                        AccountPageView(title: "收藏的制作商", path: "user/collections?model=maker")
                    }
                    hubRow("导演", icon: "megaphone") {
                        AccountPageView(title: "收藏的导演", path: "user/collections?model=director")
                    }
                    hubRow("发行商", icon: "tag") {
                        AccountPageView(title: "收藏的发行商", path: "user/collections?model=label")
                    }
                    hubRow("番号", icon: "number") {
                        AccountPageView(title: "收藏的番号", path: "user/collections?model=movie")
                    }
                    hubRow("清单", icon: "list.bullet.rectangle") {
                        AccountPageView(title: "收藏的清单", path: "user/collections?model=list")
                    }
                }
            } else {
                Section("账号") {
                    Text("登录 avfan 账号后，这里就是你的「我的」：想看、看过、关注、清单、评论和收藏，与网站同步。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("登录") { showLogin = true }
                }
            }

            Section("本地收藏") {
                if bookmarks.items.isEmpty {
                    Text("在详情页收藏影片后会显示在这里。只保存在本机。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(bookmarks.items) { item in
                    itemRow(item)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        bookmarks.remove(id: bookmarks.items[index].pathID)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AVFanTheme.pageBackground)
        .liquidGlassList()
        .navigationTitle("我的")
        .navigationDestination(isPresented: $goSearch) { SearchView() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { goSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("搜索")
            }
        }
        .sheet(isPresented: $showLogin) { SiteLoginView() }
        .task(id: session.isSignedIn) {
            if session.isSignedIn {
                await account.load(settings: settings)
            }
        }
        .refreshable {
            if session.isSignedIn {
                await account.load(settings: settings, force: true)
            }
        }
    }

    private func hubRow<Destination: View>(_ title: String, icon: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private func itemRow(_ item: BookmarkItem) -> some View {
        NavigationLink {
            MovieDetailView(card: item.asCard)
        } label: {
            HStack(spacing: 12) {
                CoverImage(url: item.coverURL, code: item.code)
                    .frame(width: 84, height: 56)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.code ?? item.pathID)
                        .font(AVFanTheme.codeFont)
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
        }
    }

}

/// One account page behind a 「我的」 entry (build 40). The
/// pages come in several shapes — movie cards （想看 / 看过 /
/// 番号）, cast cards （关注 / 收藏的演员）, list rows （收藏的
/// 清单）, plain catalog links （系列 / 制作商 / 导演 / 发行商）,
/// or something the app cannot read yet （评论 / 提交的磁链） —
/// so the view parses every known shape and renders the first
/// that yields rows; if none does, it offers the web version
/// instead of a dead end. Pagination follows the page's own
/// next-page links.
struct AccountPageView: View {
    let title: String
    let path: String
    @EnvironmentObject private var settings: AppSettings
    @State private var movies: [MovieCard] = []
    @State private var casts: [CastCard] = []
    @State private var listRows: [RelatedListRow] = []
    @State private var links: [NamedLink] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var nextPath: String?
    @State private var currentPage = 1
    @State private var showWeb = false
    @State private var pageURL: URL?

    private var isEmpty: Bool {
        movies.isEmpty && casts.isEmpty && listRows.isEmpty && links.isEmpty
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("打开网页版") { showWeb = true }
                }
            }
            if !movies.isEmpty {
                Section {
                    ForEach(movies) { card in
                        movieRow(card)
                            .onAppear {
                                if card.id == movies.last?.id { Task { await loadMore() } }
                            }
                    }
                }
            }
            if !casts.isEmpty {
                Section {
                    ForEach(casts) { cast in
                        NavigationLink {
                            CastProfileView(name: cast.name, path: cast.href)
                        } label: {
                            HStack(spacing: 12) {
                                CoverImage(url: cast.avatarURL)
                                    .frame(width: 44, height: 44)
                                    .clipped()
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cast.name).font(.body)
                                    if let count = cast.countText {
                                        Text(count).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .onAppear {
                            if cast.id == casts.last?.id { Task { await loadMore() } }
                        }
                    }
                }
            }
            if !listRows.isEmpty {
                Section {
                    ForEach(listRows) { row in
                        NavigationLink {
                            CatalogListView(title: row.name, path: HTMLParser.stripLocale(row.href))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                if let count = row.moviesCount {
                                    Text("\(count) 部作品")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onAppear {
                            if row.id == listRows.last?.id { Task { await loadMore() } }
                        }
                    }
                }
            }
            if !links.isEmpty {
                Section {
                    ForEach(links) { link in
                        NavigationLink {
                            CatalogListView(title: link.name, path: HTMLParser.stripLocale(link.href))
                        } label: {
                            Text(link.name)
                        }
                        .onAppear {
                            if link.id == links.last?.id { Task { await loadMore() } }
                        }
                    }
                }
            }
            if loaded && isEmpty && errorMessage == nil {
                Section {
                    Text("这里暂时没有内容。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("打开网页版") { showWeb = true }
                }
            }
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AVFanTheme.pageBackground)
        .liquidGlassList()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(path: path, page: 1, append: false) }
        .refreshable { await load(path: path, page: 1, append: false) }
        .sheet(isPresented: $showWeb) {
            if let pageURL { InAppWebView(url: pageURL, title: title) }
        }
    }

    private func movieRow(_ card: MovieCard) -> some View {
        NavigationLink {
            MovieDetailView(card: card)
        } label: {
            HStack(spacing: 12) {
                CoverImage(url: card.coverURL, code: card.code)
                    .frame(width: 84, height: 56)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.code ?? card.displayCode)
                        .font(AVFanTheme.codeFont)
                    Text(card.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func loadMore() async {
        guard let nextPath, !loading else { return }
        await load(path: nextPath, page: currentPage + 1, append: true)
    }

    private func load(path fetchPath: String, page: Int, append: Bool) async {
        loading = true
        defer { loading = false }
        let url = SiteClient.shared.pageURL(path: fetchPath, locale: settings.locale)
        pageURL = url
        do {
            let result = try await SiteClient.shared.html(
                for: url,
                locale: settings.locale,
                ageCookie: settings.legalAgeCookie,
                allowWebViewFallback: true,
                expectCatalog: false
            )
            let html = result.html
            let parsed = await HTMLParser.detached {
                (movies: HTMLParser.movieCards(in: html),
                 casts: HTMLParser.castCards(in: html),
                 lists: HTMLParser.relatedListRows(in: html),
                 links: HTMLParser.collectionLinks(in: html),
                 next: HTMLParser.autoNextPath(in: html, page: page, path: fetchPath))
            }
            if append {
                let knownMovies = Set(movies.map(\.pathID))
                movies += parsed.movies.filter { !knownMovies.contains($0.pathID) }
                let knownCasts = Set(casts.map(\.href))
                casts += parsed.casts.filter { !knownCasts.contains($0.href) }
                let knownLists = Set(listRows.map(\.href))
                listRows += parsed.lists.filter { !knownLists.contains($0.href) }
                let knownLinks = Set(links.map(\.href))
                links += parsed.links.filter { !knownLinks.contains($0.href) }
                let added = (parsed.movies.count + parsed.casts.count + parsed.lists.count + parsed.links.count)
                nextPath = added == 0 ? nil : parsed.next
            } else {
                movies = parsed.movies
                casts = parsed.casts
                listRows = parsed.lists
                links = parsed.links
                nextPath = parsed.next
            }
            currentPage = page
            loaded = true
            errorMessage = nil
        } catch {
            if !append {
                loaded = true
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "加载失败"
            } else {
                nextPath = nil
            }
        }
    }
}

/// The account's 想看 / 看过 / 清单， read from the account's own
/// pages (/user/reviews?status=…, /user/lists) in the app's session.
/// Parse failures simply leave a section empty.
@MainActor
final class AccountLibraryModel: ObservableObject {
    @Published var lists: [NamedLink] = []
    @Published var loaded = false

    func load(settings: AppSettings, force: Bool = false) async {
        if force { await SiteClient.shared.clearCache() }
        // Only the user's own lists are read here since build 40;
        // 想看 / 看过 live behind their own 「我的」 entries.
        if let listsHTML = await fetch(path: "user/lists", settings: settings) {
            lists = await HTMLParser.detached { HTMLParser.userLists(in: listsHTML) }
        }
        loaded = true
    }

    private func fetch(path: String, settings: AppSettings) async -> String? {
        let url = SiteClient.shared.pageURL(path: path, locale: settings.locale)
        let result = try? await SiteClient.shared.html(
            for: url,
            locale: settings.locale,
            ageCookie: settings.legalAgeCookie,
            allowWebViewFallback: true,
            expectCatalog: false
        )
        return result?.html
    }
}
