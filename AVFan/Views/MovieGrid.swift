import SwiftUI

struct MovieGrid: View {
    let cards: [MovieCard]
    var columns: Int? = nil
    /// When set, cells are buttons reporting the tap instead of value
    /// NavigationLinks. Hosts that are themselves PUSHED views (catalog
    /// lists, news articles) must use this with their own item-based
    /// destination: a value link tapped in a pushed view, resolved by a
    /// destination registered at the tab root, pops back to the ROOT —
    /// skipping the host — on this OS (builds 6/7 recordings). Root-hosted
    /// grids (search, rankings) keep value links; their host IS the
    /// registration owner and they pop correctly.
    var onSelect: ((MovieCard) -> Void)? = nil
    /// Fired when the last card scrolls into view (infinite scroll hook).
    var onReachEnd: (() -> Void)? = nil
    @Environment(\.availableLayoutSize) private var layoutSize

    private var grid: [GridItem] {
        let count = columns ?? max(2, AdaptiveLayout.columnCount(width: layoutSize.width, padding: AdaptiveLayout.gridPadding, spacing: 12))
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    /// Append the next page when the user is still a few cards away from
    /// the end, so the append lands during scrolling — not in the middle
    /// of a tap on the last rows (which shifted the grid under the finger
    /// and sent taps to the wrong cover).
    private var prefetchID: String? {
        cards.dropFirst(max(0, cards.count - 6)).first?.pathID
    }

    var body: some View {
        LazyVGrid(columns: grid, spacing: AVFanTheme.gridSpacing) {
            ForEach(cards) { card in
                Group {
                    if let onSelect {
                        // Same cell construction as the home rails
                        // (HomePosterGrid), which never misdelivered a tap:
                        // press style + explicit content shape + full-width
                        // frame instead of a bare .plain button (build 11).
                        Button { onSelect(card) } label: {
                            MoviePosterCard(card: card)
                        }
                        .buttonStyle(HomePressStyle(scale: 0.97, spring: true))
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                    } else {
                        NavigationLink(value: card) {
                            MoviePosterCard(card: card)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onAppear {
                    if card.pathID == prefetchID { onReachEnd?() }
                }
            }
        }
    }
}

struct MoviePosterCard: View {
    let card: MovieCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // No text overlays on the cover (build 14, owner's call):
            // the site's badge pills （可播放 / 24小时磁链 …) covered the
            // artwork on every small card.
            CoverImage(url: card.coverURL, code: card.code, registryPathID: card.pathID)
                .aspectRatio(2.0/3.0, contentMode: .fill)
                .clipped()
                .liquidCover(cornerRadius: AVFanTheme.cardRadius)
            Text(card.displayCode)
                .font(AVFanTheme.codeFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
            // Every card reserves the same text height (two title lines and
            // a date line, filled or not). Mixed heights made LazyVGrid's
            // row estimates wrong, so appending a page — or realizing rows
            // while tapping — corrected the scroll offset and the grid
            // visibly jumped under the user's finger.
            Text(card.displayTitle)
                .font(AVFanTheme.captionFont)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
            Text(card.date ?? "")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(height: 14, alignment: .leading)
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

