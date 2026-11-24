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
    // Stage C: Metal post chain toggles (persisted by MPlayPostChain
    // itself; these @State values are the UI mirrors).
    @State private var postSDRToHDR = MPlayPostChain.shared.sdrToHDRLevel != .off
    @State private var postUpscaling = MPlayPostChain.shared.upscalingLevel != .off
    @State private var postInterpolation = MPlayPostChain.shared.frameInterpolationEnabled

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

            Section("画质增强（播放器后链）") {
                Toggle("SDR 转 HDR 色调映射", isOn: $postSDRToHDR)
                    .onChange(of: postSDRToHDR) { _, newValue in
                        MPlayPostChain.shared.setSDRToHDRLevel(newValue ? .low : .off)
                    }
                Toggle("超分辨率（×1.5）", isOn: $postUpscaling)
                    .onChange(of: postUpscaling) { _, newValue in
                        MPlayPostChain.shared.setVideoUpscalingLevel(newValue ? .low : .off, animated: true)
                    }
                Toggle("插帧（补间中间帧）", isOn: $postInterpolation)
                    .onChange(of: postInterpolation) { _, newValue in
                        MPlayPostChain.shared.setVideoFrameInterpolationEnabled(newValue)
                    }
                Text("MPlayKit 的 Metal 帧后处理链（自研实现，效果与原版 SenPlayer 的闭源着色器不做等同声明）。默认全部关闭，开启后增加 GPU 占用与功耗。杜比视界内容不经后链做逐帧色彩变换：与原版一致，打标后交系统呈现（见 DOLBY-PLAYBACK.md）。")
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

            Section("外部数据库") {
                NavigationLink("外部数据库") { ExternalLibrarySettingsView() }
                Text("与 AVDB 相同的外部数据库：启用并保存令牌后，详情页会按番号多查一份磁力 / ED2K 链接。默认服务器与 AVDB 一致。")
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
                Text("AVFan 是独立的个人侧载应用，不是 avfan.com 的官方客户端，也不做公开分发。抓取范围仅限公开 HTML 目录字段，且按页面按需请求。播放器使用 MPlayKit（libmpv，GPL-2.0-or-later；FFmpeg 为 LGPL-2.1 配置）。")
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


/// External database settings (build 38) — AVDB's page, ported:
/// enable toggle, server root, keychain token (blank keeps the
/// saved one), save / clear, and the plain-HTTP warning.
private struct ExternalLibrarySettingsView: View {
    @ObservedObject private var settings = ExternalLibrarySettings.shared
    @State private var baseURL = ""
    @State private var enabled = false
    @State private var token = ""
    @State private var message: String?
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("外部数据库") {
                Toggle("启用外部数据库", isOn: $enabled)
                TextField("服务器根地址", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("新令牌（留空保留已保存令牌）", text: $token)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                Text(settings.hasToken ? "令牌已保存（不显示内容）" : "未配置令牌，不会发送请求")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("保存设置") {
                    do {
                        try settings.save(baseURL: baseURL, enabled: enabled, replacementToken: token)
                        token = ""
                        baseURL = settings.baseURL
                        message = "设置已保存，后续查询立即使用新设置。"
                    } catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                }
                Button("清除已保存令牌", role: .destructive) { confirmClear = true }
                if let message { Text(message).font(.footnote) }
            } footer: {
                Text("令牌仅存于本机钥匙串，不会显示或复制。留空保存不会清除令牌。更换服务器须重新填写令牌，或先清除旧令牌。停用后不查询。")
            }
            Section("传输风险") {
                Text("HTTP 未加密：令牌与查询内容可能被网络中间人读取或篡改。默认服务器使用 HTTP；请仅在知晓风险时启用。所有重定向均拒绝，请直接填写最终服务器根地址。")
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("外部数据库")
        .onAppear {
            settings.refreshStatus()
            baseURL = settings.baseURL
            enabled = settings.enabled
        }
        .onDisappear { token = "" }
        .confirmationDialog("清除后外部数据库将停止查询，直到重新保存令牌。", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除令牌", role: .destructive) {
                settings.clearToken()
                message = "已清除令牌，不再发送外部数据库请求。"
            }
            Button("取消", role: .cancel) { }
        }
    }
}
