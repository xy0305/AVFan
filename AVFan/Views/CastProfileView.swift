import SwiftUI

/// A cast's native profile page: avatar and identity, the account
/// actions （关注 / 收藏 / 短评 / 详细资料） wired to the site's own
/// calls, and the cast's works as an auto-loading catalog grid.
/// Everything is parsed from the cast page's own markup.
struct CastProfileView: View {
    let name: String
    let path: String
    @EnvironmentObject private var settings: AppSettings
    @State private var profile: CastProfile?
    @State private var cards: [MovieCard] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var source: FetchSource?
    @State private var showWeb = false
    @State private var pageURL: URL?
    @State private var currentPage = 1
    @State private var nextPage: String?
    @State private var activePath = ""
    @State private var filterForm: ListFilterForm?
    @State private var selections: [String: Set<String>] = [:]
    @State private var showFilters = false
    @State private var openCard: MovieCard?
    @State private var topScrollTick = 0
    // Account actions.
    @State private var following: Bool?
    @State private var collected: Bool?
    @State private var actionBusy = false
    @State private var showLogin = false
    @State private var toast: String?
    // Details + reviews.
    @State private var detailsOpen = false
    @State private var detailsRows: [(label: String, value: String)] = []
    @State private var detailsLoaded = false
    @State private var detailsNote: String?
    @State private var showReviews = false

