import SwiftUI
import UIKit

enum AVFanTheme {
    /// Rose accent kept as AVFan's own identity; tab/chrome glass language follows AVDB.
    static let accent = Color(red: 0.86, green: 0.27, blue: 0.38)
    static let tabAccent = Color(red: 1.0, green: 138.0 / 255.0, blue: 61.0 / 255.0)
    static let tabWarm = Color(red: 20.0 / 255.0, green: 16.0 / 255.0, blue: 13.0 / 255.0)
    static let pageBackground = Color(red: 0.97, green: 0.96, blue: 0.94)
    static let heroRadius: CGFloat = 18
    static let cardRadius: CGFloat = 14
    static let sectionSpacing: CGFloat = 22
    static let gridSpacing: CGFloat = 14

    static let titleFont = Font.system(.title2, design: .rounded).weight(.bold)
    static let sectionFont = Font.system(.title3, design: .rounded).weight(.bold)
    static let codeFont = Font.system(.headline, design: .rounded).weight(.semibold)
    static let bodyFont = Font.system(.body, design: .default)
    static let captionFont = Font.system(.caption, design: .rounded)
}

enum AdaptiveLayout {
    static func columnCount(width: CGFloat, padding: CGFloat, spacing: CGFloat = 12) -> Int {
        let usable = max(0, min(width, contentMaxWidth) - padding * 2)
        let minimum: CGFloat = width < 600 ? 100 : 150
        return min(6, max(1, Int((usable + spacing) / (minimum + spacing))))
    }

    static var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    static var contentMaxWidth: CGFloat { 1100 }
    static var horizontalPadding: CGFloat { isPad ? 24 : 16 }
    static var gridPadding: CGFloat { isPad ? 20 : 12 }
}

private struct AvailableLayoutSizeKey: EnvironmentKey {
    static let defaultValue = CGSize(width: 375, height: 667)
}

extension EnvironmentValues {
    var availableLayoutSize: CGSize {
        get { self[AvailableLayoutSizeKey.self] }
        set { self[AvailableLayoutSizeKey.self] = newValue }
    }
}

struct SceneLayoutReader: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .environment(\.availableLayoutSize, geometry.size)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
