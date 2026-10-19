# Oil Find Pro 功能层开发设计

日期：2026-10-19
范围：**仅功能层** —— 离线磁盘搜索、图片内容搜索、文档内容搜索。
不含：授权码、试用、设备绑定、购买流程、官网支付（现状与踩坑见附录 A，供以后接入时参考）。

本文所有 `file:line` 指向公开仓库 `/Users/zhuzhong/superconductor/projects/oil-find`。

## 目标

在私有仓库 `Pro/` 内实现三块 Pro 能力，不改动公开库即可完成；一旦发现必须改公开库，只允许新增**中性** API（不出现私有 target 名，不泄露产品状态）。

## 现状：公开接入面

`Package.swift:5` 用 `Context.packageDirectory + "/Pro/Sources/OilFindPro"` 探测私有模块；`OILFIND_FREE=1` 强制免费版。`Sources/OilFind/main.swift:2-7` 在 `canImport(OilFindPro) && !OILFIND_FREE_BUILD` 时注入 `OilFindProExtension()`。

Pro 是独立 module，**只能使用 public 符号**。以下均为 internal，Pro 拿不到，必须自建：

| internal 符号 | 影响 |
| --- | --- |
| `L10n` | Pro 必须自带中英文文案表 |
| `Theme` / `IconProvider` | Pro 必须自带样式与图标加载 |
| `SettingsModel` | 无法把 Pro 统计并入设置页模型（可用 `settingsSection` 自带 SwiftUI 状态） |
| `ExternalDriveCatalog` | 无法控制逐盘开关、推出审批、目录持久化 |
| `Snapshot` | `allowed` 参数白名单写死，Pro 调试参数必须自己消费 |
| `Permissions` | 完全磁盘访问判断需自建 |
| `AITopic*` | 内容索引内核只能照搬设计，不能复用代码 |
| `SearchViewController` / `SearchPresentation` / `ResultsView` | 无法自定义结果行渲染与合并策略 |

### 可用的扩展点

| 能力 | 入口 |
| --- | --- |
| 生命周期钩子 | `ApplicationExtension`：`handleLaunch` / `start` / `stop` / `languageDidChange` / `handle(_ url:)`（`Sources/OilFindApp/ApplicationExtension.swift:38-55`） |
| 设置分区 | `settingsSection(window:)`，插在 AI 话题之后、排除路径之前（`Sources/OilFindApp/SettingsWindow.swift:368`） |
| 状态栏菜单项 | `settingsMenuItem`（`Sources/OilFindApp/AppDelegate.swift:169,221-237`） |
| 额外索引源 | `searchSources() -> [SearchSource]`（`AppDelegate.swift:62`、`Snapshot.swift:150`、`SettingsWindow.swift:493`） |
| 源变化通知 | `onSearchSourcesChange`（`AppDelegate.swift:68`） |
| 内容命中叠加 | `supplementarySearchProvider`（`AppDelegate.swift:59`） |
| 独立结果分类 | `AdditionalSearchProvider`（宿主现由 `AITopicSearchProvider` 示范） |
| 外置盘只读目录 | `attachExternalDrives(ExternalDriveCatalogReading)`（`AppDelegate.swift:69`） |
| 离线索引加载 | `IndexManager(config:dbURL:volumeUUID:)` + `startOffline()`（`Sources/OilFindCore/IndexManager.swift:43,100`） |

## M0 私有扩展骨架

