# Oil Find 内容搜索设计（图片文字 + 文档文字）

日期：2026-10-19
范围：**免费功能**，做进公开仓库。
目标：搜索图片里的文字（OCR）与文档里的文字（PDF / Office / 文本类），命中挂到文件行上并定位到页 / 幻灯片 / sheet。

与 `2026-10-19-pro-features-design.md` 的关系：那份文档把这两块规划为私有 `Pro/` 能力。本次决定改为公开仓库的免费功能，因此其中 B/C/D 三节的前提（"内核只能自建"）不再成立，改用本文档。两份文档对同一批代码的**事实性修正**见第 8 节。

本文所有 `file:line` 指向 `/Users/zhuzhong/superconductor/projects/oil-find`。

## 1. 落点与复用策略

新建 `Sources/OilFindApp/ContentSearch/`，与 `AITopics/` 平级。

同在 `OilFindApp` module 内，`AITopics` 的 internal 设施可以直接改造复用，不需要重写：

| 复用对象 | 位置 |
| --- | --- |
| SQLite 封装 | `AITopics/AITopicSQL` |
| ZLIB / LZFSE 压缩 | 格式对齐 `AITopicIndex.swift:223-234`（codec 字节 0 raw / 1 LZFSE / 2 ZLIB），但独立实现。AI 话题的解码器带复用缓冲区以避开搜索路径上的分配，共用会动到它的热路径，故不抽取 |
| gram 生成 | `AITopicIndex.swift:188-220` |
| CPU 预算 | `AITopics/AITopicWorkBudget.swift`（35 行，自包含） |
| 文件监听 | `AITopics/AITopicFileWatcher.swift` |
| 串行队列编排 | `AITopics/AITopicSyncQueue.swift` |

真正通用的部分抽到 `ContentSearch/Support/` 下共用，不复制两份。

内容索引独立一个库：`~/Library/Application Support/Oil Find/content/index.sqlite`，目录 0700、文件 0600，与 AI 话题库、文件索引库分开。

### 接线点

`supplementaryProvider` 是**单槽位**（`SearchViewController.swift:48`），当前由 `appExtension?.supplementarySearchProvider` 占用（`AppDelegate.swift:59`）。新增一个多路复用器，把「内容搜索」与「Pro 扩展」两个 provider 合并，不抢占 Pro 的槽位。

## 2. 文件身份：存路径，不存 entryID

**这是本设计最关键的一条约束。**

`entryID` 不是文件身份，而是文件在 `IndexStore` SoA 数组里的**下标**：`insert` 用 `UInt32(count)` 作新 id 并追加（`IndexStore+Mutation.swift:105-108`）。

- 平时稳定：`insert` 只追加；`remove(i)` 只打 `SiftFlag.deleted` 墓碑、不移动元素（`IndexStore+Mutation.swift:164-168`）
- **但会整体重排**：`compacted()`（`IndexStore+Mutation.swift:175-199`）把所有活条目重新连续编号。触发条件 `deletedCount > max(100_000, count/4)`（`:174`），且**自动触发**（`IndexManager.swift:271`、`:355-357`）。全量 `rescan()` 更是从头重建。

若内容索引存 entryID，压实之后：

- 该 id 变成墓碑 → 宿主 `isLive(hit.entryID)` 校验失败（`SearchPresentation.swift:140`）→ 命中静默消失
- 更糟：该 id 仍活着但已指向**另一个文件** → 命中挂到错误的文件上

`sourceVersion` 挡不住这个：它防的是"快照过期"，不是"编号重排"——重排后内容索引自己记录的 version 也会更新，看起来一致。

**结论**：内容索引存**绝对路径**；查询时用 `store.resolve(path:)`（`IndexStore+Mutation.swift:44`，public）解析成**当前** entryID。代价是每条命中一次逐层哈希查找，可忽略。

