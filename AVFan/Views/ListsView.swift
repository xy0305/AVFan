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
                            CoverImage(url: item.coverURL, code: item.code)
                                .frame(width: 84, height: 56)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.code ?? item.pathID)
                                    .font(AVFanTheme.codeFont)
                                Text(item.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        bookmarks.remove(id: bookmarks.items[index].pathID)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AVFanTheme.pageBackground)
        .liquidGlassList()
        .navigationTitle("收藏")
    }
}