| # | 事项 | 要点 |
| --- | --- | --- |
| 0.1 | 建 `Pro/` 私有仓库 | 布局固定：`Pro/Sources/OilFindPro`（target 名）、`Pro/Tests/OilFindProTests`、`Pro/Sources/OilFindPro/Resources` |
| 0.2 | 实现 `OilFindProExtension` | 必填：`start` / `stop` / `languageDidChange` / `handle(_ url:)` / `settingsSection`；其余按需 |
| 0.3 | 自建本地化 | 中英文表 + `languageDidChange` 热切换 |
| 0.4 | 自建资源加载 | 显式查找 `OilFind_OilFindPro.bundle`（`Bundle.main.resourceURL` → `bundleURL` → `Bundle(for:)`），**禁用 `Bundle.module`**（1.7.0 启动崩溃根因，见 `docs/AI_TOPICS.md:79-81`） |
| 0.5 | DEBUG 参数自消费 | `Snapshot.run` 的 `allowed` 是固定集合（`Sources/OilFindApp/Snapshot.swift:12`），扩展须在 `prepareArguments` 解析并移除自己的参数，否则 `--snapshot` 报 `Invalid snapshot argument` |
| 0.6 | 免费版回归闸门 | 每次改动跑 `OILFIND_FREE=1 swift build`、`OILFIND_FREE=1 swift test --filter '…'`、`python3 Tests/Scripts/test_open_core.py` |
| 0.7 | 打包占位 | `scripts/package.sh:16-29` 强制要求 `Pro/Sources/*/License/LicenseConfig.swift` 中存在非空 `productionPublicKey`，缺失即打包失败。不做授权也要先放该文件或自写打包脚本 |

## A 离线磁盘搜索

公开核心已提供全部机制，Pro 主要是接线。

| # | 事项 |
| --- | --- |
| A.1 | 经 `attachExternalDrives` 持有 `ExternalDriveCatalogReading`：`knownDrives`（`id/name/path/enabled/isConnected/catalogURL`）+ `changes`（主线程投递） |
| A.2 | 对 `enabled && !isConnected` 的盘：`IndexManager(config:dbURL:catalogURL, volumeUUID:)` + `startOffline()`；只载入目录，不扫描、不启 FSEvents（`IndexManager.swift:100-150`） |
| A.3 | 包装为 `SearchSource(id: 盘 ID, displayName: 盘名, isOnline: false, explainPath:)` 由 `searchSources()` 交出 |
| A.4 | `onSearchSourcesChange` 通知宿主重搜；只在主线程提交来源快照 |
| A.5 | 生命周期：重插 → 撤下离线源、切回公开在线源；移除 / 逐盘关闭 / 目录删除 → 撤下并清理；启动时仅载入未连接的盘 |
| A.6 | 目录兼容：`configFingerprint` / `scopeFingerprint` 校验、`excludedExtensions` 内存过滤、`volumeUUID` 换挂载点后 `rebase(to:)` |
| A.7 | 空快照保护：`knownDrives` 在目录不可用/未发现时返回 `[]`（`ExternalDriveCatalog.swift:127-128`），不得据此清空 Pro 自身缓存 |
| A.8 | 验收：拔盘后可搜到；离线行变淡并标注未连接；拖拽与移到废纸篓禁用、复制可用；重插后恢复在线 |
| A.9 | 测试：合成 `drives.json` + 合成目录文件。注意 `ExternalDriveCatalog` 为 internal，Pro 测试只能自造 `IndexManager` + 目录文件验证 |

## B 内容索引内核（图片与文档共用）

`AITopicIndex` 不可复用（internal），但设计可整套照搬。

