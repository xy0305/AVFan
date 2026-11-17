import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var pan115: Pan115Settings
    @EnvironmentObject private var session: SiteSession
    @State private var showSiteLogin = false
    @State private var cleared = false
    @State private var imageCleared = false
    @State private var imageCacheSize = "计算中…"
    @State private var signingOut = false

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

            Section("封面") {
                Toggle("高清封面源", isOn: $settings.hqCoversEnabled)
                Text("默认开启：按番号从 DMM / FANZA 与 MGStage 官方图源取高清封面（与 AVDB 相同的来源与校验），取不到时用页面原封面。")
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

            Section("网站登录") {
                if session.isSignedIn {
                    HStack {
                        Text("当前账号")
                        Spacer()
                        Text(session.displayName.isEmpty ? "已登录" : session.displayName)
                            .foregroundStyle(.secondary)
                    }
                    Button(signingOut ? "正在退出…" : "退出登录") {
                        Task {
                            signingOut = true
                            await session.signOut(locale: settings.locale)
                            signingOut = false
                        }
                    }
                    .disabled(signingOut)
                    .foregroundStyle(.red)
                } else {
                    Button("登录 avfan 账号") { showSiteLogin = true }
                }
                Text("默认使用原生登录表单。真正的提交在网站登录页完成：应用会把账号填进去，验证码也在这个网页里输入。不会把 /sessions 当成接口来用，也不会和 115 登录混用。")
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
                LabeledContent("图片缓存", value: imageCacheSize)
                Button(imageCleared ? "图片缓存已清除" : "清除图片缓存") {
                    Task {
                        await ImageDiskCache.shared.clear()
                        imageCleared = true
                        imageCacheSize = "0 KB"
                    }
                }
            }

            Section("关于") {
                LabeledContent("版本", value: "1.2 (3)")
                Text("AVFan 是独立的个人侧载应用，不是 avfan.com 的官方客户端，也不做公开分发。抓取范围仅限公开 HTML 目录字段，且按页面按需请求。播放器使用 KSPlayer（GPL-3.0）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .task {
            let bytes = await ImageDiskCache.shared.totalSize()
            imageCacheSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        .background(AVFanTheme.pageBackground)
        .liquidGlassList()
        .navigationTitle("设置")
        .sheet(isPresented: $showSiteLogin) {
            SiteLoginView()
                .environmentObject(settings)
                .environmentObject(session)
        }
    }
}
