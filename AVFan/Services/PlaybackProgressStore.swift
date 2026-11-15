import Foundation

struct PlaybackProgress: Codable, Hashable {
    let movieID: String
    let time: TimeInterval
    let duration: TimeInterval
    let updatedAt: Date
}

enum LocalJSONStore {
    static func load<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum PlaybackProgressStore {
    private static let key = "avfan.playback.progress"

    static func progress(for movieID: String) -> PlaybackProgress? {
        let all = LocalJSONStore.load(key, as: [String: PlaybackProgress].self) ?? [:]
        return all[movieID]
    }

    static func save(movieID: String, time: TimeInterval, duration: TimeInterval) {
        guard time >= 5, duration > 30, time < duration - 15 else { return }
        var all = LocalJSONStore.load(key, as: [String: PlaybackProgress].self) ?? [:]
        all[movieID] = PlaybackProgress(movieID: movieID, time: time, duration: duration, updatedAt: Date())
        LocalJSONStore.save(all, key: key)
    }
}