**衍生问题**：路径本身也会变（外置盘换挂载点 `/Volumes/X` → `/Volumes/X 1`，文件被移动）。文件索引侧由 `IndexManager.swift:132` 的 `rebase(to:)` 处理；内容索引侧需要做同样的处理，否则拔盘重插后内容命中全部失效。

## 3. 索引内核

### 表结构

```sql
CREATE TABLE files(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    path TEXT NOT NULL UNIQUE,     -- 文件身份，见第 2 节
    size INTEGER NOT NULL,
    mtime INTEGER NOT NULL,
    kind INTEGER NOT NULL,         -- 3 = document, 4 = image
    parser TEXT NOT NULL,          -- text/pdf/docx/xlsx/pptx/ocr + revision
    revision INTEGER NOT NULL DEFAULT 1);

CREATE TABLE chunks(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,      -- 页号 / slide 序号 / sheet 序号 / 段序
    label TEXT NOT NULL,           -- "第 3 页" / "第 2 张幻灯片" / "Sheet1"
    folded BLOB NOT NULL,          -- 归一化文本（LZFSE 压缩）
    bytes INTEGER NOT NULL);

CREATE VIRTUAL TABLE chunk_fts USING fts5(grams, content='', contentless_delete=1, detail=none);
```

`AUTOINCREMENT` 不是随手加的：FTS 行以 `chunks.id` 为 key，普通 `INTEGER PRIMARY KEY` 在删除后会复用 rowid，一个新块可能继承旧块的编号，让残留 posting 挂到错误的文本上。`AUTOINCREMENT` 保证编号单调不复用。代价是多一张 `sqlite_sequence`。

迁移用 `PRAGMA user_version` 打版本号：版本不符就丢弃重建，不走 `ALTER TABLE`。

`AITopicIndex` 用 `columns()` 探测 + `ALTER TABLE` 原地迁，是因为那里存的是用户的 AI 对话正文，丢了不可恢复。内容索引是**派生数据**，能从文件重建，所以版本不符直接重建更简单也更可靠——`ALTER TABLE` 只能补列，修复不了类型不符、缺 `UNIQUE`、`chunk_fts` 选项不对这类漂移。重建在同一个 `BEGIN IMMEDIATE` 事务里完成，两个写连接同时首次打开也只会有一次重建。

### 分块策略

按格式走，**不整篇一块**：

| 格式 | 分块单位 | label 示例 |
| --- | --- | --- |
| PDF | 每页 | 第 3 页 |
| pptx | 每张幻灯片 | 第 2 张幻灯片 |
| xlsx | 每个 sheet（大表再按行段切） | Sheet1 |
| docx | 段落累计到 32–64 KiB | 第 3 段附近 |
| txt/md/csv/tsv/log/rtf | 按行累计到 32–64 KiB | 第 1200 行附近 |

分块有三个作用：

1. **定位**——命中要能说"第 3 页"，这是功能卖点
2. **压住 gram 基数**——gram 集合按块去重。500 页 PDF 整篇一块，distinct bigram 接近饱和，块内 gram 数暴涨；按页切则各页独立去重，总量更小更均匀
3. **增量**——删除 / 替换以块为单位

### 分词

沿用 `AITopics` 的 gram 方案（unigram + bigram + ASCII trigram，按块去重后写入 FTS5，见 `AITopicIndex.swift:188-220`）。理由：该方案已在本仓库验证过中文子串搜索，而用户对文件名搜索的预期就是"子串能中"，内容搜索应保持同一语义。

**这是本设计唯一需要实测的地方**（见第 7 节风险）。

### 增量同步

文件身份 = **path + size + mtime**。

修正：`2026-10-19-pro-features-design.md` 的 B.8 写"path + inode + size + mtime"，但 `IndexStore` 不存 inode（字段只有 `sizeC`/`mtime`/`flags`/`depth`/`kind`），取 inode 要额外 `stat`，对网络卷还不可靠。故用 path + size + mtime。

判定新增 / 修改 / 删除。来源枚举不完整时保留缓存、不做对账删除。

### 候选枚举

