import KSPlayer
import SwiftUI
import UIKit

final class AVFanAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : KSOptions.supportedInterfaceOrientations
    }
}

@main
struct AVFanApp: App {
    @UIApplicationDelegateAdaptor(AVFanAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(AppSettings.shared)
                .environmentObject(BookmarkStore.shared)
                .environmentObject(Pan115Settings.shared)
                .tint(AVFanTheme.accent)
                .preferredColorScheme(.light)
                .liquidGlassChrome()
        }
    }
}
