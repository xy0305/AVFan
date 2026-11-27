# Build 61 — AVBase 分页修复 + 女优排行 / 女优作品页

项目版本 60 → 61（pbxproj 两处 CURRENT_PROJECT_VERSION）。
在 Build 60 的 AVBase 一期之上修分页缺陷，并接入二期的女优排行
与女优作品页（标签浏览仍不做）。

## 一、加载更多没反应：确诊根因与修法

真机证据（2026-11-27 12:46 截图）：AVBase 列表能加载（条目带名次
25–30），底部「加载更多」按钮呈灰色禁用态、点按无反应。

根因（代码证据，在 Build 60 的实现里）：

1. **主因——`loading` 被尾部预热长时间占用。**
   `ExternalRankingsView.load()` 开头 `loading = true`，靠 `defer`
   在函数返回时复位；而函数的最后一步是
   `await store.preResolve(entries:)`——对首页每个未缓存番号串行
   发一次 avfan 搜索（SiteClient 自带 ≥1 秒限速，还可能走 WebView
   回退）。首页 30 个新鲜番号就是几分钟。在这段时间里：
   - 按钮 `.disabled(jrLoadingMore || avLoadingMore || loading)`
     一直为真 → 按钮灰；
   - `loadMoreAVBase()` 的守卫 `!loading` 一直为假 → 就算点中也
     被静默吞掉。
   列表本身早已渲染（spinner 只在 entries 为空时出现），用户看到
   的就是「列表在、按钮灰、点了没反应」。
2. **次因——失败静默。** Build 60 的 `loadMoreAVBase` catch 里
   直接 `avHasMore = false`：翻页请求一旦失败，按钮无声消失，
   没有任何提示。
3. **隐患——去重键带名次。** Build 60 按 `entry.id`（`"名次|番号"`）
   去重：若站点忽略 `?page=` 返回重复页，重复条目会因名次不同
   被当成新条目追加。

修法：

- `load()` 在 `preResolve` 之前显式 `loading = false`（defer 保留
  兜底）；按钮的 disabled 对 AVBase 只看 `avLoadingMore`，
  `loadMoreAVBase` 守卫去掉 `!loading`。女优作品页的 loadFirst
  同样处理。
- 分页判定改成**以实际返回为准**（`AVBaseParser.hasMore` 纯
  函数，CI 可测）：本页返回数达到观测到的首页页大小才认为还有
  下一页；不足一页或空页即最后一页。客户端删掉按声明 total
  推断的分支（/works/recent 的 total 键位与 readTotal 的口径
  对不上，不再让它参与判定）。
- 去重改按归一化番号（`RankingMatchStore.key`）；整页无新番号
  （空页或站点重复页）即停，不追加、不进页。
- 翻页失败：保留已有条目与按钮，按钮上方出现「下一页没加载
  出来，检查网络后点重试。」+ 重试按钮；`avLoadingMore` 仍由
  defer 复位。
- 三个面（最新作品 / 按发售日 / 番号搜索）共用同一套机制，
  女优作品页同样。

## 二、女优排行（.avbase 新 term「女优排行」）

- 数据：`/talents/popular?date=<JST 当天>`（日期口径照
  avbase.js）。当日快照不存在时按 avbase.js 的做法退回不带
  日期取最新一期，再空才报 avbaseEmpty。
- 解析（AVBaseParser.talentRanking）：照 avbase.js 的顺序
  **DOM 优先**——服务端 HTML 的 article 卡片里有名次角标、
  变动角标、ruby（名字+假名）、头像 img；JSON 的
  `props.pageProps.snapshot.items` 只有姓名序列（talent.primary，
  否则 talent.actors[0]），作兜底（无头像、无变动）。
- 列表项：名次角标、女优名、头像。头像用 AVBase 的演员图
  （DOM img 的 src/data-src，相对地址按站源补全）——演员没有
  高清源，这是唯一来源；作品封面的高清链规则不变。格子对
  actor 条目有 coverURL 时显示头像，无头像时保持原占位
  （JAVLibrary 的 actor 条目不受影响）。
- 点女优 → 女优作品页（不再走 avfan 演员匹配）。

## 三、女优作品页（AVBaseTalentWorksView）

- 数据：`/talents/<name>?page=N`，一次抓取同时拿到资料与作品
  （同一 pageProps）。客户端 `AVBaseClient.loadTalent`，串行
  限速与 WebView 回退与一期相同，错误沿用
  avbaseChallenged / avbaseEmpty。
- 资料解析（avNormTalent / avFindTalent 的移植）：名字与头像在
  `primary`（name / ruby / image_url），三围等在
  `meta.basic_info`（birthday / height / bust / waist / hip /
  cup / prefectures）；数字字段字符串化。页头显示头像 + 名字
  + 资料摘要（avTalentProfileText 口径：假名 / 生年月日 /
  出身地 / 身長 / サイズ）+ 作品总数（列表 total）。页面没给
  的字段就不显示，不编造。
- 作品网格与一期同一套：coverURL=nil、code=裸番号走 CoverImage
  高清链；点按走 RankingMatchStore → avfan 详情（磁力 / 115 在
  详情页）；分页用第一节修好的机制。

## 四、测试

`scripts/test_parser_main.swift` 新增 Build 61 块，CI 的 swiftc
清单本来就含 AVBaseParser.swift（Build 60 已加），新测试随
「Parser fixture tests」步真跑：

- hasMore 四种情形（满页 / 不足页 / 空页 / 无观测页大小）；
- 女优榜 DOM fixture（按 avbase.js 记录的卡片结构构造）：
  名次、ruby 名字与假名、头像相对地址补全、data-src 头像、
  变动文案（上升 2 位 / 新进榜）；
- 女优榜 snapshot 兜底 fixture：姓名序列、名次、无头像；
- 女优资料 fixture：primary + meta.basic_info 结构、数字身高
  字符串化、摘要全文、扫描兜底、Bare 名字不编造字段；
- 女优页 works 与资料同页解析。

与 Build 60 相同：本机出口被 Cloudflare 403，拿不到 AVBase
真实页面，fixture 按 avbase.js 记录的字段/结构构造；真机行为
以下方验收为准。

## 五、装机验收清单

1. 最新作品：列表出现后立刻点「加载更多」——按钮可用，第二页
   追加、名次连续；翻到末页按钮消失，不重复追加。
2. 按发售日、番号搜索：同样能翻页；翻页失败（如断网）时出现
   提示与重试，恢复网络后重试成功。
3. 女优排行：出列表，带名次与头像（JSON 兜底时可能无头像，
   属预期）；点任一女优进她的作品页，不是 avfan 演员页。
4. 女优作品页：页头有头像、名字与资料摘要（页面没给的字段
   不显示）；作品能翻页；点作品进 avfan 详情，磁力 / 115 在。
5. 封面仍是高清链结果（DMM/MGS 官方竖构图优先），不是 AVBase
   产品图；女优头像除外（本站演员图，唯一来源）。
