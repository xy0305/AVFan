import SwiftUI

// Build 42/43: the rankings tab keeps ALL of AVFan's own boards and
// adds the external boards ported from AVDB — DMM, JAV Ranking,
// MissAV, 中指通, JAVLibrary. Build 60 adds AVBase （最新作品 /
// 按发售日 / 番号搜索， live from avbase.net's public pages).
// (JavDB's own rankings were the ones the
// owner said to skip.) External entries are keyed by code; tapping one
// resolves the code against AVFan's own search and opens the AVFan
// detail page (RankingMatchStore caches resolutions on disk and
// pre-resolves the visible list in the background). The native boards
// live in NativeRankingsView, unchanged.

private struct RankingTerm: Identifiable, Hashable {
    let id: String
    let label: String
}

private enum RankingSource: String, CaseIterable, Identifiable {
    case dmm, javranking, missav, avbase, zhongzhitong, javlibrary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dmm: return "DMM"
        case .javranking: return "JAV Ranking"
        case .missav: return "MissAV"
        case .avbase: return "AVBase"
        case .zhongzhitong: return "中指通"
        case .javlibrary: return "JAVLibrary"
        }
    }

    var terms: [RankingTerm] {
        switch self {
        case .dmm:
            return [RankingTerm(id: "daily", label: "日榜"),
                    RankingTerm(id: "weekly", label: "周榜")]
        case .javranking:
            return [RankingTerm(id: "explore", label: "精选"),
                    RankingTerm(id: "awarded-videos", label: "神作榜"),
                    RankingTerm(id: "awarded-actors", label: "女优榜"),
                    RankingTerm(id: "awarded-male-actors", label: "男优榜"),
                    RankingTerm(id: "rankings", label: "全部榜单")]
        case .missav:
            return [RankingTerm(id: "today-hot", label: "今日热门"),
                    RankingTerm(id: "weekly-hot", label: "本周热门"),
                    RankingTerm(id: "monthly-hot", label: "本月热门")]
        case .avbase:
            return [RankingTerm(id: "recent", label: "最新作品"),
                    RankingTerm(id: "bydate", label: "按发售日"),
                    RankingTerm(id: "search", label: "番号搜索")]
        case .zhongzhitong:
            return []  // dynamic: bundled catalog years/months (build 44)
        case .javlibrary:
            return [RankingTerm(id: "mostwanted", label: "最想要"),
                    RankingTerm(id: "bestrated", label: "高评价"),
                    RankingTerm(id: "actors", label: "女优收藏")]
        }
    }
}

private enum RankingTarget: Hashable, Identifiable {
    case movie(RankingBoardEntry)
    case actor(String)

    var id: String {
        switch self {
        case .movie(let entry): return "movie|" + entry.id
        case .actor(let name): return "actor|" + name
        }
    }
}


private enum RankingBoard: Hashable {
    case native
    case external(RankingSource)
}

/// Rankings tab container (build 43): a board picker on top — AVFan's
/// own boards first (NativeRankingsView, untouched), then the
/// external boards.
struct RankingsView: View {
    @State private var board: RankingBoard = .native

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    boardChip(title: "本站榜单", selected: board == .native) {
                        board = .native
                    }
                    ForEach(RankingSource.allCases) { item in
                        boardChip(title: item.title, selected: board == .external(item)) {
                            board = .external(item)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            switch board {
            case .native:
                NativeRankingsView()
            case .external(let source):
                ExternalRankingsView(source: source)
                    .id(source)
            }
        }
    }

