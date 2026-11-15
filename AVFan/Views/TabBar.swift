import SwiftUI
import UIKit

enum AppTab: Int, CaseIterable, Identifiable, Hashable {
    case home, search, rankings, library, settings
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .search: return "搜索"
        case .rankings: return "排行"
        case .library: return "收藏"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .search: return "magnifyingglass"
        case .rankings: return "trophy"
        case .library: return "bookmark"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class TabBarChrome: ObservableObject {
    @Published private(set) var searchDepth: [AppTab: Int] = [:]
    @Published private(set) var keyboardVisible = false

    func enterSearch(_ tab: AppTab?) { guard let tab else { return }; searchDepth[tab, default: 0] += 1 }
    func leaveSearch(_ tab: AppTab?) {
        guard let tab else { return }
        searchDepth[tab] = max(0, (searchDepth[tab] ?? 0) - 1)
    }
    func setKeyboard(_ visible: Bool) { if keyboardVisible != visible { keyboardVisible = visible } }

    nonisolated static func hidden(selected: AppTab, searchDepth: [AppTab: Int], keyboardVisible: Bool) -> Bool {
        keyboardVisible || (searchDepth[selected] ?? 0) > 0
    }
    func hidden(selected: AppTab) -> Bool { Self.hidden(selected: selected, searchDepth: searchDepth, keyboardVisible: keyboardVisible) }

    nonisolated static func keyboardCovers(endFrame: CGRect, screenHeight: CGFloat) -> Bool {
        endFrame.height > 120 && endFrame.minY < screenHeight - 1
    }
}

private struct AppTabKey: EnvironmentKey { static let defaultValue: AppTab? = nil }
private struct TabBarChromeKey: EnvironmentKey { static let defaultValue: TabBarChrome? = nil }
private struct SelectedAppTabKey: EnvironmentKey { static let defaultValue: AppTab? = nil }
extension EnvironmentValues {
    var tabBarChrome: TabBarChrome? {
        get { self[TabBarChromeKey.self] }
        set { self[TabBarChromeKey.self] = newValue }
    }
    var appTab: AppTab? {
        get { self[AppTabKey.self] }
        set { self[AppTabKey.self] = newValue }
    }
    var selectedAppTab: AppTab? {
        get { self[SelectedAppTabKey.self] }
        set { self[SelectedAppTabKey.self] = newValue }
    }
}

struct HidesFloatingTabBar: ViewModifier {
    @Environment(\.appTab) private var tab
    @Environment(\.tabBarChrome) private var chrome
    @State private var registered = false
    func body(content: Content) -> some View {
        content
            .onAppear { if !registered, let chrome { registered = true; chrome.enterSearch(tab) } }
            .onDisappear { if registered { registered = false; chrome?.leaveSearch(tab) } }
    }
}

struct KeyboardVisibilityReader: ViewModifier {
    let chrome: TabBarChrome
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let height = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? frame.maxY
                withAnimation(.easeInOut(duration: 0.22)) { chrome.setKeyboard(TabBarChrome.keyboardCovers(endFrame: frame, screenHeight: height)) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.easeInOut(duration: 0.22)) { chrome.setKeyboard(false) }
            }
    }
}

struct FloatingTabContainer<Content: View>: View {
    @Binding var selection: AppTab
    @StateObject private var chrome = TabBarChrome()
    private let content: Content
    init(selection: Binding<AppTab>, @ViewBuilder content: () -> Content) {
        _selection = selection; self.content = content()
    }
    var body: some View {
        content
            .environment(\.selectedAppTab, selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !chrome.hidden(selected: selection) {
                    AVFanNativeTabBar(selection: $selection)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: chrome.hidden(selected: selection))
            .modifier(KeyboardVisibilityReader(chrome: chrome))
            .environment(\.tabBarChrome, chrome)
    }
}

/// Dark warm glass tab bar, adapted from AVDB's native bar; AVFan uses five of its own tabs.
struct AVFanNativeTabBar: View {
    @Binding var selection: AppTab
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var buttons: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                let selected = selection == tab
                Button { selection = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 19, weight: selected ? .semibold : .regular))
                        Text(tab.title)
                            .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    }
                    .foregroundStyle(selected ? AVFanTheme.accent : Color.white.opacity(0.55))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background {
                        if selected {
                            Capsule().fill(Color.white.opacity(0.12)).padding(.vertical, 4)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("app.tab.\(tab.rawValue)")
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }.padding(.horizontal, 6)
    }

    private var fillOpacity: Double {
        reduceTransparency ? 1 : 0.66
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        buttons
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(AVFanTheme.tabWarm.opacity(fillOpacity))
                    shape.fill(AVFanTheme.accent.opacity(0.10))
                }
                .environment(\.colorScheme, .dark)
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            }
            .overlay { shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5) }
            .environment(\.colorScheme, .dark)
            .animation(.easeInOut(duration: 0.22), value: selection)
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
    }
}