直接从文件索引扫 `kind == 3/4` 的活条目，**不重新走文件系统**——现有索引范围、排除文件夹、排除扩展名全部自动继承。

注意**分批读取**：`IndexStore` 的读锁（`IndexStore.swift:50`）会阻塞文件索引的写入与压实，不能持锁扫一百万条。

### CPU 预算

复用 `AITopicWorkBudget`，但比例从 0.25 下调——OCR 与 PDF 解码远重于 JSON 解析。起步 0.10，让出点更密。

## 4. 解析层

```swift
protocol ContentParser {
    func parse(url: URL, budget: WorkBudget, isCancelled: () -> Bool) throws -> [ContentChunk]
}
struct ContentChunk { let ordinal: Int; let label: String; let text: String }
```

### 图片：Vision OCR

- `VNImageRequestHandler(url:)` 自动处理 EXIF 方向
- `VNRecognizeTextRequest`：`recognitionLevel = .accurate`、`recognitionLanguages = ["zh-Hans", "en-US"]`
- revision 固定并记进 `files.parser`；换 revision 结果会变，需能识别并重建
- 长边超阈值先降采样再 OCR

**已知限制**：`perform` 同步阻塞，单张图内部无法让出 CPU。预算控制只能到"每张图之间"的粒度，一张 50MP 照片可能几百毫秒不让出。这是本功能唯一无法做精细的地方；缓解办法是先降采样、压住单张耗时。

格式范围：`CGImageSource` 能解的（png/jpg/jpeg/gif/heic/heif/webp/bmp/tiff/avif/icns/ico）。svg/psd/ai/sketch/fig/raw 排除（`docs/ARCHITECTURE.md:143` 的 `kind=image` 全集减去这些）。

画面识别（`VNClassifyImageRequest`）**本版不做**：其标签为英文（`receipt`/`dog`），中文查询命中不了，需额外维护中英映射表。

### 文档

| 格式 | 做法 |
| --- | --- |
| txt / md / markdown / csv / tsv / log | 编码探测：UTF-8 → UTF-16 → **GB18030 回退**（中文老文件常为 GBK） |
| rtf | `NSAttributedString` 直接读 |
| doc / docx | `NSAttributedString` + `.officeOpenXML`（`.doc` 走 `NSDocFormat`）。`NSOfficeOpenXMLTextDocumentType` 已确认存在于 SDK（`AppKit/NSAttributedString.h:271`，macOS 10.5+），**不需要自己解 zip** |
| PDF | `PDFDocument` 逐页 `page.string`；加密 / 损坏捕获跳过；`page.string` 为空 → 回退 Vision OCR（扫描版），与图片管线共用 |
| xlsx / pptx | 自己解 zip + `XMLParser` |

xlsx/pptx 是唯一需要从零造轮子的地方：最小 zip reader（EOCD + 中央目录 + local header，method 0 stored / 8 deflate 走 `compression_decode_buffer`），约 150–200 行。项目约定不引第三方包，故手写。需实测确认 Apple 的 `COMPRESSION_ZLIB` 是否就是 zip method 8 所需的 raw deflate；若带 zlib 头则手动跳过前 2 字节。

`kind=document` 其余格式（epub/mobi/odt/ods/odp/tex）本版不做。

### 统一约定

单文件大小上限、解析超时、损坏文件跳过并计数（不中断整批）。

## 5. 搜索集成与呈现

`ContentSearchProvider: SupplementarySearchProvider`。

`prepareSearch` 在主线程被调用（只做准备），返回的闭包在宿主 `supplementQueue` 上并发执行（`SearchViewController.swift:291-293`），与文件名搜索并行。

闭包流程：

1. 从 query 取检索词 → 查 `chunk_fts` 得候选 chunk
2. **逐字节字面验证**，排除跨 gram 假阳性（沿用 `AITopics` 做法）
3. 候选 chunk → 文件 path
4. path → `(sourceID, entryID)`：遍历传入的 `sources`，`source.store.read { resolve(path:) }`
5. 同一文件多 chunk 命中 → 只出一行，detail 显示最相关的一处

