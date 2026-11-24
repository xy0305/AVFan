# Build 59 — 播放器内核替换：KSPlayer → MPlayKit（libmpv + FFmpeg 8）+ 全量还原

用户原话（2026-11-23）：「先使用 AVFan 换播放器内核，这个编译成 ipa 快」；
同日晚间拍板「全部还原」：iOS 侧逆向（IOS-FINDINGS）里所有与播放有关的
内容逐项实施，不再保留打包的「集中申报」。

## 与 AVDB Build 353 的关系

同一套还原：逆向规格 `~/workspace/p115-player-re/RE-REPORT.md`（115 播放器
APK 的 MPlayKit / libmpv + FFmpeg 8 静态融合内核），后叠加
`~/workspace/p115-player-re/IOS-FINDINGS.md`（SenPlayer iOS 版符号级
逆向，含原版 meson 构建参数原文与版本串）。AVDB 353 是「双内核
可切换、默认仍 KSPlayer」；AVFan 59 是**硬替换**（无开关、无回落），且
AVFan 的 IPA 构建快，所以先在 AVFan 落地验证同一套原生管线与 Swift 层，
再反哺 AVDB 的 CI 首跑判断。

- 原生管线：`scripts/mplaykit59/`（自 AVDB `scripts/mplaykit353/` 移植）。
  版本钉按 IOS-FINDINGS 修正：mpv **0.41.0**（iOS 二进制 `mpv v0.41.0`
  直证）、**uchardet 0.0.8 + lcms2 2.16**、GL 已按原版关闭
  （`-Dgl=disabled`，全量还原阶段 A）。AVDB 353 侧待同步同一修正。
  产物 `Vendor/Libmpv.xcframework`（静态合并，见该目录 LINK-NOTES）。
- Swift 层：`AVFan/Services/MPlayKit/`，自内核替换的 7 文件扩展为完整
  还原面（帧管线、PiP、Metal 后链、Dolby Vision、空间音频、流协议、
  字幕/翻译、捕获、扩展 API 等，逐项见下表）。已按 mpv 0.41.0 头文件
  逐项核对，核对记录在各文件头部注释。

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
| 在线字幕：下载→解析→文字 overlay | 下载/校验路径**不变**（仍是 OnlineSubtitleModel 的加固下载，绝不让引擎碰远程字幕 URL）；解析后把已下载字节写本地临时文件 `sub-add` 给 libass 渲染；overlay 保留为兜底与位置编辑预览 |
| 预告 stage `.ksPlayer` | `.mplayKit`（链路顺序不变：MPlayKit → AVPlayer → WKWebView → failed） |

调用点：Pan115PlayerView（115 播放）、WatchOnlinePlayerView（在线观看）、
MovieDetailView TrailerPlayerView（预告）三处全部换完；参数面不变
（progressID / supportsFramePreview / onPlaybackFailure /
managesOrientation / onSelectSource / onSelectEpisode /
publicSubtitleQuery / onVideoMetrics / resumeKey / startFromBeginning）。

## 全量还原逐项状态（IOS-FINDINGS 播放相关条目 × 状态）

状态口径：**landed** = 代码落地、落点明确；**partial** = 主体落地但有
明示的缺口；**blocked** = 做不到且证据在案。本地无 Xcode/Swift/Cargo
工具链，全部代码只做过静态自检，**没有声称编译或运行验证过**；
真机/CI 首跑清单见文末。

### 阶段 A — 像素帧显示管线

| 条目 | 状态 | 落点 / 证据 |
|---|---|---|
| 自研 vo `frame_output`（CVPixelBuffer 经 C 回调交宿主） | landed | `scripts/mplaykit59/patches/0001-vo-frame-output.patch`（对 pristine mpv 0.41.0 树 git-diff 生成、`git apply --check` 两次干净）；构建脚本按 sha256 戳幂等应用 |
| 关 GL（原版 meson `-Dgl=disabled`） | landed | build_libmpv.py 构建参数对齐；libplacebo 保留为 mpv 硬依赖、关 vulkan/opengl 后端；modulemap 去 OpenGLES |
| FrameStore / FrameOutputScheduler（帧队列、时间戳、丢帧） | landed | `MPlayFrameOutput.swift`：store 双通道（视频/字幕）+ scheduler（CMSampleBuffer 入队、控制时间基、层失败恢复、黑帧） |
| AVSampleBufferDisplayLayer 显示 View + 时间同步 | landed | `MPlayVideoView.swift`（layerClass 即显示层；nudge 节奏对时基）；GL 版 `MPlayRenderContext.swift` 已删除，无双路 |
| 字幕独立 CALayer（与视频帧解耦、渲染尺寸独立） | landed | vo 字幕通道（BGRA 位图）→ `MPlaySubtitleLayer.swift`；渲染尺寸经 sink 覆盖值与视频尺寸解耦（`setSubtitleRenderSize`） |

### 阶段 B — 画中画