| # | 事项 | 参照 |
| --- | --- | --- |
| B.1 | 单文件数据库 `~/Library/Application Support/Oil Find/<pro 子目录>/index.sqlite`，目录 0700、文件 0600 | `AITopicManager.swift:44,221-224` |
| B.2 | 表结构 + 原地迁移（`columns()` 探测 + `ALTER TABLE`）；`PRAGMA data_version` + `sqlite3_total_changes64` 作缓存 epoch | `AITopicIndex.swift:97-157,620-631` |
| B.3 | **分词策略需重新设计**：现有 gram 方案是为 CJK 子串搜索设计（`AITopicIndex.swift:188-220`）；图片/文档属词/短语场景，建议 token + n-gram 组合，先评估索引膨胀 | — |
| B.4 | 候选 → 逐字节字面验证，排除跨 gram 假阳性与跨块边界匹配 | `AITopicIndex.swift:506-611` |
| B.5 | 正文 ZLIB、验证文档 LZFSE；约 64 KiB 分块写入；结果/文档 LRU 缓存与总预算上限（参照 32 MiB） | `AITopicIndex.swift:15-29,72-73,88,221-234,263-308,461-493` |
| B.6 | `PRAGMA wal_checkpoint(PASSIVE)`；首次全量后 `optimize + VACUUM`，用 `PRAGMA user_version` 做一次性门闩；只保留一份数据库 | `AITopicIndex.swift:177-187` |
| B.7 | 串行写连接 + 独立串行只读连接；维护前必须 reset 所有语句并确保不在事务内（曾因 `SQLITE_ROW` 未 reset 报锁） | `AITopicManager.swift:21-22`、`docs/AI_TOPICS.md:74` |
| B.8 | 增量同步：文件身份 = path + inode + size + mtime，判定新增 / 追加 / 重写 / 删除 / 移动 | `AITopicIndexer.swift:392-429` |
| B.9 | FSEvents：latency 0.15s + debounce 0.25s，锚定首个事件不被持续写入推后；另加 30 秒兜底 | `AITopicManager.swift:120,138,193-200` |
| B.10 | CPU 预算：从单核 25% 起步（`CLOCK_THREAD_CPUTIME_ID` 计时、单次让出 ≤10ms、让出期间仍检查取消）。**OCR/解码远重于 JSON 解析，很可能需要更低比例与更密的让出点** | `AITopicWorkBudget.swift:12,23-35`、`docs/AI_TOPICS.md:21` |
| B.11 | 取消令牌 + 单文件/单事务边界；来源枚举不完整时保留缓存、不做对账删除 | `AITopicManager.swift:208-211`、`AITopicIndexer.swift:259-277` |
| B.12 | 权限与占位：自建完全磁盘访问判断并降级；`SF_DATALESS` 云端占位目录入索引但不下探；覆盖外置卷与离线卷 | `Sources/OilFindCore/Coverage.swift:109`、`Scanner.swift:265` |
| B.13 | 状态上报：宿主无进度回调（只能轮询 `scannedCount` 或用 `onApply`），首次全量导入进度由 Pro 自己的设置分区显示 | `IndexManager.swift:64,73`、`ExternalDriveCatalog.swift:363-367` |

## C 图片内容搜索

| # | 事项 |
| --- | --- |
| C.1 | 格式范围：先做位图（png/jpg/jpeg/gif/heic/heif/webp/bmp/tiff/avif/icns/ico）；`svg/psd/ai/sketch/fig/raw(cr2/cr3/nef/arw/dng)` 先排除或明确降级（`kind=image` 全集见 `docs/ARCHITECTURE.md:143`） |
| C.2 | OCR：`VNRecognizeTextRequest`（语言集合、精度档位、revision、EXIF 方向、超大图降采样、多语言混排） |
| C.3 | 画面识别：`VNClassifyImageRequest` —— 对外承诺是"文字**与画面**"（`README.zh-CN.md:86`），不可省略 |
| C.4 | 文本规范化入库；命中高亮 `NSRange` 必须与宿主渲染坐标一致（`ResultsView.swift:81-86`） |
| C.5 | 缩略图：`SupplementaryHit(thumbnail: true)`，宿主按 path + mtime 缓存，Pro 需提供可渲染图像并控制解码开销（`ResultsView.swift:94-100`） |
| C.6 | 增量：新增 / 修改 / 删除 / 移动；可选按内容哈希去重 |
| C.7 | 跟随用户设置：排除文件夹、排除扩展名、四个索引范围开关 |
| C.8 | 能耗：电池/低电量让出、后台优先级、首次导入限速 |
| C.9 | 验收：截图搜文字命中并高亮；照片搜"收据"命中；关闭开关立即撤下命中但保留索引 |

## D 文档内容搜索

