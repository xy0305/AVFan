import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var tab: AppTab = .home

    var body: some View {
        FloatingTabContainer(selection: $tab) {
            ZStack {
                tabRoot(.home) { NavigationStack { HomeView() } }
                tabRoot(.search) { NavigationStack { SearchView() } }
                tabRoot(.rankings) { NavigationStack { RankingsView() } }
                tabRoot(.library) { NavigationStack { ListsView() } }
                tabRoot(.settings) { NavigationStack { SettingsView() } }
            }
        }
        .background(AVFanTheme.pageBackground.ignoresSafeArea())
        .modifier(SceneLayoutReader())
        .fullScreenCover(isPresented: Binding(
            get: { !settings.ageConfirmed },
            set: { if $0 == false { settings.ageConfirmed = true } }
        )) {
            AgeGateView()
                .interactiveDismissDisabled()
                .environmentObject(settings)
        }
    }

    @ViewBuilder
    private func tabRoot<Content: View>(_ value: AppTab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .environment(\.appTab, value)
            .opacity(tab == value ? 1 : 0)
            .allowsHitTesting(tab == value)
            .accessibilityHidden(tab != value)
    }
}

struct AgeGateView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(AVFanTheme.accent)
            Text("你是否已经达到法定成年年龄？")
                .font(AVFanTheme.titleFont)
                .multilineTextAlignment(.center)
            Text("本应用仅供个人侧载使用，内容来自公开页面。确认后会在本地记住这次选择，并向站点发送与网页相同的成年确认 cookie（legal_age）。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                settings.ageConfirmed = true
            } label: {
                Text("是，我已经成年")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .glassChromeButton(prominent: true)
            Text("如果尚未成年，请直接关闭本应用。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .liquidGlassPage()
    }
}