    private var layoutColumns: Int? { filterForm?.layoutColumns(selections: selections) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FetchStatusBanner(source: source, error: errorMessage, webURL: pageURL) { showWeb = true }
                        .id("castTop")
                    if let profile {
                        header(profile)
                    } else if loading {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    }
                    MovieGrid(cards: cards, columns: layoutColumns, onSelect: { openCard = $0 }, onReachEnd: { Task { await loadNext() } })
                    if loading && !cards.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, AdaptiveLayout.horizontalPadding)
                .padding(.vertical, 12)
            }
            .onChange(of: topScrollTick) { _, _ in
                withAnimation(.none) { proxy.scrollTo("castTop", anchor: .top) }
            }
        }
        .background(AVFanTheme.pageBackground)
        .navigationTitle(profile?.name ?? name)
        .navigationDestination(item: $openCard) { MovieDetailView(card: $0) }
        .toolbar {
            if filterForm != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("筛选")
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showWeb) {
            if let pageURL { InAppWebView(url: pageURL, title: name) }
        }
        .sheet(isPresented: $showLogin, onDismiss: {
            // Login cleared the page cache; reload so the header is
            // re-parsed from the signed-in page (with model wiring).
            Task { await load() }
        }) { SiteLoginView() }
        .sheet(isPresented: $showReviews) {
            if let profile {
                CastReviewsSheet(profile: profile)
            }
        }
        .sheet(isPresented: $showFilters) {
            if let filterForm {
                FilterSheet(form: filterForm, selections: selections) { newSelections in
                    selections = newSelections
                    let filtered = HTMLParser.applyingFilters(
                        activePath.isEmpty ? path : activePath,
                        form: filterForm, selections: newSelections)
                    activePath = filtered
                    Task {
                        await loadPage(filtered, page: 1)
                        topScrollTick += 1
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.82), in: Capsule())
                    .foregroundStyle(.white)
                    // Above the floating tab bar (build 37): at 26 pt
                    // the toast hid behind it and the owner could not
                    // read sync results.
                    .padding(.bottom, 108)
            }
        }
    }

    // MARK: Header

    private func header(_ profile: CastProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                RemoteImage(url: profile.avatarURL, contentMode: .fill)
                    .frame(width: 92, height: 92)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name)
                        .font(.title3.weight(.bold))
                    if let reading = profile.reading {
                        Text(reading)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let romaji = profile.romaji {
                        Text(romaji)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let count = profile.worksCount {
                        Text("\(count) 部作品")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AVFanTheme.accent)
                    }
                    if !profile.socialLinks.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(profile.socialLinks) { link in
                                Link(destination: URL(string: link.href) ?? URL(string: "https://avfan.com")!) {
                                    Text("𝕏 \(link.name)")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(Color(.secondarySystemBackground), in: Capsule())
                                }
                            }
                        }
                    }
                }
                Spacer()
            }

            HStack(spacing: 10) {
                // Follow / collect stay tappable even when the page
                // carried no model wiring: guest pages render those
                // buttons as login triggers, so a tap opens the login
                // sheet instead of doing nothing (build 24).
                actionButton(
                    title: (following ?? profile.isFollowing) ? "已关注" : "关注",
                    active: following ?? profile.isFollowing,
                    enabled: true
                ) {
                    Task { await toggleFollow(profile) }
                }
                actionButton(
                    title: (collected ?? profile.isCollected) ? "已收藏" : "收藏",
                    active: collected ?? profile.isCollected,
                    enabled: true
                ) {
                    Task { await toggleCollect(profile) }
                }
                actionButton(title: "短评", active: false, enabled: true) {
                    if profile.reviewListURL == nil && profile.reviewCreateURL == nil && !profile.signedIn {
                        showLogin = true
                    } else {
                        showReviews = true
                    }
                }
                actionButton(title: detailsOpen ? "收起资料" : "详细资料", active: detailsOpen, enabled: profile.detailsURL != nil) {
                    Task { await toggleDetails(profile) }
                }
            }
            .disabled(actionBusy)
            .opacity(actionBusy ? 0.55 : 1)

            if detailsOpen {
                if !detailsLoaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let detailsNote {
                    Text(detailsNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(detailsRows.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top, spacing: 10) {
                                if !row.label.isEmpty {
                                    Text(row.label)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 76, alignment: .leading)
                                }
                                Text(row.value)
                                    .font(.subheadline)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private func actionButton(title: String, active: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(active ? AVFanTheme.accent : Color(.secondarySystemBackground), in: Capsule())
                .foregroundStyle(active ? .white : .primary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    // MARK: Account actions

    /// When the page carried no model wiring for an action, mirror
    /// the site: guests get the login sheet (and a reload after),
    /// a signed-in page without the wiring just reports it.
    private func missingWiring(_ profile: CastProfile) {
        if profile.signedIn {
            showToast("页面未提供该入口")
        } else {
            showLogin = true
        }
    }

    private func toggleFollow(_ profile: CastProfile) async {
        // Guests go to login first, like the site (build 37) —
        // firing the POST anyway only earns a redirect.
        guard profile.signedIn else { showLogin = true; return }
        let isOn = following ?? profile.isFollowing
        actionBusy = true
        defer { actionBusy = false }
        let outcome: LibrarySync.Outcome
        if isOn {
            guard let url = profile.unfollowURL else { missingWiring(profile); return }
            outcome = await LibrarySync.modelUndo(url: url, csrf: profile.csrfToken)
        } else {
            guard let url = profile.followURL else { missingWiring(profile); return }
            outcome = await LibrarySync.modelAction(url: url, model: profile.modelName, modelID: profile.modelID, csrf: profile.csrfToken)
        }
        if outcome.success {
            // Verify against the server before claiming it
            // (build 37): reload the profile fresh and adopt ITS
            // follow state — the same discipline as the list
            // collect (build 34). The reload also clears the
            // local override, so the button shows the truth.
            let target = !isOn
            await loadPage(activePath.isEmpty ? path : activePath, page: 1, bypassCache: true)
            if let now = self.profile, now.isFollowing == target {
                showToast(target ? "已关注" : "已取消关注")
            } else {
                showToast("未同步到账号，请稍后再试")
            }
        } else {
            handleFailure(outcome)
        }
    }

    private func toggleCollect(_ profile: CastProfile) async {
        guard profile.signedIn else { showLogin = true; return }
        let isOn = collected ?? profile.isCollected
        actionBusy = true
        defer { actionBusy = false }
        let outcome: LibrarySync.Outcome
        if isOn {
            guard let url = profile.uncollectURL else { missingWiring(profile); return }
            outcome = await LibrarySync.modelUndo(url: url, csrf: profile.csrfToken)
        } else {
            guard let url = profile.collectURL else { missingWiring(profile); return }
            outcome = await LibrarySync.modelAction(url: url, model: profile.modelName, modelID: profile.modelID, csrf: profile.csrfToken)
        }
        if outcome.success {
            let target = !isOn
            await loadPage(activePath.isEmpty ? path : activePath, page: 1, bypassCache: true)
            if let now = self.profile, now.isCollected == target {
                showToast(target ? "已收藏" : "已取消收藏")
            } else {
                showToast("未同步到账号，请稍后再试")
            }
        } else {
            handleFailure(outcome)
        }
    }

    private func toggleDetails(_ profile: CastProfile) async {
        if detailsOpen {
            detailsOpen = false
            return
        }
        detailsOpen = true
        guard !detailsLoaded, let detailsURL = profile.detailsURL else { return }
        do {
            let fragment = try await SiteClient.shared.fragment(
                for: SiteClient.shared.catalogURL(path: detailsURL),
                csrf: profile.csrfToken
            )
            if fragment.contains("登录后才能查看") {
                detailsNote = "详细资料需要登录后才能查看。"
            } else {
                detailsRows = await HTMLParser.detached { HTMLParser.infoRows(in: fragment) }
                if detailsRows.isEmpty {
                    let text = HTMLParser.stripTags(fragment)
                    detailsNote = text.isEmpty ? "没有可显示的资料。" : text
                }
            }
        } catch {
            detailsNote = "资料加载失败。"
        }
        detailsLoaded = true
    }

    private func handleFailure(_ outcome: LibrarySync.Outcome) {
        if outcome.needsLogin {
            showLogin = true
        } else {
            showToast(outcome.message ?? "同步失败")
        }
    }

    private func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            toast = nil
        }
    }

    // MARK: Works loading (same pattern as CatalogListView)

    private func load() async {
        let start = activePath.isEmpty ? path : activePath
        let page = Int(HTMLParser.firstMatch("[?&]page=(\\d+)", in: start) ?? "") ?? 1
        await loadPage(start, page: page)
    }

    private func loadNext() async {
        guard !loading, let target = nextPage else { return }
        await loadPage(target, page: currentPage + 1, append: true)
    }

    private func loadPage(_ fetchPath: String, page: Int, append: Bool = false, bypassCache: Bool = false) async {
        loading = true
        defer { loading = false }
        let url = SiteClient.shared.catalogURL(path: fetchPath)
        pageURL = url
        do {
            let result = try await SiteClient.shared.html(
                for: url,
                locale: settings.locale,
                ageCookie: settings.legalAgeCookie,
                allowWebViewFallback: true,
                expectCatalog: true,
                bypassCache: bypassCache
            )
            let html = result.html
            source = result.source
            let parsed = await HTMLParser.detached {
                (cards: HTMLParser.movieCards(in: html, fromPath: fetchPath),
                 form: HTMLParser.listFilterForm(in: html),
                 next: HTMLParser.autoNextPath(in: html, page: page, path: fetchPath),
                 profile: HTMLParser.castProfile(in: html))
            }
            if !append {
                profile = parsed.profile
                following = nil
                collected = nil
                if filterForm == nil {
                    filterForm = parsed.form
                    if let form = parsed.form { selections = form.defaultSelections }
                }
            }
            if append {
                let known = Set(cards.map(\.pathID))
                cards += parsed.cards.filter { !known.contains($0.pathID) }
                if parsed.cards.allSatisfy({ known.contains($0.pathID) }) { nextPage = nil } else { nextPage = parsed.next }
            } else {
                cards = parsed.cards
                nextPage = parsed.next
            }
            currentPage = page
            errorMessage = nil
        } catch {
            if !append { errorMessage = (error as? LocalizedError)?.errorDescription ?? "加载失败" }
            if append { nextPage = nil }
        }
    }
}

/// The cast's short reviews: the site's list fragment (hot / latest)
/// plus the write form (a score is required, like the site).
struct CastReviewsSheet: View {
    let profile: CastProfile
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CastReviewItem] = []
    @State private var fallbackText: String?
    @State private var sort = "hot"
    @State private var page = 1
    @State private var loading = false
    @State private var canLoadMore = false
    @State private var score = 0
    @State private var bodyText = ""
    @State private var message: String?
    @State private var ownReviewID: String?
    @State private var showLogin = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("排序", selection: $sort) {
                        Text("热门").tag("hot")
                        Text("最新").tag("latest")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: sort) { _, _ in Task { await reload() } }
                }
                Section("短评") {
                    if loading && items.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if items.isEmpty {
                        Text(fallbackText ?? "还没有短评。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.author).font(.subheadline.weight(.semibold))
                                Spacer()
                                if let meta = item.meta {
                                    Text(meta).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(item.body).font(.subheadline)
                        }
                        .padding(.vertical, 2)
                        .onAppear {
                            if item.id == items.last?.id && canLoadMore {
                                Task { await loadMore() }
                            }
                        }
                    }
                }
                Section("写短评") {
                    HStack(spacing: 6) {
                        ForEach(1...5, id: \.self) { star in
                            Button {
                                score = star
                            } label: {
                                Image(systemName: star <= score ? "star.fill" : "star")
                                    .foregroundStyle(star <= score ? .orange : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(score == 0 ? "先选评分" : "\(score) 分")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextEditor(text: $bodyText)
                        .frame(height: 90)
                    HStack {
                        Text("\(bodyText.count)/1000")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if ownReviewID != nil || profile.ownReviewID != nil {
                            Button("删除我的短评", role: .destructive) {
                                Task { await deleteOwn() }
                            }
                            .font(.subheadline)
                        }
                        Button("发表") {
                            Task { await submit() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .disabled(score == 0 || profile.reviewCreateURL == nil)
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("\(profile.name) · 短评")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task { await reload() }
        .sheet(isPresented: $showLogin) { SiteLoginView() }
    }

    private func listURL(page: Int) -> URL? {
        guard let base = profile.reviewListURL else { return nil }
        let separator = base.contains("?") ? "&" : "?"
        return SiteClient.shared.catalogURL(path: "\(base)\(separator)sort=\(sort)&page=\(page)")
    }

    private func reload() async {
        page = 1
        items = []
        fallbackText = nil
        canLoadMore = false
        await fetchPage(1, append: false)
    }

    private func loadMore() async {
        await fetchPage(page + 1, append: true)
    }

    private func fetchPage(_ target: Int, append: Bool) async {
        guard let url = listURL(page: target) else { return }
        loading = true
        defer { loading = false }
        do {
            let fragment = try await SiteClient.shared.fragment(for: url, csrf: profile.csrfToken)
            let parsed = await HTMLParser.detached { HTMLParser.castReviews(in: fragment) }
            if append {
                items += parsed
            } else {
                items = parsed
                if parsed.isEmpty {
                    let text = HTMLParser.stripTags(fragment)
                    fallbackText = text.isEmpty ? nil : text
                }
            }
            canLoadMore = !parsed.isEmpty
            if !parsed.isEmpty { page = target }
        } catch {
            canLoadMore = false
        }
    }

    private func submit() async {
        guard let url = profile.reviewCreateURL, let sqid = profile.reviewCastSqid else { return }
        let outcome = await LibrarySync.createCastReview(
            url: url, castSqid: sqid, score: score,
            body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
            csrf: profile.csrfToken
        )
        if outcome.success {
            ownReviewID = outcome.reviewID
            bodyText = ""
            score = 0
            message = outcome.message ?? "已发表"
            await reload()
        } else if outcome.needsLogin {
            showLogin = true
        } else {
            message = outcome.message ?? "发表失败"
        }
    }

    private func deleteOwn() async {
        let id = ownReviewID ?? profile.ownReviewID
        let destroy = profile.ownReviewDestroyURL ?? id.map { "/cast_reviews/\($0)" }
        guard let destroy else { return }
        let outcome = await LibrarySync.modelUndo(url: destroy, csrf: profile.csrfToken)
        if outcome.success {
            ownReviewID = nil
            message = "已删除"
            await reload()
        } else if outcome.needsLogin {
            showLogin = true
        } else {
            message = outcome.message ?? "删除失败"
        }
    }
}