### 关键点：内容命中能凭空出现

`SearchPresentation.supplement` 会把**不在名称结果中**的命中 append 成新行（`SearchPresentation.swift:137-152`）。所以文件名不含查询词、但内容含的文件会真的出现在列表里——这是功能成立的前提。

### detail 与高亮

detail 形如 `图片中文字: …片段…` 或 `第 3 页: …片段…`。

`highlights: [NSRange]` 必须是**你自己那段 text 内部**的 UTF-16 坐标。`ResultsView.swift:81-86` 先把 `decoration.text + " · "` 拼接再直接拿 highlights 染色，越界的会被 `NSMaxRange(range) <= text.length` 静默跳过——算上拼接部分就会整体错位。

### sourceVersion

在**同一个读锁内**读 `store.version`（`IndexStore.swift:12`）并完成 path→entryID 解析，然后用该 version 盖戳。中途文件索引变化时，宿主按 `SearchPresentation.swift:139` 的不匹配丢弃命中。

### 排序契约与 UX 后果

宿主把内容命中 append 在名称命中**之后**（`SearchPresentation.swift:150-152`），relevance 模式下内部按 mtime 倒序，不做全局重排。

因此搜"收据"时，"图里写着收据"永远排在"文件名含收据"之后。这是宿主既定契约，不改公开库动不了。对文件搜索工具而言合理。

### 撤下

关掉总开关 → `isEnabled = false` → 宿主走 `withoutSupplements()` 自动撤下（`SearchViewController.swift:87`）。索引重建期间保证不返回过期命中。

### 性能红线

不得拖慢文件名搜索 p95（`docs/ARCHITECTURE.md:8`）。内容查询走独立只读连接 + LRU 缓存。

## 6. 设置、验证与里程碑

### 设置分区

接在 `AITopicSettings` 那个 Section 之后（`SettingsWindow.swift:368-369`），新增 `Section { ContentSearchSettings(manager: content) }`，写法照抄 `AITopicSettings`。

内容：总开关、图片 / 文档分项开关、索引进度、磁盘占用、重建索引、清除索引。

比 `2026-10-19-pro-features-design.md` 的 B.13 简单：那里担心"宿主无进度回调只能轮询 `scannedCount`"，说的是复用宿主的 `IndexManager`；内容索引是我们自己的 manager，直接 `@Published` 即可。

### 文案

`L10n.swift` 加中英对照键。`L10n` 是 internal，同 module 可直接用。

### DEBUG 验证不需要改 `Snapshot`

`Snapshot.run` 的 `allowed` 集合写死在 `Snapshot.swift:12`，但现成参数够用：

```sh
"build/debug/Oil Find.app/Contents/MacOS/OilFind" --snapshot /tmp/hit.png --query 收据
"build/debug/Oil Find.app/Contents/MacOS/OilFind" --snapshot /tmp/settings.png --state settings --settings-scroll 0.3
```

前者出内容命中界面，后者出设置分区。省掉一处公开库改动。

`--settings-scroll` 收的是 **0…1 的滚动比例**，不是分区名（`Snapshot.swift:130` 用 `Double(value)` 解析，传分区名会报 `Invalid settings scroll fraction`）；内容分区在 AI 话题之后，先取 `0.3`，看不全再调大。

### 测试（放 `Tests/OilFindUITests`，代码在 `OilFindApp` 内）

1. 解析器单测：合成 docx/xlsx/pptx/PDF 夹具，验证抽出文本与 `label`
2. 内核 oracle：写入 → 检索 → 验证命中与定位标签
3. 增量同步：新增 / 修改 / 删除后重跑，验证块数变化
4. **压实后解析仍正确**——造索引、触发 `compacted()`、验证 path→entryID 仍指得对（直接覆盖第 2 节的关键点）
5. 取消与代次、资源回归（1.7.0 的 `Bundle.module` 崩溃教训，`docs/AI_TOPICS.md:79-81`）
6. 免费版回归闸门：`OILFIND_FREE=1 swift build`、`OILFIND_FREE=1 swift test`、`python3 Tests/Scripts/test_open_core.py`

