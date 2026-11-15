import Foundation
import Combine

final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()
    private let key = "avfan.bookmarks"
    private let defaults: UserDefaults

    @Published private(set) var items: [BookmarkItem] = []

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([BookmarkItem].self, from: data) {
            items = decoded.sorted { $0.addedAt > $1.addedAt }
        }
    }

    func contains(_ pathID: String) -> Bool {
        items.contains { $0.pathID == pathID }
    }

    func toggle(_ detail: MovieDetail) {
        if contains(detail.pathID) {
            items.removeAll { $0.pathID == detail.pathID }
        } else {
            let item = BookmarkItem(
                pathID: detail.pathID,
                href: detail.pageURL,
                code: detail.code,
                title: detail.displayTitle,
                coverURL: detail.coverURL,
                addedAt: Date()
            )
            items.insert(item, at: 0)
        }
        persist()
    }

    func remove(id: String) {
        items.removeAll { $0.pathID == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }
}