| 条目 | 状态 | 落点 / 证据 |
|---|---|---|
| AVPictureInPictureController + SampleBufferPlaybackDelegate 全套 | landed | `MPlayPictureInPicture.swift`（ContentSource(sampleBufferDisplayLayer:)、播放委托与控制器委托全套、音频中断恢复） |
| Player 侧时间同步 / PiP 状态面（start/stop/transfer/sync/setCanStart…AutomaticallyFromInline） | landed | 同上 + `MPlayPlayer` PiP 相关面；chrome 顶栏 PiP 按钮在 pipPossible‖pipActive 时显示 |
| 进 PiP 时字幕层迁移 | partial | 采样缓冲 PiP 没有系统宿主视图：字幕层保持挂在显示层上（随 PiP 窗口走），迁移的是**渲染尺寸**（pictureInPictureSubtitleRenderSize 语义）；字面「移入宿主视图」仅在宿主提供视图时走 `moveSubtitleLayerToPictureInPictureHost` |
| PiP 控制器在预加载接管时转移 | landed | `MPlayVideoView.attach` 的 PiP 活跃分支：sink 与控制器 player 引用切到接管实例、显示层不换手；dismantle 在 PiP 活跃时推迟拆解（恢复 KSPlayer 时代规则） |

### 阶段 C — Metal 后链 + Dolby Vision

| 条目 | 状态 | 落点 / 证据 |
|---|---|---|
| SDR→HDR 帧后变换 | landed（架构同位、效果非等同） | `MPlayPostChain.metal` `pkSDRToHDRKernel0` + `MPlayPostChain.swift`；生效域为帧后（store 与 scheduler 之间），与原版口径一致。**着色器是我方实现，与原版闭源 sdr-hdr-\*.metallib 不声称效果等同**（只查过其文件名/符号，未反编译） |
| 空间超分 | landed（同上口径） | `pkUpscaleKernel0`（Lanczos-2），管线位置与开关面对齐 |
| 插帧 | landed（同上口径） | `pkMotionKernel0` + `pkInterpKernel0`（块匹配运动估计 + 中间帧合成），忙时丢帧策略 |
| HDRVivid | partial | 开关面在位（与 SDR→HDR 同层 pass 选择），无独立 Vivid 曲线实现，文档明示 |
| 去隔行（MetalVideoDeinterlacer）/ MetalPreviewScaler | blocked（不立项级） | 原版符号在案；我方 vo 输出为逐行帧、无隔行源场景，PreviewReader 走 mpv SW 缩放。证据：IOS-FINDINGS §3.2 符号存在，但 AVFan 无隔行内容来源——列 blocked 而非假装 |
| DV RPU 解析（reshaping / MMR / polynomial / NLQ） | landed（组件） | `MPlayDolbyVision.swift` `MPlayDoviRPU`：逐字段对 FFmpeg 8.0.1 `libavcodec/dovi_rpudec.c` 实读核对（增量 pivot、poly/MMR 段、NLQ、DM 颜色元数据）。限定：use-prev RPU 只解头、linear-interp 段按 FFmpeg 口径拒绝、扩展块不解、CRC 不验。**播放中不直接喂字节**：mpv 客户端 API 不导出原始 RPU，解析器消费宿主提供的 RPU 数据；profile/level/FEL 状态走轨道属性实时读取 |
| DolbyP5ColorCorrection 类型 + Profile 5 校正 | landed（常量来源明示） | 类型形状按符号反射复刻（Map{profile5, yccToRGB, yccOffset, rgbToLMS}、convert(i:p:t:map:)）；profile5 常量为公开的 ITU-R BT.2124 IPT 矩阵、代码内求逆组合——**原版烘焙常量未提取（需反汇编），不声称数值等同** |
| P5 校正在 Metal 后链（与 SDR→HDR 同层） | landed | `pkDoviP5Kernel0`（IPT 重建 → PQ EOTF → BT.2020 PQ 重编码），与色调 pass 互斥选择；视图按 1 秒节奏刷新链的 dolbyProfile；设置页开关（默认开） |
| FEL 标记（dovi-fel / dovi-fel-hwdec 等价物） | landed（标记面） | `MPlayPlayer.setDolbyVisionFELHardwareDecode`（开启时钉 hwdec=videotoolbox）+ `dolbyVisionState`（profile/level/FEL 推断） |
| FEL 双层合成完整等价 | blocked | 证据：原版 fork 有 `demux/dovi_split.c` / `f_dovi_rpu` / BSF 依赖，且其自身日志显示 BSF 不可用时回落基底渲染；stock mpv 0.41 + stock FFmpeg 无此链路，双层合成不复刻 |
| PreviewReader Still.dolbyProfile 真实值 | landed | `MPlayPreviewReader.swift`：Int（0=非 DV），自 track-list 子属性读取（mpv 0.41 command.c 直证）；Still 另有 pixelBuffer/stride/frameIndex/image |
| 截图 correctDolbyP5 开关 | landed（双路口径） | PreviewReader 路：CPU 逐像素（**通道域近似**：帧已经过 SW 渲染 YUV→RGB，文件头明示）；捕获路（MPlayCapture）：双平面原始域逐像素，为全保真口径 |

