import SwiftUI

struct ListsView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var session: SiteSession
    @StateObject private var account = AccountLibraryModel()
    @State private var goSearch = false

    var body: some View {
        List {
            Section("我的收藏") {
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

            if session.isSignedIn {
                Section("账号 · 想看") {
                    if account.loaded && account.watchlist.isEmpty {
                        Text("账号里还没有想看的影片。在详情页点「想看」会同步到这里。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(account.watchlist) { card in
                        cardRow(card)
                    }
                }

                Section("账号 · 看过") {
                    if account.loaded && account.watched.isEmpty {
                        Text("账号里还没有看过的影片。在详情页点「看过」会同步到这里。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(account.watched) { card in
                        cardRow(card)
                    }
                }

                Section("账号 · 清单") {
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
            } else {
                Section("账号同步") {
                    Text("登录 avfan 账号后，这里会显示账号里的想看、看过和清单，与网站同步。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AVFanTheme.pageBackground)
        .liquidGlassList()
        .navigationTitle("收藏")
        .navigationDestination(isPresented: $goSearch) { SearchView() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { goSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("搜索")
            }
        }
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

    private func cardRow(_ card: MovieCard) -> some View {
        NavigationLink {
            MovieDetailView(card: card)
        } label: {
            HStack(spacing: 12) {
                CoverImage(url: card.coverURL, code: card.code)
                    .frame(width: 84, height: 56)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.code ?? card.pathID)
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
}

/// The account's 想看 / 看过 / 清单， read from the account's own
/// pages (/user/reviews?status=…, /user/lists) in the app's session.
/// Parse failures simply leave a section empty.
@MainActor
final class AccountLibraryModel: ObservableObject {
    @Published var watchlist: [MovieCard] = []
    @Published var watched: [MovieCard] = []
    @Published var lists: [NamedLink] = []
    @Published var loaded = false

    func load(settings: AppSettings, force: Bool = false) async {
        if force { await SiteClient.shared.clearCache() }
        async let watchlistPage = fetch(path: "user/reviews?status=watchlist", settings: settings)
        async let watchedPage = fetch(path: "user/reviews?status=watched", settings: settings)
        async let listsPage = fetch(path: "user/lists", settings: settings)
        let watchlistHTML = await watchlistPage
        let watchedHTML = await watchedPage
        let listsHTML = await listsPage
        if let watchlistHTML {
            watchlist = await HTMLParser.detached { HTMLParser.movieCards(in: watchlistHTML) }
        }
        if let watchedHTML {
            watched = await HTMLParser.detached { HTMLParser.movieCards(in: watchedHTML) }
        }
        if let listsHTML {
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
