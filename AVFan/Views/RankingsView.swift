import SwiftUI

// Build 42/43: the rankings tab keeps ALL of AVFan's own boards and
// adds the five external boards ported from AVDB — DMM, JAV Ranking,
// MissAV, 中指通, JAVLibrary. (JavDB's own rankings were the ones the
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
    case dmm, javranking, missav, zhongzhitong, javlibrary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dmm: return "DMM"
        case .javranking: return "JAV Ranking"
        case .missav: return "MissAV"
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
            return [RankingTerm(id: "explore", label: "精选")]
        case .missav:
            return [RankingTerm(id: "today-hot", label: "今日热门"),
                    RankingTerm(id: "weekly-hot", label: "本周热门"),
                    RankingTerm(id: "monthly-hot", label: "本月热门")]
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
/// own boards first (NativeRankingsView, untouched), then the five
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

    private var loadKey: String { "\(source.rawValue)|\(term)|\(zztMonth)|\(loadAttempt)" }

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
        if source == .javlibrary && !javlibraryConfigured {
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                      spacing: 14) {
                ForEach(entries) { entry in
                    Button {
                        target = entry.isActor
                            ? .actor(entry.actorName ?? entry.title)
                            : .movie(entry)
                    } label: {
                        RankingGridCell(entry: entry)
                    }
                    .buttonStyle(.plain)
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
                var monthEntries = month.entries
                let covers = await ZhongZhiTongCatalog.feedCovers(term: zztMonth)
                if !covers.isEmpty {
                    for index in monthEntries.indices {
                        if let code = monthEntries[index].code,
                           let cover = covers[RankingMatchStore.key(for: code)] {
                            monthEntries[index].coverURL = cover
                        }
                    }
                }
                entries = monthEntries
                updatedText = "中指通月度精选 · 2019–2026 年全量"
            case .dmm, .javranking:
                let result = try await RankingFeedLoader.load(board: source.rawValue, term: term)
                entries = result.entries
                updatedText = result.generatedAt.map { "数据更新于 \(String($0.prefix(10)))" }
            case .missav:
                entries = try await MissAVRankings.load(term: term)
                updatedText = "实时抓取自 MissAV"
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
}

private struct RankingGridCell: View {
    let entry: RankingBoardEntry

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
                    // A board-provided cover loads directly (no HQ
                    // probing — that contention is what made covers
                    // slow); code-only entries keep the HQ pipeline.
                    CoverImage(url: entry.coverURL,
                               code: entry.coverURL == nil ? entry.code : nil)
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
