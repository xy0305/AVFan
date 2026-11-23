# Build 59 — 播放器内核替换：KSPlayer → MPlayKit（libmpv + FFmpeg 8）

用户原话（2026-11-23）：「先使用 AVFan 换播放器内核，这个编译成 ipa 快」

## 与 AVDB Build 353 的关系

同一套还原：逆向规格 `~/workspace/p115-player-re/RE-REPORT.md`（115 播放器
APK 的 MPlayKit / libmpv + FFmpeg 8 静态融合内核）。AVDB 353 是「双内核
可切换、默认仍 KSPlayer」；AVFan 59 是**硬替换**（无开关、无回落），且
AVFan 的 IPA 构建快，所以先在 AVFan 落地验证同一套原生管线与 Swift 层，
再反哺 AVDB 的 CI 首跑判断。

- 原生管线：`scripts/mplaykit59/`（自 AVDB `scripts/mplaykit353/` 移植，
  版本钉与 sha256 一字未动：FFmpeg 8.0.1 / mpv 0.42.0 / libplacebo
  7.387.0 / dav1d 1.5.1 / libass 0.17.4 / freetype 2.13.3 / harfbuzz
  15.2.0 / fribidi 1.0.16 / xxHash 0.8.3），产物
  `Vendor/Libmpv.xcframework`（静态合并，见该目录 LINK-NOTES）。
- Swift 层：`AVFan/Services/MPlayKit/` 7 文件（自 AVDB 同名目录移植），
  另加四处扩展：`MPlayPlaybackEvent`/`onPlaybackEvent`、`videoSize()`、
  `MPlayProgress.cacheSpeed`、`setRate(_:)`。`MPlayKernel.swift` 在 AVFan
  缩减为单 case 描述（无内核开关，杜绝回落已删除的 KSPlayer）。

## 映射表（KSPlayer → MPlayKit）

| 原（KSPlayer 时代） | 现（Build 59） |
|---|---|
| `KSChromePlayer`（文件 + 类型） | `MPlayChromePlayer`（同文件改名、pbxproj 同 ID；UI/手势/续播逻辑不动） |
| `KSVideoPlayer.Coordinator` + `KSPlayerLayer` | `MPlayChromeCoordinator`（`Views/Player/MPlayEngine.swift`），内部持一个 `MPlayPlayer` core |
| `coordinator.onStateChanged/onFinish` + `playerLayer === layer` 身份守卫 | `onReady/onFailure/onEnded` 回调 + load generation 守卫；状态由既有 500 ms ticker 轮询 `state()/progress()` 折叠，终局边沿走 `onPlaybackEvent` |
| `AudioOwnedKSVideoPlayer`（UIViewRepresentable） | `AudioOwnedMPlayVideoView`：`audio.begin()` 仍在 core 创建之前；`MPlayVideoView.attach(player:)`；URL 变更在同一 core 上 `open` |
| `KSOptions`（headers/UA/referer/isAutoPlay/videoAdaptable） | `MPlayPlayer.open(url:headers:)` 的 http-header-fields；autoplay 恒真；画面模式走 mpv 属性（见下） |
| `player.play()/pause()` | `setPaused(false/true)` |
| `layer.seek(time:autoPlay:completion)` | `MPlayPlayer.seek`（completion 在 PLAYBACK_RESTART 触发）+ autoPlay 时清 pause |
| `player.playbackRate`（倍速） | mpv `speed` 属性（`setRate`），ready 与每 tick 重申 |
| `player.contentMode`（fit/fill/stretch） | fit: keepaspect=yes+panscan=0；fill: panscan=1.0；stretch: keepaspect=no |
| 吞吐标签（AVPlayerItem access-log 字节数） | mpv `cache-speed`（demuxer 缓存填充速率）；读不到（0）时隐藏，与原行为一致 |
| 视频尺寸回调（presentationSize / naturalSize） | mpv `width/height`（当前视频轨尺寸，evidence=.track） |
| `KSOptions.supportedInterfaceOrientations` | `OrientationLock.supportedMask`（AVFanApp delegate 读它） |
| KSPlayer 的 LogHandler 隐私日志 | 删除（引擎诊断走 MPlayDiagnostics 结构化事件） |
| 在线字幕：下载→解析→文字 overlay | 下载/校验路径**不变**（仍是 OnlineSubtitleModel 的加固下载，绝不让引擎碰远程字幕 URL）；解析后把已下载字节写本地临时文件 `sub-add` 给 libass 渲染；overlay 保留为兜底与位置编辑预览（见偏差 4） |
| 预告 stage `.ksPlayer` | `.mplayKit`（链路顺序不变：MPlayKit → AVPlayer → WKWebView → failed） |

