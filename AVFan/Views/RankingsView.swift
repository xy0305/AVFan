import SwiftUI

// Build 42: the rankings tab carries ONLY the five external boards the
// owner picked — DMM, JAV Ranking, MissAV, 中指通, JAVLibrary — ported
// from AVDB. AVFan's own ranking pages are gone. Entries are keyed by
// code; tapping one resolves the code against AVFan's own search and
// opens the AVFan detail page (RankingMatchStore caches resolutions
// on disk and pre-resolves the visible list in the background).

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
            return [RankingTerm(id: "2026-10", label: "2026 年 10 月"),
                    RankingTerm(id: "2026-09", label: "2026 年 9 月")]
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

struct RankingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = RankingMatchStore.shared
    @ObservedObject private var external = ExternalLibrarySettings.shared
    @State private var source: RankingSource = .dmm
    @State private var term: String = "daily"
    @State private var entries: [RankingBoardEntry] = []
    @State private var updatedText: String?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var target: RankingTarget?
    @State private var loadAttempt = 0

    private var loadKey: String { "\(source.rawValue)|\(term)|\(loadAttempt)" }

    private var javlibraryConfigured: Bool {
        external.enabled && !(external.token() ?? "").isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RankingSource.allCases) { item in
                            chip(title: item.title, selected: source == item) {
                                source = item
                                term = item.terms[0].id
                            }
                        }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(source.terms) { item in
                            chip(title: item.label, selected: term == item.id) {
                                term = item.id
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
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    Button {
                        target = entry.isActor
                            ? .actor(entry.actorName ?? entry.title)
                            : .movie(entry)
                    } label: {
                        RankingRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    Divider()
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
            case .dmm, .javranking, .zhongzhitong:
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

private struct RankingRow: View {
    let entry: RankingBoardEntry

    var body: some View {
        HStack(spacing: 12) {
            Text("\(entry.rank)")
                .font(.headline)
                .foregroundStyle(entry.rank <= 3 ? Color.accentColor : Color.secondary)
                .frame(width: 30, alignment: .center)
            if entry.isActor {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 54, height: 72)
            } else {
                CoverImage(url: entry.coverURL, code: entry.code)
                    .frame(width: 54, height: 72)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 4) {
                if let code = entry.code {
                    Text(code)
                        .font(.subheadline.weight(.semibold))
                }
                Text(entry.title)
                    .font(.subheadline)
                    .lineLimit(2)
                if !entry.actresses.isEmpty {
                    Text(entry.actresses.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
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