### 阶段 D — 空间音频 + 预加载接管 + 缓存策略

| 条目 | 状态 | 落点 / 证据 |
|---|---|---|
| 钉版开源组件（AetherEngine / LibTrueHD / LibDTSX） | landed | NOTICE 三钉版（AetherEngine fc6b412…、LibTrueHD 3eab2e7…、LibDTSX 6f0b321…）；`scripts/mplaykit59/build_spatial.py` 克隆后验 HEAD==钉版、走各仓自家 build.sh，失败回落仓内 xcframework 并响亮告警。勘误：AetherEngine 是**纯 SwiftPM 包、非 Rust/Cargo**（无 C ABI）；LibTrueHD/LibDTSX 是 Rust crate（工具链分别钉 Rust 1.98.1 / 1.99.0） |
| MPlayNative 风格 ABI 桥（mplay_ 前缀转发） | landed | `Spatial/MPlaySpatialBridge.h/.c`：27 个转发函数（13 truehd_atmos_\* + 13 dtsx_\* + 组合自检），头文件逐字 vendored 自钉版仓库 |
| 对象音频解码（TrueHD / DTS:X） | landed | `MPlaySpatial.swift`：push-pull 包装（块指针解码器所有、拉后即拷贝）；错误码/访问单元粒度按头文件语义（TrueHD 40 帧 @48k、DTSX 512 帧） |
| 对象渲染 5.1.2–9.1.6 布局 | landed（渲染模型为我方） | `MPlaySpatialRender.swift` ObjectAudioRenderer：最近三声道逆距离分布 + 软限幅、48kHz 约束。原版渲染内幕无符号证据，不声称等同 |
| APAC 编码 → 内存 HLS → AVPlayer（系统空间音频） | landed（iOS 26 门槛明示） | MPlayAPACEncoder 以 `#available(iOS 26.0, *)` 门控（依 AetherEngine 标注）；MPlayAPACStream 进程内回环 HLS |
| 静默 Atmos 保通路 | partial | AtmosOutputActivator 已落地但**惰性**：静默样本由构建脚本在 CI 侧尝试用钉版仓库的 make-silent-atmos.swift 生成；样本不在仓内时激活器不动作（不假装保通） |
| 空间链路喂活播放 | blocked（缺口明示） | 解码/渲染/APAC 链完整可调用，但**未由实时 mpv 播放喂数**：那需要原版自研 `audio_relay` ao 级别的核内组件，stock mpv 无此 ao。7.1 PCM 回落路在位（MPlayAudioRelay） |
| EAC3PassthroughDecision / AudioRouteOutputOverride | landed（决策逻辑） | `MPlayAudioPolicy.swift`：符号字段逐字；iOS 栈无位流直通落点，决策用于空间路分叉，文档明示 |
| 预加载完整实例接管（promotePreloadedPlayback） | landed | `MPlayPlayer.promotePreloadedPlayback` + 协调器 preload/open 接管分支 + PiP rebindPlayer 快路；chrome 侧因宿主懒解析流而 opt-in（preloadTarget） |
| CachePolicy 分段模型 | landed（数值为我方） | `MPlayCachePolicy.swift`：字段名与原版逐字（capacity/directory/prefetchBytes/seconds/segmentBytes/segments）；值是我方 96×4MiB=384MiB / 32MiB / 120s——**原版数值是代码常量、不可恢复，不冒充**；到 mpv 选项的映射为近似（文件头明示） |

### 字幕 / 流协议 / 光盘 / NowPlaying / 故障切换 / 显示匹配