| # | 事项 |
| --- | --- |
| D.1 | 纯文本 / Markdown / RTF / CSV / TSV / log（最先打通链路） |
| D.2 | PDF：PDFKit 逐页抽取 + 页码标注（"第 3 页"）；处理加密、损坏、超大文件 |
| D.3 | 扫描版 PDF：无文本层时回退 Vision OCR（与 C.2 共用） |
| D.4 | Office：docx / xlsx / pptx（zip + XML；sheet 名、单元格、slide 序号定位） |
| D.5 | **Pages / Numbers / Keynote**：IWA + snappy 私有格式，风险最高。建议对外先只承诺 PDF + Office + Markdown/文本，Pages 走"尽力而为"，不写进对比表 |
| D.6 | 补齐 `kind=document` 其余格式：epub / mobi / odt / ods / odp / tex（`docs/ARCHITECTURE.md:142`） |
| D.7 | 分块策略：长文档按页/段切块，命中定位到页 |
| D.8 | 上限与超时：单文件大小上限、解析超时、损坏文件跳过并计数 |
| D.9 | 验收：PDF 第 3 页命中、Word/Excel 命中、扫描 PDF 命中、Markdown 命中 |

## E 与宿主搜索的集成

| # | 事项 |
| --- | --- |
| E.1 | 呈现方式：用 `SupplementarySearchProvider` 把内容命中挂到文件行（detail 显示"图片中文字: …"，thumbnail 显示缩略图）；不建议另开独立分类 |
| E.2 | 正确提供 `sourceVersion`：宿主与捕获的 `storeVersion` 比对，不一致即丢弃；`entryID` 越界与源不存在同样丢弃（`SearchPresentation.swift:131`） |
| E.3 | `prepareSearch` 主线程准备 + 返回闭包并发执行；`isCancelled` 贯穿；过期查询代次不得提交 |
| E.4 | `userActivity(visible:typing:)` 与 `backgroundIndexingChanged(busy:)` 让出资源 |
| E.5 | 排序契约：不得改变已显示的名称结果顺序；其他排序按文件键 |
| E.6 | 查询语法覆盖：`ext:` / `kind:` / `size:` / `dm:` / `path:` / `!否定` / `regex:` 与内容命中的组合 |
| E.7 | 停用或来源失效时立即撤下命中（`removingUnavailableAdditionalItems` 只作用于 additional，supplementary 需自己保证 `isEnabled == false` 或返回空） |

## F 设置与文案

| # | 事项 |
| --- | --- |
| F.1 | Pro 设置分区：总开关、图片/文档/离线磁盘分项、索引状态与进度、重建索引、清除索引 |
| F.2 | 中英文文案 + `languageDidChange` 即时刷新 |
| F.3 | 状态栏菜单项（`settingsMenuItem`），例如"重建内容索引" |
| F.4 | 覆盖率统计：`SettingsModel.additionalSources` 会带上 Pro 的 `searchSources()`（`SettingsWindow.swift:492-494`），注意别拖慢设置页 `refresh()` |

## G 测试、性能与打包

| # | 事项 |
| --- | --- |
| G.1 | `OilFindProTests`：内核 oracle 测试、合成增量同步、取消与代次、资源回归 |
| G.2 | DEBUG 验证：自己的参数在 `prepareArguments` 消费；用 `--snapshot --filter additional` 出界面快照 |
| G.3 | 免费版回归 + `test_open_core.py`（CI 会跑，模块边界不能破） |
| G.4 | 性能：内容索引后台 CPU、内存上限、首次导入耗时；**内容命中不得拖慢文件名搜索 p95**（目标见 `docs/ARCHITECTURE.md:8`） |
| G.5 | 真机验证：真实截图/照片/PDF/Office/Pages、拔盘重插、外置卷、iCloud 占位文件 |
| G.6 | 打包：`build-app.sh` 自动带上 Pro 资源；`package.sh` 需要 Pro 源码 + 生产公钥 + "Oil Find Self-Signed" 证书 + 隔离启动检查 |
| G.7 | 对外文案：README/官网对比表、隐私说明（"图片和文档都在本机处理"）、`site/content/releases.ts` 版本说明 |

## 里程碑

| 里程碑 | 内容 | 粗略工作量 |
| --- | --- | --- |
| M0 | 骨架（0）+ 免费版回归闸门 | ~1 周 |
| M1 | 离线磁盘搜索（A）→ 第一个可用 Pro 功能 | ~1–2 周 |
| M2 | 内容内核（B）+ 图片（C） | ~3–5 周 |
| M3 | 文档（D）：文本/PDF/Markdown → Office → Pages | ~3–6 周 |
| M4 | 打磨：设置（F）、性能（G4）、真机与打包（G5–G7） | ~1–2 周 |