CI 通过 `CI=true` 跳过时间敏感或依赖本机真实索引的测试。

### 里程碑

| | 内容 | 理由 |
| --- | --- | --- |
| M1 | 内核 + 图片 OCR + 纯文本/Markdown | 两个功能各通一条最短路径，立刻可见效果；图片单张文本少，先不碰 gram 膨胀 |
| M2 | PDF（含扫描版回退 OCR）+ 页码定位 | 文本量大，gram 体积门限在此实测 |
| M3 | docx | 走系统 API，最便宜 |
| M4 | xlsx / pptx | 手写 zip reader，放最后 |

## 7. 风险与门限

| 风险 | 说明 | 应对 |
| --- | --- | --- |
| **gram 索引膨胀** | 文档文本量远大于 AI 对话，gram 索引可能显著膨胀 | M2 加体积门限测试：索引体积 ÷ 原文体积超阈值即退到"高频 token + 短 gram 混合" |
| 首次索引耗时 | 图片数量可能上万，OCR 是重活 | 后台低优先级、限速、预算 0.10；设置页显示进度 |
| 单张图无法让出 | Vision `perform` 同步阻塞 | 先降采样，压住单张耗时 |
| 压实后命中错挂 | entryID 重排 | 存路径 + 查询时解析（第 2 节）；专项测试覆盖 |
| 路径漂移 | 外置盘换挂载点 | 内容索引做与 `rebase(to:)` 等价的处理 |
| zip 解析 | xlsx/pptx 需手写 | 放 M4，独立可砍 |

## 8. 对 `2026-10-19-pro-features-design.md` 的修正

| 原文 | 实际情况 |
| --- | --- |
| "`AITopic*` 全部 internal，不能复用代码" | `AITopicIndex`（`init`/`count`/`search`）、`AITopicIndexer`（`refresh`/`refreshMetadata`/`refreshHistory`）、`AITopicLocations`、`AITopic`、`AITopicProvider`、`AITopicSearchResult` 均为 public。真正 internal 的是 `AITopicIndex` 的**写入路径**（`transaction`/`upsert`/`message`，`AITopicIndex.swift:249-383`），以及 `AITopicProvider` 是封闭枚举。结论（不能直接复用为图片/文档索引）仍成立，但理由不同 |
| B.8 文件身份含 inode | `IndexStore` 不存 inode，用 path + size + mtime |
| A.2 写 `IndexManager(config:dbURL:catalogURL, volumeUUID:)` | 实际签名是 `init(config:dbURL:volumeUUID:settingsDefaults:)`（`IndexManager.swift:43`），无 `catalogURL` 形参；`ExternalDriveInfo.catalogURL` 就是那个 `dbURL` |
| 0.7 打包只缺 `LicenseConfig.swift` | `scripts/package.sh:8-13` 有四道闸门：`Pro/Sources` 存在、`OILFIND_FREE` 未设、`productionPublicKey` 非空、钥匙串有 `"Oil Find Self-Signed"` 证书 |
| D.5 建议 Pages 不写进对比表 | `README.zh-CN.md:88` 已对外承诺 Pages，两者冲突，需先对齐 |

## 附录：验证命令

```sh
swift build
swift test
OILFIND_FREE=1 swift build
OILFIND_FREE=1 swift test --filter '<受影响的测试>'
python3 Tests/Scripts/test_open_core.py

scripts/build-app.sh --debug
"build/debug/Oil Find.app/Contents/MacOS/OilFind" --snapshot /tmp/hit.png --query 收据
"build/debug/Oil Find.app/Contents/MacOS/OilFind" --snapshot /tmp/settings.png --state settings --settings-scroll 0.3
```