| 条目 | 状态 | 落点 / 证据 |
|---|---|---|
| SubtitleSettings 全字段面 | landed | `MPlaySubtitles.swift`：primary/secondary/secondaryActive/visible/fontsDirectory 真实应用；fontProvider、aspect 为记录字段（mpv 无对应，明示） |
| subtitles(primary:secondary:) / setSubtitleDelay(secondary:) | landed | sid/secondary-sid、sub-delay/secondary-sub-delay 均为真实 mpv 属性 |
| 字幕样式 style(_:secondary:) | partial | 主轨 sub-font-size/sub-color/sub-back-color/sub-bold 真实；**mpv 无副轨样式属性**，副轨仅记录（明示） |
| setSubtitleHDR / 透明度 / 垂直偏移 | landed | HDR 增益走独立字幕层预乘位图重曝光；透明度走层 opacity；偏移走 sub-pos |
| 字幕边缘处理（setSubtitleEdgeProcessingEnabled） | blocked（无对应物） | AVKit 文本样式概念，libass 位图无等价开关；仅记录 + 日志，明示 |
| 字幕翻译 / 实时字幕子系统 | partial | 管线与 API 落地（SRT 逐 cue、译后文件 sub-add、translationTrack 注册表、liveSubtitles 快照含简繁/去换行处理）；**AVFan 未内置任何翻译后端/凭证，未注入 provider 时返回 -18**；内嵌轨不可译（只支持外置文件轨，即 AVFan 在线字幕的实际形态） |
| 简繁转换（chineseConversion） | partial | 紧凑常用字表（约 140 对，抽验正确），**非完整 OpenCC 词典**，覆盖率部分 by construction |
| 自定义流协议 registerStreamProtocol | landed | `MPlayStreamBridge.c/.h` + `MPlayStreamProtocol.swift`：mpv_stream_cb_add_ro 桥到 Swift 工厂（info 布局对 0.41 头文件核对 + 静态断言）；限制：桥注册表进程全局（同 scheme 跨 core 后注册覆盖）、libmpv 无注销、工厂保留到 core 关闭 |
| 光盘播放（DiscSession / MediaInfo.disc） | partial（API 落地、本体 blocked） | `MPlayDisc.swift` 会话 API + mediaInfo 的 disc 块真实；**本体 blocked**：mpv 0.41 meson 有 libbluray/dvdnav 选项但管线 COMPONENTS 未引入两库，光盘源在 mpv 内失败并经 completion 如实上抛 |
| NowPlaying（系统播放信息 + 远程控制） | landed | `MPlayNowPlaying.swift` + 协调器接线：poll 发布标题/时长/位置/速率，远程 play/pause/toggle/seek 路由回传输层；next/previous 仅在宿主提供回调时启用 |
| VideoToolbox 故障切换（beginDecoderSwitch / decoderSwitchResult / recoverVideoToolbox） | landed（结果判定为观察式） | hwdec 属性运行时切换 + 以 hwdec-current 观察完成（stock mpv 能给的最强信号，与原版 fork 内显式结果不同，明示）；recover = 软解重载当前文件保位置 → 恢复 VT |
| 显示匹配（帧率/色彩与显示设备匹配） | partial | 状态面 + generation 失效计数落地（setFrameRateMatchingEnabled / clearDisplayCriteriaImmediately）；应用形态是 iOS 的 CADisplayLink preferredFrameRateRange（ProMotion）——**tvOS 的 AVDisplayCriteria 在 iOS 无对应物**，色彩侧依赖系统对显示层的处理 |
| AudioRelay 子选项（VideoHold / PCMSeekTrim / PCMMaxLead） | landed（策略值） | MPlayAudioRelay 存储 + 钳制；ao 本体不在我方核内（同空间喂活条目） |

### PreviewReader 全面对齐

| 条目 | 状态 | 落点 / 证据 |
|---|---|---|
| init 命名参数组（url/headers/height/timeout/percent/preferCover/nativeImage） | landed | `MPlayPreviewReaderConfiguration` + `init(configuration:)`；timeout 取代写死 15 秒 |
| image(at:) percent 落点 | landed | 无时刻时先 metadata 探测时长再按 percent 落点抓帧 |
| metadata() → PreviewMetadata | landed | 独立轻量 core（vo=null）；longName 以 format 兜底（mpv 无长名属性，明示）；逐轨 dolbyProfile |
| Still 字段（time/duration/rotation/dolbyProfile/isCover/rgba/metadata + pixelBuffer/stride/frame） | landed | 见 MPlayPreviewReader.swift 文件头逐项对齐表 |

### Player 99 公开方法面