调用点：Pan115PlayerView（115 播放）、WatchOnlinePlayerView（在线观看）、
MovieDetailView TrailerPlayerView（预告）三处全部换完；参数面不变
（progressID / supportsFramePreview / onPlaybackFailure /
managesOrientation / onSelectSource / onSelectEpisode /
publicSubtitleQuery / onVideoMetrics / resumeKey / startFromBeginning）。

## 偏差表

| # | 偏差 | 说明与后续路线 |
|---|---|---|
| 1 | **画中画（PiP）未实现** | 原 PiP 来自 KSAVPlayer 的 AVPictureInPictureController；libmpv render API 在 iOS 没有 PiP 通路。Build 59 不假装支持：dismantle 不再等 PiP 结束，直接 onStop → detach → close → audio.end；后台音频靠既有音频会话租约继续。后续路线二选一：① AVSampleBufferDisplayLayer 帧桥（重，且失去硬解直通）；② 特定源回落 AVPlayer。不在本版范围。 |
| 2 | 双 Surface 字幕面无 iOS 对应物 | 原版（Android）有独立 fp16/HDR 字幕 Surface；mpv/libass 在同一帧内合成字幕。本偏差与 AVDB 353 相同，`subtitles` 命令的 28-double 原始封送布局只实现可识别子集（sub-add 参数面）。 |
| 3 | 硬解/ TLS 平台替换 | MediaCodec → VideoToolbox；OpenSSL → SecureTransport。与 AVDB 353 相同。 |
| 4 | 在线字幕样式映射为近似值 | 引擎渲染激活时：offset → `sub-delay`（同号：正数延后）；字号 pt → `sub-font-size`（×3，锚点 18pt≈mpv 默认 55）；位置 y → `sub-pos`（×100）；x → `sub-align-x`（三等分 left/center/right）。ASS 特效由 libass 原生呈现（原 overlay 明确不支持）。写临时文件或 sub-add 失败时自动回落 overlay 渲染。 |
| 5 | 续播在 MPlayKit 路径的行为 | 续播逻辑（PlaybackResumeStore/Policy、>95% 或末 15 秒从头、从头 toast）全保留，走 ready 后 `engine.seek(autoPlay:)`。与 AVDB 353「MPlayKit 路径暂未接续播」不同，AVFan 的续播在 chrome 层、本来就与引擎无关，故完整保留。 |
| 6 | RE 未定名部分不复刻 | n0/n8/n10/n13/n18 无 Java 调用点、语义不可知；Playback$State 未命名下标仅下标等价（MPlayStateRaw）。与 AVDB 353 相同。ncnn 不引入。 |
| 7 | 音轨/字幕轨选择 UI | AVFan 此前就**没有**音轨/字幕轨选择 UI（全仓无此入口），不是本版删掉的。引擎侧能力已具备（`MPlayPlayer.selectTrack` + `mediaJSON()`），要加 UI 另行立项。 |
| 8 | LUT | AVFan 从来没有生效的 LUT 路径（seek 预览卡上的「原始画面 · 不含 LUT」是唯一残留文案，未动）。本版不引入 LUT。 |

## KSPlayer 残留清单

- 代码依赖：**零**。SwiftPM 包引用、product dependency、Frameworks 链接、
  全部 `import KSPlayer` 与引擎类型均已移除；`grep KSPlayer` 只剩注释与
  本文档（历史沿革说明）。
- `THIRD_PARTY/KSPlayer-GPL-3.0.txt` 许可证文件保留在仓库（历史归属，
  不再随包分发 KSPlayer 代码，可后续清理）。
- `MPlayKernel.swift` 为单 case 描述文件（见上），无功能残留。

## CI 首跑清单（本地无法编译 Swift / 无法冷构建 libmpv，以下必须首跑核）

1. `libmpv-353` 对应步（本仓为 build-ipa 单 job 内 Cache/Build/Assert 三步）：
   冷构建是否跑通——重点 freetype 的 cmake harfbuzz 探测、libplacebo/mpv
   在交叉环境下的 GL 探测；job timeout 已 90 → 300。
2. Swift 编译：`MPV_END_FILE_REASON_EOF` 常量名（与 ERROR 同枚举对称推得，
   未编译验证）；C 枚举/GL 常量导入形态；`MPlayChromeCoordinator` 与
   chrome 的 @MainActor 隔离。
3. pbxproj：Libmpv.xcframework 的 Frameworks + Embed & Sign、显式系统
   框架/库清单（LINK-NOTES）是否足够/多余。
4. 真机：115 播放起播与续播、预告三级链第一级、倍速、seek 落点、
   在线字幕 sub-add 渲染与样式映射、横竖屏锁、后台音频。
