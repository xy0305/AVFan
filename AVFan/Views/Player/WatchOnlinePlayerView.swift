import SwiftUI

/// Plays a media URL extracted from avfan public HTML (no JavDB /api/ sources).
struct WatchOnlinePlayerView: View {
    let title: String
    let url: URL
    var headers: [String: String] = [:]
    var resumeKey: String? = nil
    var startFromBeginning: Bool = false

    var body: some View {
        MPlayChromePlayer(
            url: url,
            title: title,
            subtitle: "在线观看",
            headers: headers,
            publicSubtitleQuery: title,
            resumeKey: resumeKey,
            startFromBeginning: startFromBeginning
        )
        .background(PlaybackOrientationHost().allowsHitTesting(false))
    }
}