| 条目 | 状态 | 落点 / 证据 |
|---|---|---|
| 传输/打开族（open/close/pause/stop/load/PlaybackSource 形态、source 作用域 async 变体） | landed | MPlayPlayer + MPlayPlayerExtras（单源核：source 不匹配返回 -2） |
| 属性族（intProperty/doubleProperty/stringProperty、option/setOption、configure、setVolume/setAudioDelay/ao-volume） | landed | 同上；即原 n8/n10/n13 的 iOS 正式对应面 |
| 状态聚合（state/progress/playbackState/playbackSnapshot/trackSnapshot/mediaInfo/navigationInfo/chapters） | landed | MPlayState/MPlayProgress + Extras 聚合（EngineState 字段集按原版命名） |
| 轨道选择（selectTrack、select(Choice,slot)、addSubtitle 全形态、removeSubtitle、prepareExternalSubtitleURL、clearExternalSubtitleCache） | landed | Extras；外置字幕走托管缓存目录，引擎永不抓远程字幕 URL（AVFan 既有纪律） |
| 后链开关族（setSDRToHDRLevel/setHDRVividEnabled/setVideoUpscalingLevel/setVideoFrameInterpolationEnabled） | landed | MPlayPostChain 设置面（UserDefaults 持久化）+ 设置页 |
| PiP 族（start/stop/transfer/sync/setCanStart…AutomaticallyFromInline） | landed | MPlayPictureInPicture.swift：startPictureInPicture/stopPictureInPicture/toggle/transfer(to:)/rebindPlayer/syncPictureInPicturePlaybackTime + 委托全套 |
| PiP 族其余（preparePictureInPictureForExit / invalidatePictureInPicturePlaybackState / resetPictureInPictureController / restorePictureInPictureAfterForeground） | partial | 以 stop/unbind/rebind 的语义覆盖（退出准备 = stop 前的同步、状态失效 = unbind、重置 = 重新 bind、前台恢复 = 中断恢复路径），无四个独立方法，明示 |
| 捕获族（captureVideoFrame/screenshot/renderBlackFrame/clearRenderView/setVideoGravity/mirrored） | landed（属主不同） | MPlayCapture.swift 在 MPlayVideoView 上（我方 FrameStore 属视图而非 Player，数据同、属主异，明示）；镜像输出为第二视图喂同帧 |
| 预览族（preview(at:)/preparePreview/renderPreview/requestThumbnail/cancelPreview） | landed | Extras 转 MPlayPreviewReader；preparePreview/renderPreview 的像素缓冲直喂形态并入 still 管线（无独立落点，明示） |
| configureAuxiliaryCache / configureManagedTracks / setPreloadedTrackOptionsProvider | partial | 缓存再应用已落地；轨道托管交接与预加载轨道选项提供者只有协调器接管语义、无独立 API 落点（明示） |
| stopRendering / restoreDisplayFrame | partial | 我方架构下渲染停止 = 视图 detach（无播放器侧渲染环）；restoreDisplayFrame 无对应状态，返回 false 并在文档明示 |
| CoreOption / CoreProperty / CoreCommand / CoreCustom 生成词汇镜像 | blocked（不镜像） | 原版是代码生成的全量词汇类型；我方是手写子集 + 通用 setProp/command 通道，功能可达、类型镜像不复刻。dovi-fel 等 CoreCustom 标记以专用方法落地（见 DV 行） |

### 无落点条目（证据在案，不复刻）

| 条目 | 结论 | 证据 |
|---|---|---|
| AppleSession | 不复刻 | IOS-FINDINGS：只有 handle + fileAccess 两个 ivar，角色未定案 |
| CoreRenderView | 不复刻 | IOS-FINDINGS：角色未定案（符号面不足以定其职责） |
| runtimePermit | 不复刻 | iOS 侧**无此符号**（安卓/网盘侧概念），无中生有不如实 |
| libavdevice 输入 | 不补 | 原版 meson enabled、我方未启；无设备/光盘源需求（光盘条目已单独 blocked 在库缺失） |
| mpv avfoundation AO | 未消除项（临时关闭，待消除） | 原版内嵌参数有 `-Davfoundation=enabled`，且原版 fork 的 ao 代码能在 iOS 编译；stock mpv 0.41.0/0.42.0（源码实读）该特性为 auto 且对 iOS SDK 自动开启，随后 ao_avfoundation.m 用 iOS 不可用的 `setAudioOutputDeviceUniqueID:`、且 HAVE_AVFOUNDATION 会解开 ao_coreaudio_utils.h/ao_coreaudio_chmap.h 中 macOS 专属 AudioDeviceID/AudioStreamID 声明的守卫，而 ao_audiounit.m 无条件包含这两个头——第六轮 CI 实证 AVFan 死于 ao_audiounit.m 10 个 error。故 build_mpv() 显式 `-Davfoundation=disabled`，这是当前让 stock mpv 在 iOS 编译通过的唯一可行路，不是已接受的差异：音频输出路径与听感的效果等价性待装机与原版同片对比后判定，必要时按原版符号面把该 ao 的 iOS 可用部分移植过来。coreaudio 本已关闭，audiounit（iOS AO）保持开启，其调用的共享函数均在守卫外声明 |
| 字幕渲染者分工（libass 位图 vs Swift/Metal） | 按可实现路线定案 | 我方走 vo 字幕通道的 libass 位图（阶段 A）；原版分工符号面未定案（IOS-FINDINGS §6），不冒充其选择 |

## KSPlayer 残留清单

- 代码依赖：**零**。SwiftPM 包引用、product dependency、Frameworks 链接、
  全部 `import KSPlayer` 与引擎类型均已移除；`grep KSPlayer` 只剩注释与
  本文档（历史沿革说明）。
- `THIRD_PARTY/KSPlayer-GPL-3.0.txt` 许可证文件保留在仓库（历史归属，
  不再随包分发 KSPlayer 代码，可后续清理）。
- `MPlayKernel.swift` 为单 case 描述文件（见上），无功能残留。

## CI 首跑清单（本地无法编译 Swift / 无法冷构建 libmpv / 无 Cargo，以下必须首跑核）

