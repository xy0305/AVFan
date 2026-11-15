import SwiftUI

/// The site's public catalog categories （有码/无码/欧美/动漫/FC2/在线观看）.
/// These used to sit in a section at the bottom of the 收藏 (bookmarks)
/// page, where they didn't belong — bookmarks are the user's own list;
/// categories are public browsing and get their own tab (build 6).
struct CategoriesView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List {
            Section {
                ForEach(CatalogShortcut.allCases) { item in
                    NavigationLink {
                        CatalogListView(title: item.title, path: item.path(locale: settings.locale))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.icon)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(AVFanTheme.accent)
                                .frame(width: 28)
                            Text(item.title)
                                .font(.body.weight(.medium))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AVFanTheme.pageBackground)
        .liquidGlassList()
        .navigationTitle("类别")
    }
}

extension CatalogShortcut {
    var icon: String {
        switch self {
        case .censored: return "eye.slash"
        case .uncensored: return "eye"
        case .western: return "globe.americas"
        case .anime: return "wand.and.stars"
        case .fc2: return "video"
        case .watch: return "play.rectangle"
        }
    }
}
