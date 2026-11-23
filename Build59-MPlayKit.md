# Build 59 — 播放器内核替换：KSPlayer → MPlayKit（libmpv + FFmpeg 8）

用户原话（2026-11-23）：「先使用 AVFan 换播放器内核，这个编译成 ipa 快」

## 与 AVDB Build 353 的关系

同一套还原：逆向规格 `~/workspace/p115-player-re/RE-REPORT.md`（115 播放器
APK 的 MPlayKit / libmpv + FFmpeg 8 静态融合内核），后叠加
`~/workspace/p115-player-re/IOS-FINDINGS.md`（SenPlayer iOS 版符号级
逆向，含原版 meson 构建参数原文与版本串）。AVDB 353 是「双内核
可切换、默认仍 KSPlayer」；AVFan 59 是**硬替换**（无开关、无回落），且
AVFan 的 IPA 构建快，所以先在 AVFan 落地验证同一套原生管线与 Swift 层，
再反哺 AVDB 的 CI 首跑判断。

- 原生管线：`scripts/mplaykit59/`（自 AVDB `scripts/mplaykit353/` 移植）。
  移植当初版本钉与 sha256 与 353 一字未动；**本轮已按 IOS-FINDINGS
  修正**：mpv 0.42.0 → **0.41.0**（iOS 二进制 `mpv v0.41.0` 直证，
  §5）、补构建 **uchardet 0.0.8 + lcms2 2.16** 并打开 mpv 两开关
  （原版 meson 参数原文，§3.1）；libplacebo 7.387.0 保留（0.41 下限
  仅 >= 6.338.2）。AVDB 353 侧待同步同一修正。产物
  `Vendor/Libmpv.xcframework`（静态合并，见该目录 LINK-NOTES）。
- Swift 层：`AVFan/Services/MPlayKit/` 7 文件（自 AVDB 同名目录移植），
  另加四处扩展：`MPlayPlaybackEvent`/`onPlaybackEvent`、`videoSize()`、
  `MPlayProgress.cacheSpeed`、`setRate(_:)`。`MPlayKernel.swift` 在 AVFan
  缩减为单 case 描述（无内核开关，杜绝回落已删除的 KSPlayer）。本轮已
  按 mpv 0.41.0 头文件逐项核对（与 0.42 的差异只有 API 版本 2.5↔2.6
  与 node 命令 `_name` 键，本层不受影响），无需改代码，核对记录在
  `MPlayPlayer.swift` 头部注释。

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
| 在线字幕：下载→解析→文字 overlay | 下载/校验路径**不变**（仍是 OnlineSubtitleModel 的加固下载，绝不让引擎碰远程字幕 URL）；解析后把已下载字节写本地临时文件 `sub-add` 给 libass 渲染；overlay 保留为兜底与位置编辑预览（见偏差 5） |
| 预告 stage `.ksPlayer` | `.mplayKit`（链路顺序不变：MPlayKit → AVPlayer → WKWebView → failed） |

调用点：Pan115PlayerView（115 播放）、WatchOnlinePlayerView（在线观看）、
MovieDetailView TrailerPlayerView（预告）三处全部换完；参数面不变
（progressID / supportsFramePreview / onPlaybackFailure /
managesOrientation / onSelectSource / onSelectEpisode /
publicSubtitleQuery / onVideoMetrics / resumeKey / startFromBeginning）。

## 偏差表

