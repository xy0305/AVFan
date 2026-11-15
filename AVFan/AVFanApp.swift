import SwiftUI

@main
struct AVFanApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(AppSettings.shared)
                .environmentObject(BookmarkStore.shared)
                .environmentObject(Pan115Settings.shared)
                .tint(AVFanTheme.accent)
        }
    }
}

enum AVFanTheme {
    static let accent = Color(red: 0.86, green: 0.27, blue: 0.38)
}