1. libmpv 冷构建：freetype 的 cmake harfbuzz 探测、uchardet（cmake）/
   lcms2（meson）两 stage 的 .pc 落点；**阶段 A 新增**：vo 补丁在
   pristine 0.41.0 树上的应用（本地已验 apply --check，CI 走构建脚本
   戳路径）、frame_output 的格式协商（VideoToolbox CVPixelBuffer
   直通与软解 planes 兜底）、关 GL 后 libplacebo 的实际链接形态。
2. Swift 编译：全量新文件（MPlayKit 目录 + Spatial 子目录）一次过编；
   重点：桥接头双 include（Spatial + StreamBridge）、首个 C 文件
   （MPlaySpatialBridge.c / MPlayStreamBridge.c）进 target 的编译
   形态、C 函数指针回调的导入形状、@convention(c) 签名匹配。
3. Metal：`MPlayPostChain.metal` 进默认库（makeDefaultLibrary）编译，
   四个 kernel + P5 kernel 的纹理格式在真机上的可用性。
4. 空间音频 Cargo 阶段：两个钉版工具链（Rust 1.98.1 / 1.99.0）在
   runner 上的构建时长与 rust_eh_personality 预链接；DTSX 动态库
   Embed & Sign；静默 Atmos 样本生成（make-silent-atmos.swift）在
   runner 上是否成功——失败时激活器保持惰性（设计内）。
5. pbxproj：Libmpv/TrueHD/DTSX 的 Frameworks + Embed、显式系统框架
   清单（含 MediaPlayer，已在链内）是否足够/多余。
6. 真机：起播/续播/倍速/seek 落点、在线字幕 sub-add 与样式映射、
   PiP 进出与字幕渲染尺寸、显示层时间基漂移、后链三 pass 与 P5
   的实际观感（与原版效果差异以观感为准再调参）、DV 文件的
   profile 读取与 RPU 解析对真实样本的回归、PreviewReader 的
   SW 渲染方向（旋转源）与 dolby-vision-profile 回读。
7. 版本号保持 59；本轮全部提交只在本地 `feat/mplaykit-59`，未 push。

## 装机首测修复（2026-11-24，IPZZ-950 黑屏卡死）

现象：时长/轨道/缓存正常，画面全黑、time-pos 钉 0、播放器自认为在播放。
根因（mpv 0.41.0 源码坐实）：核心线程输出第一帧后在 `vo_wait_frame()`
里等 VO 线程画完（player/video.c 的 STATUS_READY 路径，video_latency_hacks
未开）；我们的 VO 回调链在 draw_frame 内经 `nudgeTimeSync` 同步调用
`player.state()`，属性读取走 `mp_dispatch_lock`、须等核心线程进入
dispatch 处理点——核心正堵在 vo_wait_frame 里，两边互等，第一帧即
永久死锁（播放器队列为传导环节）。解复用/缓存线程独立，故缓存照涨。
这违反 frame_output.h 自定的契约（VO 线程回调不得阻塞、不得回调
client API）；原版帧路径同样不回读播放器状态，时间同步由播放器侧驱动。
修法（仅 MPlayVideoView.swift）：nudge 在 VO 线程只做本地节流判断，
state 读取与 DV profile/显示标准刷新整体异步跳主队列执行（核心永不
等主队列），语义与 1 秒节流节奏不变；detach 复位在途标志。
另记一项非阻塞性偏差（后续单独处理）：vo_frame_output 未给
hwdec_devs 注册 VideoToolbox 设备（无 load_api），hwdec=videotoolbox
静默回落软解、帧走 fo_pack_image 打包而非原版的 VT 零拷贝直通——
不影响起播，影响性能与保真度。

## 装机二测修复（2026-11-24，IPZZ-950 黑屏有声）

现象：死锁修复（17d5c84）装机后，播放能进行、有声音，画面仍全黑。
定性：核心时钟已走、音频支路正常，问题收窄在视频支路
（解码输出 → vo → Swift 帧管线 → 显示层）。逐环审计结论：

1. **根因（架构性，已坐实）：vo 从未注册 VideoToolbox 解码设备。**
   上一节记的「非阻塞性偏差」就是本轮根因。mpv 0.41.0 源码链：
   播放器请求 `hwdec=videotoolbox`（非 copy 型）→ vd_lavc.c 的
   `hwdec_create_dev()` 只能从 VO 的 `hwdec_devs` 按
   (IMGFMT_VIDEOTOOLBOX, AV_HWDEVICE_TYPE_VIDEOTOOLBOX) 取设备 →
   我们的 vo `preinit` 是空的、从未 create/add → 设备创建失败 →
   `hwdec-software-fallback=yes` 下静默回落软解。管线注释曾断言
   「VT 解码路径是 FFmpeg hwaccel + mpv 的 hwdec_vt 设备驱动、
   不受影响」——双重误判：hwdec_vt（ra_hwdec_videotoolbox）只由
   gpu 后端加载，且其 init 在无 GL/PL interop 时直接拒绝
   （hwdec_vt.c）；而我们的 vo 连设备列表都没建。原版帧是 VT
   解码器自己的 CVPixelBuffer（IOSurface、自带色彩附件、零拷贝），
   我们则从第一天起就全靠从未在真机出过画的软解打包路径。