## 开工前必须定的四件事

1. **内容命中如何呈现**：`supplementary`（挂到文件行）还是独立分类。建议 supplementary，与"文件里包含这段文字"的产品语义一致，也无需新造分类与动作。
2. **内容内核只能自建**：`AITopicIndex` 是 internal，抄设计不抄代码；B.3 的分词策略要针对词/短语场景重新评估。
3. **文档格式的野心**：Pages/Numbers/Keynote 是最大风险点，建议先只承诺 PDF + Office + Markdown/文本。
4. **打包路径**：不做授权时 `package.sh` 的前置检查会拦住打包，需占位或自写脚本。

## 边界结论

只改私有仓库即可完成全部三块功能：`ApplicationExtension` + `searchSources()` + `supplementarySearchProvider` + `IndexManager.startOffline()` 这套接口够用。

若后续需要以下能力，**必须先往公开库加中性 API**：

- 自定义结果行渲染 / 缩略图管线 / 结果合并策略（`SearchViewController`、`SearchPresentation`、`ResultsView` 均 internal）
- 把 Pro 状态并入设置页统计模型（`SettingsModel` internal）
- 在 DEBUG 快照里暴露 Pro 专属状态（`Snapshot.run` 的 `allowed` 与 `--state` 白名单写死）
- 让扩展参与外置盘生命周期（逐盘开关、推出审批、目录持久化在 internal 的 `ExternalDriveCatalog` 内）
- 共享 `L10n` / `Theme`

## 附录 A：授权现状（本期不做，接入时参考）

服务端**已在公开仓库完整实现**（`site/`），因此将来接入是"照现成契约写客户端"：

- 接口：`/api/activate`、`/api/refresh`、`/api/deactivate`、`/api/session`、`/api/checkout`、`/api/price`、`/api/recover`、`/api/webhook`；错误码全集见 `site/lib/http.ts:1-2`。
- 授权码：`OILF-<Crockford Base32>`，HMAC-SHA256 取前 6 字节，主体为 Stripe 客户 ID（`site/lib/keys.ts`）。
- 设备令牌：Ed25519 签名，`exp = 0` 表示永久；验签需用 SPKI 前缀 `302a300506032b6570032100` + 32 字节原始公钥包装（`site/lib/token.ts`、`site/test/helpers.ts:22`）。
- 设备标识必须是 32 位小写 hex；3 个槽位，第 4 台挤掉最旧（`site/lib/license.ts:20`、`site/lib/devices.ts:3`）。
- 三个必须遵守的既有约定：
  1. `Pro/Sources/*/License/LicenseConfig.swift` 的 `productionPublicKey` 是打包硬要求（`scripts/package.sh:16-29`）。
  2. 试用锚点名已被公开脚本钉死：`proEvaluationStartedAt` / `proEvaluationLastSeenAt` / `proEvaluationEndedAt` + keychain `com.oiloil.find.pro.evaluation`（`scripts/uninstall.sh:40-53`、`Tests/Scripts/test_uninstall.py:59-72`）。
  3. `Sources/OilFindApp/LegacyAuthorizationCleanup.swift` 每次启动会删除 `license.json`、keychain `com.oiloil.find.trial` 以及所有 `trial*` / `license*` 前缀的 UserDefaults 键（`AppDelegate.swift:42`）。Pro 存状态**不要**使用这些路径与前缀。
- 深链 `oilfind://activate?key=…` 的 scheme 已在 `Resources/Info.plist:19-27` 注册。

## 附录 B：常用验证命令

```sh
# 含 Pro 构建与测试（需 Pro/ 存在）
swift build
swift test

# 免费版回归
OILFIND_FREE=1 swift build
OILFIND_FREE=1 swift test --filter '<受影响的测试>'
python3 Tests/Scripts/test_open_core.py

# 调试版应用与界面快照
scripts/build-app.sh --debug
"build/debug/Oil Find.app/Contents/MacOS/OilFind" --snapshot /tmp/shot.png --filter additional
```