| # | 偏差 | 说明与后续路线 |
|---|---|---|
| 1 | **画中画（PiP）未实现** | 本版仍未实现，**列为下一版第一项**。原版路线已查明（IOS-FINDINGS §一）：自研 vo `frame_output` 输出 CVPixelBuffer → FrameStore/FrameOutputScheduler 调度 → 包 CMSampleBuffer 入队 AVSampleBufferDisplayLayer；`MPlayKit.PictureInPictureController` 实现 AVPictureInPictureSampleBufferPlaybackDelegate 全套方法与时间同步；字幕为独立 CALayer，进 PiP 时移入 PiP 宿主视图、按 PiP 渲染尺寸单独设定。本版现状：dismantle 不再等 PiP 结束，直接 onStop → detach → close → audio.end；后台音频靠既有音频会话租约继续。此前「libmpv render API 在 iOS 没有 PiP 通路」的说法**已被推翻、删除**——原版主显示链根本不用 render API，PiP 是这条像素帧管线的自然延伸，且该路线不丢硬解直通（VideoToolbox 帧以 CVPixelBuffer 原生流动）。工作量判断见 IOS-FINDINGS §1.2。 |
| 2 | **显示架构与原版不同**（本轮新增申报） | 原版是 `-Dgl=disabled` + 自研 vo `frame_output` 像素帧管线（CVPixelBuffer → CMSampleBuffer → AVSampleBufferDisplayLayer）；我们是 GL render API（mpv plain-gl + `MPlayVideoView` 的 CAEAGLLayer + mpv_render_context）。这是比 PiP 更底层的架构差异，与偏差 1 同批：下一版显示管线重构时一并处理。本轮管线保留 GL 正是为保住现有显示层（逐项对照写在管线脚本 docstring）。 |
| 3 | 独立字幕层架构未复刻（原第 2 条改写） | 原版 iOS 有独立字幕层：字幕是独立 CALayer（另有 Metal 字幕层）、可在内嵌/PiP 宿主间迁移、渲染尺寸与视频帧解耦、带 HDR 增益管理——这正是安卓双 Surface 字幕面在 iOS 的对应物。此前文档写「iOS 无对应物」是错的，现予改掉。本版暂以 mpv/libass 同帧合成替代；`subtitles` 命令的 28-double 原始封送布局只实现可识别子集（sub-add 参数面）。字幕层的渲染者分工（核心 libass 位图 vs Swift/Metal）原版符号面未定案（IOS-FINDINGS §6）。 |
| 4 | 硬解 / TLS 平台替换 | MediaCodec → VideoToolbox；OpenSSL → SecureTransport。与 AVDB 353 相同。 |
| 5 | 在线字幕样式映射为近似值 | 引擎渲染激活时：offset → `sub-delay`（同号：正数延后）；字号 pt → `sub-font-size`（×3，锚点 18pt≈mpv 默认 55）；位置 y → `sub-pos`（×100）；x → `sub-align-x`（三等分 left/center/right）。ASS 特效由 libass 原生呈现（原 overlay 明确不支持）。写临时文件或 sub-add 失败时自动回落 overlay 渲染。 |
| 6 | 续播在 MPlayKit 路径的行为 | 续播逻辑（PlaybackResumeStore/Policy、>95% 或末 15 秒从头、从头 toast）全保留，走 ready 后 `engine.seek(autoPlay:)`。与 AVDB 353「MPlayKit 路径暂未接续播」不同，AVFan 的续播在 chrome 层、本来就与引擎无关，故完整保留。 |
| 7 | RE 未定名部分不逐一复刻（原第 6 条改写） | n8/n10/n13 在 iOS 侧均有正式命名的对应 API（`intProperty` / `setSpeed`·`setVolume` 系 / `stringProperty` + `EngineState`，IOS-FINDINGS §2.3），说明它们是安卓侧未接线、**并非语义不可知**；本版以属性访问面覆盖其功能，不单独复刻门面方法。n0 无对应物（功能由 coreVersion/ffmpegVersion 等只读属性覆盖）、n18 无一对一对应（iOS 为 source 作用域 async 方法群，属同位演化、推断不定案），仍不复刻。Playback$State 未命名下标仅下标等价（MPlayStateRaw）；iOS 的 EngineState 给出了完整命名字段集，未命名字段的候选语义可由此反推，但不逐下标定案。ncnn 不引入（iOS 侧亦 0 命中，其图像增强线是 Metal 原生）。 |
| 8 | 音轨/字幕轨选择 UI | AVFan 此前就**没有**音轨/字幕轨选择 UI（全仓无此入口），不是本版删掉的。引擎侧能力已具备（`MPlayPlayer.selectTrack` + `mediaJSON()`），要加 UI 另行立项。 |
| 9 | LUT | AVFan 从来没有生效的 LUT 路径（seek 预览卡上的「原始画面 · 不含 LUT」是唯一残留文案，未动）。本版不引入 LUT。 |
| 10 | 缓存数值是我方取值（本轮新增） | 默认选项 `demuxer-max-bytes=256MiB` / `demuxer-max-back-bytes=128MiB` 是**我方取值**。原版 iOS 是 CachePolicy 分段缓存模型（capacity / directory / prefetchBytes / seconds / segmentBytes / segments），具体数值是代码常量、二进制里不可恢复（IOS-FINDINGS §3.2/§6），不得把这两个数字当作原版参数引用；分段缓存模型本身亦未复刻。 |
| 11 | 空间音频线未复刻（本轮新增申报） | 原版有整条 MPlaySpatial 线：`MPlaySpatial.framework`（bundle id org.mplaykit.spatial，Rust 实现）以 NOTICE 钉版的 LibTrueHD / LibDTSX 开源组件做 TrueHD / DTS:X 对象音频解码，经 SpatialDecoder/ObjectAudioRenderer 按 5.1.2–9.1.6 布局渲染；核心另有自研 ao `audio_relay` 把音频编码为 APAC 7.1.4、经内存 HLS 喂 AVPlayer 借系统空间音频/Atmos 输出，并以静默 Atmos 流保活输出通路（IOS-FINDINGS §四）。我们完全未复刻，此前两份 Build 文档只字未提，本轮补申报。评估：与 AVFan 的内容场景关联低（115 常规 AAC/AC3/DTS 音轨不走对象音频路径，TrueHD/DTS:X 母带级音轨是少数场景），**本版只申报、不实现**；若日后立项，应按 FFmpegKit.bundle NOTICE 的钉版引入同一批开源组件 + 复刻接线层，而非逆向重写。 |
| 12 | Metal 图像后链未复刻（本轮新增申报） | 原版 FrameStore 持有 MetalSDRToHDRMapper / MetalHDRVividMapper / MetalSpatialUpscaler / VideoFrameInterpolator / MetalVideoDeinterlacer：SDR→HDR、HDRVivid、空间超分、插帧、去隔行五件均未复刻，此前未申报、本轮补上。其中 SDR→HDR 是 CVPixelBuffer 域的帧后 Metal LUT 变换（sdr-hdr-\*.metallib 只有 `pkFrameKernel0` 一个 kernel），生效域是帧后处理而非 vo 内 libplacebo tone-mapping；libplacebo 在原版 iOS 更像编入而未走（桌面共用构建），我们的 libplacebo 只活在 GL render 域内，分工与原版不同（IOS-FINDINGS §3.2）。 |
| 13 | 预加载非接管制（本轮新增） | 原版 iOS 的预加载是完整 Player 实例 + `promotePreloadedPlayback` 接管制：音轨/字幕/音量/起播位置一并交接，PiP 控制器还能在实例间转移（IOS-FINDINGS §2.5）。我们只是用相同 options 新建实例、共享 GL 上下文预热（`MPlayPlayer.makePreloadedPlayer`），媒体状态不共享、无接管语义；且「共享 GL 上下文」这一形态建立在我们的 GL 显示架构上，原版并无此前提。 |
| 14 | 其余未复刻的原版面（集中申报，本轮新增） | 字幕翻译/实时字幕子系统、自定义流协议（`registerStreamProtocol`）、光盘支持（`mplay::DiscSession` / MediaInfo.disc）、NowPlaying 集成、VideoToolbox 故障切换（`beginDecoderSwitch` / `recoverVideoToolbox`）、显示匹配（帧率/动态范围 display criteria）、Dolby Vision RPU 解析与 P5 色彩校正（`dovi-fel` / `dovi-fel-hwdec`）——均未复刻，集中申报在此，避免被误认为已对齐（IOS-FINDINGS §2.5/§3.2）。与之相关：管线侧 libavdevice/avfoundation 与原版 meson 参数有差异（原版 enabled），因无设备/光盘源需求暂不补，记录在案。 |

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
   在交叉环境下的 GL 探测、新增 uchardet（cmake）/lcms2（meson）两 stage
   的 .pc 是否落进 prefix 并被 mpv 的 dependency() 找到（本轮新钉，
   IOS-FINDINGS §3.1 对齐项）；job timeout 已 90 → 300。
2. Swift 编译：C 枚举/GL 常量导入形态；`MPlayChromeCoordinator` 与
   chrome 的 @MainActor 隔离。（`MPV_END_FILE_REASON_EOF` 已销项：
   mpv 0.41.0 client.h 直证存在且 =0，与 ERROR 同枚举，见
   `MPlayPlayer.swift` 头部核对记录。）
3. pbxproj：Libmpv.xcframework 的 Frameworks + Embed & Sign、显式系统
   框架/库清单（LINK-NOTES）是否足够/多余。
4. 真机：115 播放起播与续播、预告三级链第一级、倍速、seek 落点、
   在线字幕 sub-add 渲染与样式映射、横竖屏锁、后台音频。
