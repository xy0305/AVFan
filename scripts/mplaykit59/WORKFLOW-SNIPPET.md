# WORKFLOW-SNIPPET — 把 Libmpv 构建步骤插进 AVFan 的 build-ipa.yml（Build 59）

> 本文件只是**待插入的片段说明**，不是 workflow 本身；协调者收口时再把
> 下面的 YAML 贴进 `.github/workflows/build-ipa.yml`。本轮不直接改 workflow。

## 插入位置与前提

- 文件：`.github/workflows/build-ipa.yml`
- Job：唯一的 `ipa` job（`runs-on: macos-26`，单 job 结构不变，不要新开 job）
- 位置：插在 `- name: Resolve Swift packages` 步骤**之前**
  （Libmpv.xcframework 必须在 resolve / build 之前就落在 `Vendor/`，
  后续接进 App target 时链接才找得到它）。
- 另需一处 job 级改动：`timeout-minutes: 90` → `timeout-minutes: 300`
  （见文末理由，片段本身改不了 job 级字段，收口时一并改）。

## YAML 片段（与 job 内其他 steps 同级缩进，直接粘贴）

```yaml
      - name: Cache Libmpv sources, build tree and xcframework
        id: libmpv-cache
        uses: actions/cache@v4
        with:
          path: |
            .cache59
            Vendor/Libmpv.xcframework
          key: libmpv-59-v1-${{ runner.os }}-${{ hashFiles('scripts/mplaykit59/**') }}
          restore-keys: |
            libmpv-59-v1-${{ runner.os }}-

      - name: Build Libmpv.xcframework (pinned sources, sha256-verified)
        if: steps.libmpv-cache.outputs.cache-hit != 'true'
        run: python3 scripts/mplaykit59/build_libmpv.py "$GITHUB_WORKSPACE"

      - name: Assert Libmpv.xcframework exists
        run: test -d Vendor/Libmpv.xcframework
```

## 缓存 key 设计

- **主 key**：`libmpv-59-v1-${{ runner.os }}-${{ hashFiles('scripts/mplaykit59/**') }}`
  - `hashFiles('scripts/mplaykit59/**')`：脚本、cross 模板、文档任一改动都
    使 key 变化——`build_libmpv.py` 里的版本钉与 sha256 一变，旧产物绝不
    能被当成新产物命中，这正是要绑脚本哈希的原因。
  - `${{ runner.os }}`：把 runner 系统纳入 key，避免不同系统镜像的缓存
    互相串用（当前 job 固定 macos-26，该项主要防未来换 runner 世代）。
  - `libmpv-59-v1-` 前缀：带 Build 号与手动版本号；管线语义大改时把
    `v1` 抬到 `v2` 即可整体作废旧缓存。
- **restore-keys 前缀回退**：`libmpv-59-v1-${{ runner.os }}-`
  主 key 未命中时，actions/cache 会按此前缀恢复最近一份同前缀缓存。
  回退恢复是安全的：`cache-hit` 此时为 `''`（不等于 `'true'`），构建步
  骤照样运行；脚本按 `.cache59/build/<platform>/<stage>.stamp` 逐阶段
  跳过已完成阶段，回退带回的 `.cache59` 只起增量加速作用；产物
  `Vendor/Libmpv.xcframework` 由脚本先删后建，不会沿用旧文件。
- **缓存内容两件**：
  - `.cache59`：脚本的中间缓存目录（downloads / src / build / cross /
    venv），是冷构建最耗时的部分（9 个 tarball 下载解压 + 双平台全量
    编译树），命中/回退后重跑只补未完成阶段。
  - `Vendor/Libmpv.xcframework`：最终产物；主 key 精确命中时构建步骤
    整步跳过，job 直接用现成产物往下走。

## 为什么 job timeout 必须从 90 提到 300

- 现状 `timeout-minutes: 90` 是按「只编 App 本体」定的。
- 冷构建（缓存全未命中）要从零编 9 个组件 × 2 个平台（device +
  simulator）：FFmpeg / mpv / libplacebo / dav1d / libass / freetype（×2
  遍）/ harfbuzz / fribidi / xxHash 全量交叉编译，再合并 framework、
  组 xcframework，之后还要再跑完原有的 App 编译 + 打 IPA。单是原生
  冷构建一项就可能吃掉数小时量级，90 分钟必然在中途被砍，后面的
  打包步骤根本轮不到。
- 提到 **300** 是给「冷构建 + App 编译打包」留足一趟跑完的余量；
  缓存精确命中的热跑构建步整步跳过，实际耗时仍接近原来的量级，
  抬上限不花钱、只防冷跑被腰斩。
