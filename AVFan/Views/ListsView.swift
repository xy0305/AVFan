import SwiftUI

struct ListsView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore

    var body: some View {
        List {
            Section("我的收藏") {
                if bookmarks.items.isEmpty {
                    Text("在详情页收藏影片后会显示在这里。只保存在本机。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(bookmarks.items) { item in
                    NavigationLink {
                        MovieDetailView(card: item.asCard)
                    } label: {
                        HStack(spacing: 12) {
                            CoverImage(url: item.coverURL)
                                .frame(width: 72, height: 48)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.code ?? item.pathID)
                                    .font(.subheadline.weight(.semibold))
                                Text(item.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        bookmarks.remove(id: bookmarks.items[index].pathID)
                    }
                }
            }

            Section("公开分类") {
                ForEach(CatalogShortcut.allCases) { item in
                    NavigationLink(item.title) {
                        CatalogListView(title: item.title, path: item.path(locale: AppSettings.shared.locale))
                    }
                }
            }
        }
        .navigationTitle("收藏与列表")
    }
}
