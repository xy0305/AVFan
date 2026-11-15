import SwiftUI

struct MovieGrid: View {
    let cards: [MovieCard]
    var columns: Int = 2

    private var grid: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: columns)
    }

    var body: some View {
        LazyVGrid(columns: grid, spacing: 12) {
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
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                CoverImage(url: card.coverURL)
                    .aspectRatio(3/2, contentMode: .fill)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let badge = card.badges.first {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.72), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            Text(card.displayCode)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(card.displayTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let date = card.date {
                Text(date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct CoverImage: View {
    let url: String?

    var body: some View {
        if let url, let parsed = URL(string: url) {
            AsyncImage(url: parsed) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder
                case .empty:
                    ZStack {
                        placeholder
                        ProgressView()
                    }
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .overlay {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
    }
}

struct FetchStatusBanner: View {
    let source: FetchSource?
    let error: String?
    var webURL: URL?
    var onOpenWeb: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                if webURL != nil, let onOpenWeb {
                    Button("在应用内网页打开", action: onOpenWeb)
                        .font(.caption.weight(.semibold))
                }
            } else if source == .wkWebView {
                Text("直连页面不完整或被拦截，已改用应用内浏览器会话解析。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
