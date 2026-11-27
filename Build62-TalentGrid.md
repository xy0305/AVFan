# Build 62 — AVBase 女优排行格子图片错乱修复

版本 61 → 62，只动女优排行格子（及同组件的女优作品页页头头像）一处呈现；
作品网格、其他榜单、解析层均未动。

## 真机缺陷（build 61，2026-11-27 14:57 截图）

- 女优排行 3 列网格里头像被裁得极狠、脸部过度放大切边；
- 第 5 名（持野蓬）格子坏掉：头像没出来，占位人形图标压在格子中间偏右，
  同行格子宽度互不一致（第 4 名明显更宽），整行错位。

## 根因（代码确诊）

1. **头像走了 RemoteImage，而它的尺寸由图片原生比例协商决定。**
   `RemoteImage`（NewsView.swift）的 body 是裸 `ZStack { Rectangle;
   Image.resizable().aspectRatio(contentMode: .fill) }`——没有 GeometryReader、
   没有固定帧。resizable + .fill 的图片按「覆盖提议尺寸且保持原生比例」
   回报尺寸，可以在某一维**超出网格列宽**；格子外层再套
   `.aspectRatio(3/4, contentMode: .fill)` 也约束不住（.fill 只会放大不会收）。
   于是每张头像按各自原生比例溢出不同的量：格子看着宽窄不一、图片互相
   压边、可见窗口不是居中的 3:4 裁切而是溢出后剩下的部分——脸被切得极狠。
   作品封面没这问题，是因为 `CoverImage` 整体包在 GeometryReader 里
   （ImageLoader.swift），永远按提议尺寸回报，尺寸与加载状态无关。
2. **无头像占位是无固有尺寸的 ZStack。** build 61 的占位分支是
   `ZStack { RoundedRectangle（无固有尺寸）; person.fill 图标 }` +
   `.aspectRatio(3/4, .fill)`，同样没有 maxWidth 帧钉住列宽，协商结果
   不稳定：格子塌陷/移位、图标偏离中心。第 5 名正是此例——她那行
   DOM 里没抓到 img（或走了 props 兜底，那条路 avatarURL 恒为 nil，
   AVBaseParser.swift），命中占位分支后整行错位。
3. **头像 URL 无大图变体可用。** 通读 avbase.js：演员图一律
   `avAbsUrl(actor.image_url)` / DOM 的 `img src || data-src` 原样使用，
   模块里没有任何尺寸变体规则。故本版用原图，不编造 URL 规则。

## 修法

- 新增专用 `TalentAvatarView`（RankingsView.swift 内）：
  `frame(maxWidth: .infinity)` + `aspectRatio(3/4, contentMode: .fit)`
  把格子钉死为「列宽 × 4/3 高」，在加载中 / 已加载 / 失败 / 无头像
  四种状态下尺寸完全一致；内部头像用 ImageLoader 直出 AVBase 演员图、
  `scaledToFill` 居中裁切并 clipped 在帧内，永不溢出；占位填满同一帧、
  图标居中（仅无 URL 或加载已失败时显示，加载中只显底色）。
  不走 CoverImage 的封面裁切策略（FrontPosterPolicy/cropRect），
  不走高清探测链。
- RankingGridCell 的 actor 分支整体换成 TalentAvatarView
  （JAVLibrary 的演员行共用同一分支，同点受益）。
- 女优作品页页头头像原本同样用 RemoteImage（外加固定 72×96 帧），
  一并换成 TalentAvatarView 再套 72×96 帧（72×96 正好是 3:4，
  内部 aspect fit 落在同一帧上）。

改动文件：`AVFan/Views/RankingsView.swift`、`AVFan.xcodeproj/project.pbxproj`
（版本 62）、本文件。解析层未动，无新增解析测试。

## 装机验收

1. 女优排行：所有格子等宽等高、成行对齐；头像为居中 3:4 裁切，
   脸不再被过度放大切边。
2. 无头像/慢加载的格子（如第 5 名那类）：占位完整填满格子、
   图标居中、不溢出不压邻格，整行不错位。
3. 点女优进作品页：页头头像正常显示（72×96），作品网格不受影响。
4. 其他榜单（作品封面网格、JAVLibrary 演员行）呈现无回归。