    private func boardChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.15),
                            in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct ExternalRankingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = RankingMatchStore.shared
    @ObservedObject private var external = ExternalLibrarySettings.shared
    let source: RankingSource
    @State private var term: String

    @State private var zztYear: String = ZhongZhiTongCatalog.years.first ?? ""
    @State private var zztMonth: String = ZhongZhiTongCatalog.months.first?.month ?? ""

    // JAV Ranking (build 52): sublist picker under 全部榜单 and
    // ?page=N pagination state. Only meaningful for .javranking;
    // the view is recreated per source (.id(source)), and load()
    // resets the page state on every first-page load.
    @State private var jrSublists: [JRListItem] = []
    @State private var jrSublistPath: String?
    @State private var jrSublistError: String?
    @State private var jrPage = 1
    @State private var jrHasMore = false
    @State private var jrLoadingMore = false

    // AVBase (build 60): ?page=N pagination, the 按发售日 day being
    // browsed, and the 番号搜索 query (submitted separately from the
    // text field's live contents so typing alone never reloads).
    @State private var avPage = 1
    @State private var avHasMore = false
    @State private var avLoadingMore = false
    @State private var avDay = Date()
    @State private var avQuery = ""
    @State private var avSubmittedQuery = ""

    /// AVBase dates are JST release dates (yyyy-MM-dd).
    private var avDateString: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: avDay)
    }

    init(source: RankingSource) {
        self.source = source
        _term = State(initialValue: source.terms.first?.id ?? "")
    }
    @State private var entries: [RankingBoardEntry] = []
    @State private var updatedText: String?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var target: RankingTarget?
    @State private var loadAttempt = 0

    private var loadKey: String {
        var key = "\(source.rawValue)|\(term)|\(zztMonth)|\(loadAttempt)"
        if source == .avbase {
            if term == "bydate" { key += "|\(avDateString)" }
            if term == "search" { key += "|\(avSubmittedQuery)" }
        }
        return key
    }

    private var javlibraryConfigured: Bool {
        external.enabled && !(external.token() ?? "").isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if source == .zhongzhitong {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ZhongZhiTongCatalog.years, id: \.self) { year in
                                chip(title: "\(year) 年", selected: zztYear == year) {
                                    zztYear = year
                                    if let first = ZhongZhiTongCatalog.months(inYear: year).first {
                                        zztMonth = first.month
                                    }
                                }
                            }
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ZhongZhiTongCatalog.months(inYear: zztYear)) { month in
                                chip(title: month.monthLabel, selected: zztMonth == month.month) {
                                    zztMonth = month.month
                                }
                            }
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(source.terms) { item in
                                chip(title: item.label, selected: term == item.id) {
                                    term = item.id
                                }
                            }
                        }
                    }
                }
                if source == .javranking && term == "rankings" {
                    if !jrSublists.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(jrSublists) { item in
                                    chip(title: item.name, selected: jrSublistPath == item.path) {
                                        jrSublistPath = item.path
                                        loadAttempt += 1
                                    }
                                }
                            }
                        }
                    } else if let jrSublistError {
                        Text(jrSublistError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if source == .avbase && term == "bydate" {
                    HStack(spacing: 10) {
                        Button {
                            shiftAVDay(-1)
                        } label: {
                            Label("前一天", systemImage: "chevron.left")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        DatePicker("", selection: $avDay, displayedComponents: .date)
                            .labelsHidden()
                        Button {
                            shiftAVDay(1)
                        } label: {
                            Label("后一天", systemImage: "chevron.right")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                }
                if source == .avbase && term == "search" {
                    HStack(spacing: 8) {
                        TextField("输入番号或关键词", text: $avQuery)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { submitAVSearch() }
                        Button("搜索") { submitAVSearch() }
                            .buttonStyle(.bordered)
                            .disabled(avQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let updatedText {
                    Text(updatedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
        .navigationTitle("排行")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $target) { target in
            switch target {
            case .movie(let entry): RankingMovieTargetView(entry: entry)
            case .actor(let name): RankingActorTargetView(name: name)
            }
        }
        .task(id: loadKey) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if source == .avbase && term == "search" && avSubmittedQuery.isEmpty {
            Text("输入番号（例如 IPZZ-936）或关键词搜索 AVBase 的作品库。点进条目会按番号精确匹配 AVFan 详情页，磁力和 115 推送都在详情页上。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 24)
        } else if source == .javlibrary && !javlibraryConfigured {
            Text("JAVLibrary 排行走外部数据库服务。请先在「设置 → 外部数据库」填好服务器和令牌并启用，再回到这里。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 24)
        } else if loading && entries.isEmpty {
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, 40)
        } else if let errorMessage, entries.isEmpty {
            VStack(spacing: 12) {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试") { loadAttempt += 1 }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            VStack(spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                          spacing: 14) {
                    ForEach(entries) { entry in
                        Button {
                            target = entry.isActor
                                ? .actor(entry.actorName ?? entry.title)
                                : .movie(entry)
                        } label: {
                            RankingGridCell(entry: entry, source: source)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if (source == .javranking && jrHasMore) || (source == .avbase && avHasMore) {
                    Button {
                        Task {
                            if source == .avbase { await loadMoreAVBase() } else { await loadMore() }
                        }
                    } label: {
                        if jrLoadingMore || avLoadingMore {
                            ProgressView()
                        } else {
                            Text("加载更多")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(jrLoadingMore || avLoadingMore || loading)
                }
            }
        }
    }

    private func chip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.15),
                            in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        if source == .javlibrary && !javlibraryConfigured {
            entries = []
            updatedText = nil
            errorMessage = nil
            return
        }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            switch source {
            case .zhongzhitong:
                guard let month = ZhongZhiTongCatalog.month(zztMonth) else {
                    entries = []
                    updatedText = nil
                    return
                }
                entries = month.entries
                updatedText = "中指通月度精选 · 2019–2026 年全量"
            case .dmm:
                // Live from FANZA's official GraphQL (build 58),
                // the same verified queries AVDB uses — the frozen
                // pre-matched feed is retired for this board, and a
                // failed fetch lands in the error state instead of
                // ever falling back to it. Entries carry the maker
                // code and the official FANZA cover; matching and
                // the grid's HQ-first cover rule are unchanged.
                let rows = try await DMMRankings.load(term: term)
                entries = rows.map { row in
                    RankingBoardEntry(rank: row.rank, code: row.code,
                                      title: row.title, coverURL: row.coverURL,
                                      actresses: [], actorName: nil)
                }
                updatedText = "实时抓取自 FANZA (DMM)"
            case .javranking:
                // Live from javranking.cc (build 52) — no frozen
                // feed. The sublist chips' data loads alongside the
                // first page; its failure is reported in the chips
                // row and retried on the next load while the list
                // itself falls back to the first sublist.
                if term == "rankings", jrSublists.isEmpty {
                    do {
                        jrSublists = try await JavRankingLists.sublists()
                        jrSublistError = nil
                        if jrSublistPath == nil {
                            jrSublistPath = jrSublists.first?.path
                        }
                    } catch {
                        jrSublistError = "子榜单取不到，请稍后重试。"
                    }
                }
                jrHasMore = false
                let result = try await JavRankingLists.loadPage(
                    term: term, sublistPath: jrSublistPath, page: 1, rankOffset: 0)
                entries = result.entries
                jrPage = 1
                jrHasMore = result.hasMore
                updatedText = "实时抓取自 JAV Ranking"
            case .missav:
                entries = try await MissAVRankings.load(term: term)
                updatedText = "实时抓取自 MissAV"
            case .avbase:
                // Live from AVBase's public pages (build 60) —
                // __NEXT_DATA__ parsed on device, entries keyed by
                // the bare code with NO AVBase cover (the grid's HQ
                // chain resolves covers). Taps go through the same
                // RankingMatchStore exact-code match as every other
                // board, landing on the AVFan detail page.
                avHasMore = false
                let result: AVBaseBoardPage
                switch term {
                case "bydate":
                    result = try await AVBaseClient.shared.loadDate(avDateString, page: 1)
                case "search":
                    let keyword = avSubmittedQuery
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !keyword.isEmpty else {
                        entries = []
                        updatedText = nil
                        return
                    }
                    result = try await AVBaseClient.shared.loadSearch(query: keyword, page: 1)
                default:
                    result = try await AVBaseClient.shared.loadRecent(page: 1)
                }
                entries = result.entries
                avPage = 1
                avHasMore = result.hasMore
                updatedText = "实时抓取自 AVBase"
            case .javlibrary:
                let snapshot = try await ExternalLibraryClient.shared
                    .fetchJAVLibraryRankings(kind: term)
                entries = snapshot.items.map { item in
                    if item.entityType == "actor" {
                        return RankingBoardEntry(rank: item.rank, code: nil,
                                                 title: item.name ?? "",
                                                 coverURL: nil, actresses: [],
                                                 actorName: item.name)
                    }
                    return RankingBoardEntry(rank: item.rank, code: item.number,
                                             title: item.title ?? item.number ?? "",
                                             coverURL: nil, actresses: [],
                                             actorName: nil)
                }
                var text = snapshot.fetchedAt.map { "快照时间 \(String($0.prefix(10)))" }
                if snapshot.stale == true {
                    text = (text ?? "快照") + " · 可能已过期"
                }
                updatedText = text
            }
            let coverURLs = entries.prefix(36).compactMap { $0.coverURL }
            Task {
                for url in coverURLs { await ImageLoader.shared.warm(url) }
            }
            await store.preResolve(entries: entries, locale: settings.locale,
                                   ageCookie: settings.legalAgeCookie)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "榜单加载失败，请稍后重试。"
        }
    }

    /// JAV Ranking pagination (build 52): appends the next ?page=N,
    /// deduped by entry id, and pre-resolves only the new slice. A
    /// failed page quietly ends pagination instead of erroring over
    /// the entries already on screen.
    private func loadMore() async {
        guard source == .javranking, jrHasMore, !loading, !jrLoadingMore else { return }
        jrLoadingMore = true
        defer { jrLoadingMore = false }
        let forTerm = term
        let forSublist = jrSublistPath
        do {
            let result = try await JavRankingLists.loadPage(
                term: forTerm, sublistPath: forSublist,
                page: jrPage + 1, rankOffset: entries.count)
            guard term == forTerm, jrSublistPath == forSublist else { return }
            let known = Set(entries.map(\.id))
            let fresh = result.entries.filter { !known.contains($0.id) }
            entries += fresh
            jrPage += 1
            jrHasMore = result.hasMore
            await store.preResolve(entries: fresh, locale: settings.locale,
                                   ageCookie: settings.legalAgeCookie)
        } catch is CancellationError {
            return
        } catch {
            jrHasMore = false
        }
    }

    /// AVBase pagination (build 60): same contract as JAV Ranking's
    /// loadMore — appends the next page deduped by entry id and
    /// pre-resolves only the new slice; a failed page quietly ends
    /// pagination. The term/date/query snapshot guards against the
    /// surface changing mid-flight.
    private func loadMoreAVBase() async {
        guard source == .avbase, avHasMore, !loading, !avLoadingMore else { return }
        avLoadingMore = true
        defer { avLoadingMore = false }
        let forTerm = term
        let forDate = avDateString
        let forQuery = avSubmittedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result: AVBaseBoardPage
            switch forTerm {
            case "bydate":
                result = try await AVBaseClient.shared.loadDate(forDate, page: avPage + 1)
            case "search":
                guard !forQuery.isEmpty else { return }
                result = try await AVBaseClient.shared.loadSearch(query: forQuery, page: avPage + 1)
            default:
                result = try await AVBaseClient.shared.loadRecent(page: avPage + 1)
            }
            guard term == forTerm, avDateString == forDate,
                  avSubmittedQuery.trimmingCharacters(in: .whitespacesAndNewlines) == forQuery
            else { return }
            let known = Set(entries.map(\.id))
            let fresh = result.entries.filter { !known.contains($0.id) }
            entries += fresh
            avPage += 1
            avHasMore = result.hasMore
            await store.preResolve(entries: fresh, locale: settings.locale,
                                   ageCookie: settings.legalAgeCookie)
        } catch is CancellationError {
            return
        } catch {
            avHasMore = false
        }
    }

    private func shiftAVDay(_ offset: Int) {
        if let shifted = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: offset, to: avDay) {
            avDay = shifted
        }
    }

    private func submitAVSearch() {
        let keyword = avQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        avSubmittedQuery = keyword
        // Force a reload even when the same keyword is re-submitted
        // (loadKey is unchanged in that case).
        loadAttempt += 1
    }
}

private struct RankingGridCell: View {
    let entry: RankingBoardEntry
    let source: RankingSource
    @ObservedObject private var store = RankingMatchStore.shared

    private var matchedCard: MovieCard? {
        guard let code = entry.code else { return nil }
        return store.resolvedCards[RankingMatchStore.key(for: code)]
    }

    /// Build 57: original-cover display only for an avfan-matched
    /// row whose type is known. Unmatched rows stay as they are;
    /// type is never guessed from the ranking code alone.
    private var usesOriginalCover: Bool {
        matchedCard?.usesOriginalAvfanCover == true
    }

    /// The cover shown until the HQ probe lands: the matched
    /// AVFan cover, except DMM — whose entries bring an official
    /// FANZA cover that outranks the watermarked AVFan one — and
    /// MissAV, whose own CDN thumbnail is the fallback seed.
    private var seedURL: String? {
        if usesOriginalCover { return matchedCard?.coverURL }
        if source == .dmm { return entry.coverURL ?? matchedCard?.coverURL }
        return matchedCard?.coverURL ?? (source == .missav ? entry.coverURL : nil)
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topLeading) {
                if entry.isActor {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    }
                    .aspectRatio(3.0 / 4.0, contentMode: .fill)
                } else {
                    // Cover policy (build 46, owner's rule): match an
                    // HQ cover first (probeDisplaysWinner lets the
                    // probe's winner land on screen), fall back to
                    // the matched movie's AVFan cover, and never use
                    // a JavDB-hosted cover. MissAV's own thumbnails
                    // stay as its source cover under the same
                    // HQ-first rule. Build 57: avfan-matched 欧美 /
                    // 无码 titles skip HQ and letterbox the page cover.
                    // Build 58: DMM entries carry an official FANZA
                    // cover, which seeds ahead of the (watermarked)
                    // matched AVFan cover under the same HQ probe.
                    CoverImage(url: seedURL,
                               code: usesOriginalCover ? nil : entry.code,
                               usesOriginalCover: usesOriginalCover,
                               registryCode: entry.code,
                               probeDisplaysWinner: !usesOriginalCover)
                        .aspectRatio(3.0 / 4.0, contentMode: .fill)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Text("\(entry.rank)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(entry.rank <= 3 ? Color.accentColor : Color.black.opacity(0.45),
                                in: Capsule())
                    .foregroundStyle(.white)
                    .padding(5)
            }
            Text(entry.code ?? entry.actorName ?? "")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - Tap targets: resolve, then show the real page

private struct RankingMovieTargetView: View {
    let entry: RankingBoardEntry
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = RankingMatchStore.shared
    @State private var card: MovieCard?
    @State private var failed = false
    @State private var attempt = 0
    @State private var showWeb = false

    var body: some View {
        Group {
            if let card {
                MovieDetailView(card: card)
            } else {
                VStack(spacing: 14) {
                    if failed {
                        Text("在 AVFan 里没搜到番号 \(entry.code ?? "")。可能站点还没收录这部。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("再试一次") { attempt += 1 }
                            .buttonStyle(.bordered)
                        Button("打开网页版搜索") { showWeb = true }
                            .buttonStyle(.bordered)
                    } else {
                        ProgressView()
                        Text("按番号匹配中…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(entry.code ?? "匹配")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showWeb) {
            InAppWebView(url: SiteClient.shared.searchURL(query: entry.code ?? "", st: "all"),
                         title: "网页搜索")
        }
        .task(id: attempt) {
            guard card == nil, let code = entry.code else { return }
            failed = false
            card = await store.resolveMovie(code: code, title: entry.title,
                                            coverURL: entry.coverURL,
                                            locale: settings.locale,
                                            ageCookie: settings.legalAgeCookie,
                                            force: attempt > 0)
            if card == nil { failed = true }
        }
    }
}

private struct RankingActorTargetView: View {
    let name: String
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = RankingMatchStore.shared
    @State private var resolved: (name: String, path: String)?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let resolved {
                CastProfileView(name: resolved.name, path: resolved.path)
            } else {
                VStack(spacing: 14) {
                    if failed {
                        Text("在 AVFan 里没搜到演员「\(name)」。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("再试一次") { attempt += 1 }
                            .buttonStyle(.bordered)
                    } else {
                        ProgressView()
                        Text("按名字匹配中…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) {
            guard resolved == nil else { return }
            failed = false
            resolved = await store.resolveActor(name: name, locale: settings.locale,
                                                ageCookie: settings.legalAgeCookie,
                                                force: attempt > 0)
            if resolved == nil { failed = true }
        }
    }
}
