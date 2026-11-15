import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var pan115: Pan115Settings
    @State private var showSiteLogin = false
    @State private var cleared = false

    var body: some View {
        Form {
            Section("内容语言") {
                Picker("语言", selection: $settings.locale) {
                    ForEach(SiteLocale.allCases) { locale in
                        Text(locale.label).tag(locale)
                    }
                }
                Text("目录页使用站点路径前缀。搜索固定走已验证的 /search?q=&st=all，不加语言前缀。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("年龄确认") {
                Toggle("已确认已达法定成年年龄", isOn: $settings.ageConfirmed)
                Text("确认后会在请求中附带 legal_age=1（与网站 cookie 一致），并记在本机。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("115 推送播放") {
                NavigationLink {
                    Pan115SettingsView()
                } label: {
                    HStack {
                        Text("115 离线设置")
                        Spacer()
                        Text(pan115.isConfigured ? "已配置" : "未配置")
                            .foregroundStyle(pan115.isConfigured ? .green : .secondary)
                    }
                }
                Text("115 登录凭据只保存在本应用的钥匙串里，不会与 avfan 网站登录混用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("网站") {
                Button("在应用内打开 avfan.com") {
                    showSiteLogin = true
                }
                Text("如需登录网站，请在这个内置网页里自行操作。应用不会去抓取登录接口或墙内数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("缓存") {
                Button(cleared ? "已清除" : "清除页面缓存") {
                    Task {
                        await SiteClient.shared.clearCache()
                        cleared = true
                    }
                }
            }

            Section("关于") {
                LabeledContent("版本", value: "1.1 (2)")
                Text("AVFan 是独立的个人侧载应用，不是 avfan.com 的官方客户端，也不做公开分发。抓取范围仅限公开 HTML 目录字段，且按页面按需请求。播放器使用 KSPlayer（GPL-3.0）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AVFanTheme.pageBackground)
        .liquidGlassList()
        .navigationTitle("设置")
        .sheet(isPresented: $showSiteLogin) {
            InAppWebView(url: URL(string: "https://avfan.com/\(settings.locale.rawValue)")!, title: "AVFan 网站")
        }
    }
}
