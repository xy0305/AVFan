# Build 60 — AVBase 接入（一期）

版本 1.3 / build 60。范围由用户 2026-11-27 锁定：AVBase
（https://www.avbase.net/）作为新的外部榜单源接进排行页，与
DMM / JAV Ranking / MissAV 并列。二期（女优排行、女优页、标签
浏览）不在本版范围。

## 三个面

| 面 | 端点 | UI |
| --- | --- | --- |
| 最新作品 | `/works/recent?page=N` | 默认面 |
| 按发售日 | `/works/date/<yyyy-MM-dd>?page=N` | 前一天/后一天步进 + 日期选择器（JST 日期） |
| 番号搜索 | `/works?q=<关键词>&page=N` | 输入框 + 搜索按钮/回车提交 |

分页复用 JAV Ranking 的 loadMore 模式（追加、按条目 id 去重、
只预解析新段）；页大小按首页实际条数推断（站点 10/30 条混用，
avbase.js 的 avCollectAllWorks 同款规则），hasMore 由页面声明
的 total 优先推断，无 total 时按「满页即可能还有下一页」。

## 数据契约（源：avbase.js v1.8.0，Forward widget 模块）

AVBase 是 Next.js 站，页面嵌 `<script id="__NEXT_DATA__">` JSON：

- 列表在 `props.pageProps.works`（兼容 worksList / items / list，
  都没有时扫描 pageProps 里最大的 work-like 数组，avExtractWorks）
- 总数在 `total`（兼容 totalCount / total_count / count / totalItems，avReadTotal）
- 作品字段：`work_id`=番号（如 MBMP-173），`prefix`=厂牌前缀
  （站内 code 是 `prefix:work_id`，如 mbm:MBMP-173），`title`，
  `casts[].actor{name}`，`tags[].name`，`min_date`=发售日
- `products[]` 多销售渠道，用 avPickProduct 按完整度打分选：
  image_url +4、thumbnail_url +2、iteminfo.description +1、
  sample images +1、sample movie +1；有图的先组成候选池；
  时长/简介取选中 product 的 `iteminfo{volume, description}`
- 番号归一化按 avAggregateId：取 work_id、去掉 `maker:` 前缀、
  去空格（含全角）、大写——聚合 id 就是裸番号，匹配只认它
- 日期归一化按 avNormDate 双格式：`2026-11-05`（含 / 与年月
  分隔）与 JS Date 字符串（`Sat Dec 05 2026 ... GMT+0900`）
- 时长按 avParseMinutes：只认 `120分` / `95min` 形式，裸数字不算

## 实现

- `AVFan/Services/AVBaseParser.swift`（新增，仅 Foundation）：
  上述契约的解析层。`__NEXT_DATA__` 抽取复用既有的
  `AvbaseMetadata.props`（CataloguePoster.swift，封面发现早就在
  用同一站点的同一解析，含 2 MB 上限与恰一块的校验），不重复造。
  已加入 CI 的 swiftc 解析测试文件清单，真跑解析测试。
- `AVFan/Services/AVBaseClient.swift`（新增）：actor 串行单通道、
  请求间隔 ≥1 秒、App 同款移动 UA。先 URLSession，遇
  403/429/503、挑战页（`HTMLParser.isBlocked`）或缺
  `__NEXT_DATA__` 时回退共享 WebViewFetcher；仍失败抛
  `avbaseChallenged` / `avbaseEmpty`（RankingSourcesError 新 case，
  仿 missavChallenged）。按番号页内去重。
- `RankingsView`：`RankingSource` 增加 `.avbase`（terms：最新
  作品 / 按发售日 / 番号搜索）；条目 coverURL=nil、code=裸番号。

## 匹配与封面（用户锁定，不许改）

- 点进条目 → 现有 RankingMatchStore 按番号精确匹配 avfan 详情
  页；磁力与 115 推送/播放都在 avfan 详情页上。匹配不到时详情
  占位页显示「在 AVFan 里没搜到番号…可能站点还没收录这部」
  （即「AVFan 暂无此作」）。
- 封面走现有高清链：网格 CoverImage 以番号走 HQ 探测
  （HQCoverResolver / DMMCoverResolver，DMM/MGS 官方竖构图
  优先），回退到匹配到的 avfan 卡片封面。**不用 AVBase 自带
  产品图**——解析器根本不把 product 图片交给 UI。

## 红线

- 只抓公开页面：不登录、不碰 `/api/`、不伪装 UA；
  403/429 停手降级为错误态，挑战页只走 WebView 回退、不绕过。
- 串行限速 ≥1 秒（AVBaseClient 单通道）。

## Fixture 说明

解析测试的页面 fixture 是**按 avbase.js 记录的字段结构构造**的，
不是真实页面抓取：本机（构建机）出口访问 avbase.net 被
Cloudflare 403（`Just a moment...` 挑战页，无 `__NEXT_DATA__`），
与 avfan.com 从该出口的处境相同。真实页面验证只能在真机上做
（App 的 WebView 回退正是为这种站点准备的）。

## 装机验收清单

1. 排行页出现 AVBase 板块，三个面可切换。
2. 最新作品能加载（真机出口能过 Cloudflare：URLSession 直通或
   WebView 回退后拿到 `__NEXT_DATA__`）；加载更多能翻页、条目
   不重复。
3. 按发售日：前一天/后一天与日期选择器切换后列表跟着变。
4. 番号搜索：输入一个番号（如 IPZZ-936）能出结果；空关键词时
   显示说明文案、不发请求。
5. 点进条目 → 匹配到 avfan 详情页，磁力列表在、115 推送/播放
   可用；点一个 AVFan 未收录的番号 → 显示暂无此作占位。
6. 封面是高清链结果（DMM/MGS 官方竖构图优先），不是 AVBase
   自带产品图；未匹配条目在预解析完成后回退到 avfan 卡片封面。
7. 若真机也被 Cloudflare 拦：错误文案为 AVBase 人机验证提示，
   不白屏、不崩溃。