2. **打包路径自身的缺陷（已坐实）：** `fo_pack_image` 用 NULL
   属性建 CVPixelBuffer（未指定 IOSurface 属性、无 Metal 兼容
   标记），且从不把帧的色彩描述（params.color.primaries /
   .transfer、params.repr.sys）写成 buffer 附件——主机据此建的
   format description 不带任何色彩信息，与 VT 缓冲的规格不在
   一个级别。该路径在 112 死在第一帧、114/115 是其首次真机运行，
   结果即黑屏。显示层一侧（时间基锚定、isReadyForMoreMediaData
   守卫、format description 按 (w,h,type) 缓存、字幕层透明合成、
   视图装配与 attach）逐项审过，无第二处可坐实的错误。
3. 修法（新补丁 `0004-vo-frame-output-vt-hwdec.patch`，只动
   vo_frame_output.c）：preinit 按 vo_mediacodec_embed 的形状自建
   设备——`hwdec_devices_create()` + `av_hwdevice_ctx_create(
   AV_HWDEVICE_TYPE_VIDEOTOOLBOX)` + 注册 mp_hwdec_ctx 并
   `hwdec_devices_add`；uninit 先 remove 再 unref/destroy（满足
   hwdec_devices_destroy 的断言）。同时修打包路径：建缓冲带
   IOSurface + Metal 兼容属性，新增 `fo_attach_color()` 把色彩
   描述从 mp_image_params 写入附件。管线脚本里那段误判注释已
   同步改正。未动：杜比映射数值（39177e5）、nudge 修复
   （17d5c84）、任何 Swift 文件（与杜比播放还原线零冲突）。
4. 装机验证要点：播 IPZZ-950 应出画面且有声；Diagnostics 里
   hwdec-current 应为 videotoolbox；拖动进度、暂停/恢复正常。
   若个别老编码文件仍走软解（VT 不支持的编码），其帧现在走
   修过的打包路径（带附件的 IOSurface 缓冲）；万一那种文件仍
   黑屏，黑屏域即被单独钉在打包路径上，届时按计数器
   （enqueued / notReadyDrops）再查，不要再动已通的硬解路径。

## 播放路径杜比呈现对齐（2026-11-24，逆向报告 DOLBY-PLAYBACK.md）

原版播放 DV 的呈现链（全部有二进制证据，详见
~/workspace/p115-player-re/DOLBY-PLAYBACK.md）：

1. 内核侧：分叉 mpv 新增 demux/dovi_split.c（P7 双层拆 BL/EL 流）
   与 filters/f_dovi_rpu.c（逐帧提取+解析 RPU、挂帧侧数据 type 23）；
   vo 选项 vo-frame_outputvo-dovi-p7-to-p81 在流选择层生效
   （profile==7 且开关开时对 EL 流做流级处理）。
2. 帧管线侧：FrameStore 的后处理成员只有 hdrVivid/sdrToHDR/
   upscaler/interpolator/deinterlacer/previewScaler——**没有杜比
   映射器**；FrameOutputView.enqueue 是纯封装（用调用方给的
   formatDescription 建 CMSampleBuffer 直接入队），不做任何像素
   处理；打标代码设置/传播的是标准 HDR 附件键（primaries/
   transfer/matrix + MasteringDisplayColorVolume +
   ContentLightLevelInfo），二进制未导入任何杜比专用附件键，
   SampleDescriptionExtensionAtoms 零代码引用（无 dvcC 原子）。
3. Metal 后链：随包 metallib 只有 ONE 个内核 pkFrameKernel0
   （SDR→HDR：toneLUT + inputMinPQ/inputMaxPQ 等标量），**无任何
   DV/P5 内核、无 RPU 参数**。
4. 结论：原版播放呈现 =「内核备好 BL+RPU、标准 HDR 打标、系统
   合成器呈现」；DolbyP5ColorCorrection.convert 只活在静帧/截图
   路径（上一轮已提取数值并对齐，39177e5）。

本轮改动（只限杜比呈现路径）：

- **删播放 P5 GPU pass**：MPlayPostChain 原先对 profile 5 默认
  开启逐帧 GPU 校正（pkDoviP5Kernel0）——原版播放路径没有这一
  级，属我方多加的像素变换。已删路由、pipeline、runDoviP5、
  metal 内核、设置页开关与 UserDefaults 键；DV 流（profile≠0）
  现在整体跳过 tone pass（SDR→HDR 也只作用于非 DV 帧）。
- **补附件传播**：后链此前任何 pass 的输出都不带附件，DV/HDR
  帧只要开超分/插帧就丢打标。保色 pass（upscale、interp）输出
  现按原版做法 CVBufferPropagateAttachments 传播源帧附件；
  SDR→HDR 输出不复制源标签（其信号语义已变，属既有非 DV 议题）。
