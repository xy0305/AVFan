import SwiftUI

struct MovieGrid: View {
    let cards: [MovieCard]
    var columns: Int? = nil
    @Environment(\.availableLayoutSize) private var layoutSize

    private var grid: [GridItem] {
        let count = columns ?? max(2, AdaptiveLayout.columnCount(width: layoutSize.width, padding: AdaptiveLayout.gridPadding, spacing: 12))
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        LazyVGrid(columns: grid, spacing: AVFanTheme.gridSpacing) {
            ForEach(cards) { card in
                NavigationLink(value: card) {
                    MoviePosterCard(card: card)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct MoviePosterCard: View {
    let card: MovieCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                CoverImage(url: card.coverURL)
                    .aspectRatio(2.0/3.0, contentMode: .fill)
                    .clipped()
                    .liquidCover(cornerRadius: AVFanTheme.cardRadius)
                HStack(spacing: 4) {
                    if let badge = card.badges.first {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.62), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    if card.canPlay {
                        Text("可播放")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AVFanTheme.accent.opacity(0.92), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .padding(8)
            }
            Text(card.displayCode)
                .font(AVFanTheme.codeFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(card.displayTitle)
                .font(AVFanTheme.captionFont)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let date = card.date {
                Text(date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct FetchStatusBanner: View {
    let source: FetchSource?
    let error: String?
    var webURL: URL?
    var onOpenWeb: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                if webURL != nil, let onOpenWeb {
                    Button("在应用内网页打开", action: onOpenWeb)
                        .font(.caption.weight(.semibold))
                        .glassChromeButton()
                }
            } else if source == .wkWebView {
                Text("直连页面不完整或被拦截，已改用应用内浏览器会话解析。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
