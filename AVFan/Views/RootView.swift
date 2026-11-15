import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("首页", systemImage: "house.fill") }
            NavigationStack { SearchView() }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            NavigationStack { RankingsView() }
                .tabItem { Label("排行", systemImage: "chart.bar.fill") }
            NavigationStack { ListsView() }
                .tabItem { Label("收藏", systemImage: "bookmark.fill") }
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !settings.ageConfirmed },
            set: { if $0 == false { settings.ageConfirmed = true } }
        )) {
            AgeGateView()
                .interactiveDismissDisabled()
                .environmentObject(settings)
        }
    }
}

struct AgeGateView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 48))
                .foregroundStyle(AVFanTheme.accent)
            Text("你是否已经达到法定成年年龄？")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text("本应用仅供个人侧载使用，内容来自公开页面。确认后会在本地记住这次选择，并向站点发送与网页相同的成年确认 cookie（legal_age）。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                settings.ageConfirmed = true
            } label: {
                Text("是，我已经成年")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Text("如果尚未成年，请直接关闭本应用。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }
}