- 未动：帧送达逻辑（17d5c84 nudge 修复、51186ba 的 vo 补丁
  0004）、CPU convert 与提取数值（39177e5）、空间音频、PiP。

未能对齐（如实记档）：dovi_split 的 P7 EL 合成与 f_dovi_rpu 的
RPU 侧数据通路依赖原版分叉内核，stock mpv 0.41 无对应组件
（blocked，证据见 DOLBY-PLAYBACK.md）；逐帧 DolbyP5FrameMetadata
跨 vo 边界到 Swift 的确切生产点未能提取（类型字段已实测：
rpuData + 解析后 ColorMap + 软解平面 payloads；播放路径未发现
用它变换像素的消费者）。

## 装机三报修复（黑屏有画但全压黑 · 显示侧复审 + 运行时探针）

装机三报（116/123）：「是有画面，但是全是黑的，只能看到水印」——帧里烧录的 IPPA/MOODYZ 水印（近白）隐约可见、其余内容全压成黑。定性随之改变：解码、帧送达、显示呈现三段都通了，死点在色彩/亮度转换（传递函数/矩阵/打标错位、或某道 pass 以错误输入域作用于 SDR 帧）。

显示侧全链复审结论（逐环，代码证据）：
- vo draw_frame 出口：VT 帧 planes[3] 取 CVPixelBufferRef + CFRetain 与 hwdec_ios_gl 同约定，正确；软解打包 + fo_attach_color（0004）的 709/PQ/HLG/601/2020 映射逐项正确（本轮未动 0004/0005 语义）。
- FrameStore：纯透传 + 计数，无丢帧点；计数此前无任何界面消费。
- 调度器/CMSampleBuffer：格式描述由真实帧缓冲构造（附件随之传播）、timing 用帧 PTS/时长、未设 DisplayImmediately（时间基节奏下正确）；isReady 丢帧有计数但从未上屏；图层 status 有查、error 无人持续读取——运行时对这一段是全盲的，这是本轮探针要补的洞。
- 时间基：主机时钟创建、速率由 nudge/transport 同步（17d5c84 后路径已通，三报症状亦证明节奏在跑）。
- 显示层装配：layerClass 后备层、字幕子层透明（isOpaque=false、无黑底，排除均匀压暗）、videoGravity 默认值无异常。
- 后链：代码坐实默认全关——四个开关读 UserDefaults、未设置即 off/false，setter 仅设置页开关调用，felInput 无人喂；isEnabled=false 时帧直达调度器。但 UserDefaults 跨侧载更新保留，若用户曾开过「画质增强」开关，后链即在跑；而 runSDRToHDR 的输出缓冲不带任何色彩附件（不传播、不重打标），其着色器却按 PQ 域参数写值——此路径一旦开启，输出必然被错误呈现，与三报样貌相容。本轮不凭猜改它，先由探针读其实时状态定性。
- 播放器选项：无 tone/target/EQ 类选项；vo/hwdec 符合预期。
- 与原版对照：原版 format description 由 FrameStore 侧构造后传入 enqueue、调度器按显示 tick + lead 统计出帧；原版 SDR→HDR mapper 按帧的真实打标（isSRGB/isFullRange/inputMin/MaxPQ）选数学。我方机制不同（逐缓冲建描述、时间基节奏），已证可工作，架构差异记档待探针数据再议。

本轮改动：
- 运行时探针（必交项）：调度器新增真实计数（格式描述失败、样本创建失败）与最近帧记录（像素格式/尺寸/PTS/ID、缓冲附件与格式描述扩展的 primaries/transfer/matrix），格式描述重建时同步写入诊断日志；MPlayVideoView.probeSnapshot() 组装帧仓库计数 + 调度器状态 + 后链实时状态；播放器 chrome「画面与方向」菜单新增「播放探针」面板（PlaybackProbeView），含播放器侧 hwdec-current/current-vo/video-params（primaries/gamma/colormatrix/colorlevels/pixelformat）与 time-pos，0.5 秒刷新，截图即可定位。
- 小修（有代码证据）：图层失败上报标志此前全生命周期锁存、恢复后再失败永不再报——改为图层恢复时复位；stats() 计数改走调度队列读，消除跨线程无同步读。

装机定位法（新包）：播放 IPZZ-950 后打开探针截一张图——
- hwdec-current 非 videotoolbox → 还在软解/打包路径，查 params 与帧格式；
- params/gamma 为 bt709 而格式描述 transfer 出现 PQ/2020 字样 → 打标在缓冲→描述一段被写错；
- 缓冲附件与格式描述都对、后链「启用=否」却仍压黑 → 问题在系统呈现/时间基节奏，转查 status 与 timebase；
- 后链「启用=是」且 SDR→HDR 级别非 0 → 先关设置页「画质增强」复测，即可判后链输出未打标是否元凶；
- status=failed 或 error 有值 → 显示层拒帧，按 domain/code 查。
