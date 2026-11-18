import SwiftUI

/// Pageable full same-day FANZA list opened from the home 今日发行
/// chevron. Resolves AVFan matches per visible page; a tap force
/// retries a previous miss and stays here with 「AVFan 暂无此作」
/// when the title is still unlisted.
struct FanzaTodayListView: View {
    @ObservedObject var model: FanzaTodayHomeModel
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = RankingMatchStore.shared
    @State private var openCard: MovieCard?
    @State private var resolvedThrough = 0
    private let pageSize = 21

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.errorMessage, model.cards.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("重试") {
                        Task { await model.load(settings: settings, force: true) }
                    }
                    .font(.caption.weight(.semibold))
                }
                if model.loading && model.cards.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                }
                MovieGrid(
                    cards: model.cards,
                    columns: 3,
                    onSelect: { card in Task { await open(card) } },
                    onReachEnd: { Task { await loadNextVisible() } }
                )
                if model.loading && !model.cards.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
            .padding(.horizontal, AdaptiveLayout.horizontalPadding)
            .padding(.vertical, 12)
        }
        .background(AVFanTheme.pageBackground)
        .navigationTitle(model.sectionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openCard) { MovieDetailView(card: $0) }
        .task {
            if model.items.isEmpty && !model.loading {
                await model.load(settings: settings, force: false)
            }
            await resolveWindow(from: 0)
        }
        .onChange(of: store.movieIDs) { _, _ in
            model.refreshResolvedCards()
        }
        .refreshable { await model.load(settings: settings, force: true) }
        .overlay(alignment: .bottom) {
            if let message = model.statusMessage {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.82), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 108)
                    .onChange(of: model.missedMessage) { _, value in
                        guard value == message else { return }
                        Task {
                            try? await Task.sleep(nanoseconds: 2_200_000_000)
                            await MainActor.run {
                                if model.missedMessage == message { model.missedMessage = nil }
                            }
                        }
                    }
            }
        }
    }

    private func open(_ card: MovieCard) async {
        GlassHaptic.tap()
        if let hit = await model.open(card, settings: settings) {
            openCard = hit
        }
    }

    private func loadNextVisible() async {
        let start = resolvedThrough
        await resolveWindow(from: start)
    }

    private func resolveWindow(from start: Int) async {
        let count = pageSize
        await model.preResolveVisible(settings: settings, from: start, count: count)
        resolvedThrough = max(resolvedThrough, min(model.items.count, start + count))
    }
}
