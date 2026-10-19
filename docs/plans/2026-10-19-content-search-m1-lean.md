# 内容搜索 M1 实施计划（精简版）

> **本文件取代 `2026-10-19-content-search-m1.md` 的 Task 4–11 部分。**
> 原文件冻结为 Task 1–3 的完成记录；需要看某个符号的完整函数体时再去查它，但**不要同时维护两份**。

**Goal:** 让 Oil Find 能按图片里的文字和纯文本/Markdown 文件里的文字搜索，命中挂到文件行上并高亮。

**Architecture:** `Sources/OilFindApp/ContentSearch/`，与 `AITopics/` 平级，同在 `OilFindApp` module 内，复用其 SQLite 封装、gram 生成与 CPU 预算。独立一个 SQLite 库存 `files` / `chunks` / `chunk_fts`。查询时从 gram 索引取候选、逐字节字面验证，再把文件**路径**解析成文件索引当前的 entryID，通过 `SupplementarySearchProvider` 挂到结果行。

**Tech Stack:** Swift 5、SQLite3（系统库）、Vision、AppKit、XCTest。不引第三方包。

**设计依据:** `docs/plans/2026-10-19-content-search-design.md`

---

## 怎么用这份计划

这份计划只写**契约**：文件路径、类型与函数签名、不变量、验收测试名。**没有函数体**，实现由执行者写。

执行纪律（这三条是这份精简版存在的理由）：

1. **实现时发现计划有错，只改代码，不要回头改这份计划。** 只有当缺陷影响**尚未开始**的任务时才更新本文件，且只改那一段。
2. **验证按阶段跑，不按 step 跑。** `swift build` 增量约 1 秒，`swift test --filter Content` 约 2 秒，所以一个 Task 内不必每步都跑；但**每个 Task 结束必须跑一次免费版闸门**。
3. **一个 Task 一个提交。** 不要 `git add -A`（本仓库不提交构建产物与本机索引，`Pro/` 必须保持未跟踪）。

验收测试名是硬契约：**测试名必须与本文一致**，这样 `--filter` 命令和 M1 完成标准才对得上。

---

## 全局不变量

违反其中任何一条都会造成静默错误，务必先读：

1. **内容索引存绝对路径，不存 entryID。** `entryID` 是 `IndexStore` SoA 数组下标，`compacted()`（`IndexStore+Mutation.swift:175-199`）会整体重排。存 id 会让命中在压实后挂到**另一个文件**上。查询时用 `store.resolve(path:)` 解析成当前 entryID。
2. **`files.id` 与 `chunks.id` 都是 `AUTOINCREMENT`。** FTS posting 以 `chunks.id` 为 key，普通 rowid 删除后会复用，新块会继承旧块编号。
3. **元数据与块必须一起提交。** 一律用 `store(file:chunks:)`，不要自己拼 `upsert` + `replaceChunks`：`plan` 靠 `size/mtime/parser` 判断是否需要重解析，只提交元数据会让该文件此后永远被跳过，留下搜得到、其实已不存在的旧文本。
4. **对外错误类型只有 `ContentIndexError`。** `AITopicStatement.next()` 抛的是共享封装层的 `AITopicError`，所以实现代码里的 `next()` 一律走 `ContentIndex.step(_:)`，不要直接 `try statement.next()`。测试里直接操作语句可以例外。
5. **gram 必须来自 folded 文本。** 用 `AITopicIndex.fold` 后再 `grams`，否则匹配会区分大小写（`AITopicIndex.swift:274` 建文档 gram 时 fold，`:618` 建查询 gram 时也 fold）。
6. **CPU 预算 0.10**，不是 AITopics 的 0.25：OCR 与解码远重于 JSON 解析。
7. **不得拖慢文件名搜索 p95**（`docs/ARCHITECTURE.md:8`）。内容查询走独立只读连接。
8. **`highlight` 的 `NSRange` 必须是 detail 字符串内部的 UTF-16 坐标。** `ResultsView.swift:81-86` 直接拿它染色，越界的会被静默跳过；拼了前缀就要整体加偏移。
9. **测试放 `Tests/OilFindUITests/`**（代码在 `OilFindApp` 内，需要 `@testable import OilFindApp`）。CI 通过 `CI=true` 跳过时间敏感或依赖本机真实索引的测试。
10. **`OILFIND_FREE=1` 下内容搜索仍然存在**（它是免费功能），只有 Pro 扩展被排除。

## 验证命令

```sh
swift build
swift test --filter Content
OILFIND_FREE=1 swift build
OILFIND_FREE=1 swift test --filter Content
python3 Tests/Scripts/test_open_core.py
```

界面验证（`--settings-scroll` 收的是 **0…1 的滚动比例**，不是分区名；传字符串会报 `Invalid settings scroll fraction`）：

```sh
scripts/build-app.sh --debug
"build/debug/Oil Find.app/Contents/MacOS/OilFind" --snapshot /tmp/content-settings.png --state settings --settings-scroll 0.78
```

`0.78` 是实测值：内容分区排在 AI 话题之后，`0.3` 只到「外置磁盘」。

**`--query` 出不了内容命中界面**（本节原先写的 `--query 发票` 是错的）：`Snapshot.swift:148` 直接赋 `appExtension?.supplementarySearchProvider`，从不安装多路复用器，免费版下 `appExtension` 为 nil，快照里根本没有 supplementary provider。要出图得先让 `Snapshot` 装上 provider（公开库改动），M1 未做。

---

## 已完成：Task 1–3（不需要重做，读一遍即可）

**Task 1 — gram 让出变体 + 压缩辅助**
- `Sources/OilFindApp/AITopics/AITopicIndex.swift`：`grams(_:query:checkpoint:)` 由 `private` 放开为 `static`（`AITopicIndex.swift:192`）。
- `Sources/OilFindApp/ContentSearch/Support/ContentCompression.swift`：`ContentCompression.pack(_:compact:) -> Data`、`unpack(_:bytes:) throws -> Data`、`maxBodyBytes = 16 * 1024 * 1024`。codec 字节 0 raw / 1 LZFSE / 2 ZLIB。**无校验和**（索引是派生数据，可重建）。
- 测试：`ContentSearchSupportTests`（7 个，含 `testGramCheckpointIsCalledAndCancellationPropagates`）。

**Task 2 — 内容索引表结构与迁移**
- `Sources/OilFindApp/ContentSearch/ContentIndex.swift`：`ContentIndexError`、`ContentChunk`、`ContentFileRecord`、`ContentIndex`（`schemaVersion = 1`、`defaultURL`、`usesWAL`、`statement(_:)`、`count()`）。
- 迁移：`PRAGMA user_version` 不符即**丢弃重建**（不走 `ALTER TABLE`），全程在 `BEGIN IMMEDIATE` 内，两个写连接并发首开只重建一次。读连接遇到版本不符直接抛错，不静默跑空表。
- 表结构见下方「Task 4 依赖的既有 schema」。
- 迁移锁重试按**墙钟 2 秒**设上限（不是次数），非 BUSY 错误立即抛出。

**Task 3 — 写入文件与块**
- 同一文件新增：`step(_:)`、`run(_:)`、`file(path:) -> (record:id:revision:)?`、`upsert(file:)`、`store(file:chunks:)`、`replaceChunks(file:chunks:)`、`bindBlob(_:at:into:)`、`chunkCount(file:)`、`removeFile(path:)`、`removeFiles(prefix:)`、`transaction(_:)`。
- `Tests/OilFindUITests/ContentTestSupport.swift`：`removeContentDatabase(_:)`（清 WAL sidecar）、`makeContentDatabaseURL()`。
- 测试：`ContentIndexWriteTests`（14 个）。

**Task 4 依赖的既有 schema**（`ContentIndex.migrate()` 内，勿改）：

```sql
files(id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL UNIQUE, size, mtime,
      kind INTEGER NOT NULL, parser TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1)
chunks(id INTEGER PRIMARY KEY AUTOINCREMENT, file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
       ordinal INTEGER NOT NULL, label TEXT NOT NULL, folded BLOB NOT NULL,
       bytes INTEGER NOT NULL CHECK(bytes BETWEEN 0 AND 16777216), UNIQUE(file, ordinal))
CREATE VIRTUAL TABLE chunk_fts USING fts5(grams, content='', contentless_delete=1, detail=none)
CREATE TRIGGER chunk_postings_delete AFTER DELETE ON chunks BEGIN DELETE FROM chunk_fts WHERE rowid = old.id; END
```

---

## Task 4: 检索与字面验证

**Files:**
- Modify: `Sources/OilFindApp/ContentSearch/ContentIndex.swift`
- Test: `Tests/OilFindUITests/ContentIndexSearchTests.swift`

**接口**

```swift
struct ContentHit {
    let path: String
    /// File-index kind (3 = document, 4 = image); the provider uses it to decide thumbnails.
    let kind: UInt8
    let label: String
    let snippet: String
    let highlights: [NSRange]
}

extension ContentIndex {
    func search(_ text: String, limit: Int, isCancelled: () -> Bool) throws -> [ContentHit]
    private static func byteRanges(of needle: [UInt8], in haystack: [UInt8]) -> [Range<Int>]
    private static func snippet(text: String, terms: [String], before: Int = 40, after: Int = 60)
        -> (text: String, highlights: [NSRange])
    private func blob(_ statement: AITopicStatement, _ column: Int32) -> Data
}
```

**不变量与约束**

- 前置：`guard limit > 0, !terms.isEmpty else { return [] }`。
- 查询串：每个 term 的 gram 集合用 `" AND "` 连接，去重排序后再用 `" AND "` 拼；`guard !query.isEmpty else { return [] }`。注意 `grams` 会抛错，不能在 `flatMap` 里无 `try` 调用。
- **gram 的 AND 会给出跨 gram / 跨块的假阳性，必须逐字节字面验证**：每个 term 都要 `byteRanges(...)` 非空才接受该行。
- 某行 body 为 NULL 或解不开时 `continue` 跳过，**不得**中断整个查询。
- `byteRanges` 非重叠（命中后 `i += needle.count`）；不可能从多字节 scalar 中间开始匹配（合法 UTF-8 前导字节永远不是续字节）。
- `snippet` 的 `before` / `after` 计的是 **UTF-16 单元，不是字符**；range 必须在解码后的文本上算（字节偏移与 UTF-16 偏移不线性对应）；高亮最多收集 20 个；只保留落在展示窗口内的。
- 同文件多块命中只出一行：保留 highlights 最多的那块。
- 排序与上限：`best.values.sorted { $0.path < $1.path }`（路径升序）；`if best.count >= limit { break }`。
- 取消：`if isCancelled() { return [] }`，返回空而不是部分结果。

**验收测试**（`ContentIndexSearchTests`）

- `testFindsChineseSubstringWithLabelAndHighlight` — 1 条命中，path/label 正确，高亮 range 取出的子串是 `"发票"`。
- `testIsCaseInsensitiveAndFindsEnglish` — `"invoice"` 与 `"INVOICE"` 各命中 1 条。
- `testDoesNotReportMatchesThatOnlyExistAcrossChunkBoundaries` — `"收据"` 被拆到两个块时结果为空。
- `testReturnsEachFileOnceWithItsBestChunk` — 同文件两块命中只出 1 行。
- `testRespectsLimitAndCancellation` — limit 5 出 5 条；取消后为空。

**验证**：`swift test --filter ContentIndexSearchTests` → 先编译失败（`has no member 'search'`），后 PASS。
**提交**：`feat(content): search chunks with byte-level verification`

---

## Task 5: 增量同步

**Files:**
- Modify: `Sources/OilFindApp/ContentSearch/ContentIndex.swift`
- Test: `Tests/OilFindUITests/ContentIndexSyncTests.swift`

**接口**

```swift
extension ContentIndex {
    struct SyncPlan {
        var added: [ContentFileRecord] = []
        var changed: [ContentFileRecord] = []
        var unchanged: [ContentFileRecord] = []
        var removed: [String] = []
    }

    /// `complete` is false when the candidate enumeration could not finish, in which case nothing is deleted.
    func plan(candidates: [ContentFileRecord], complete: Bool = true) throws -> SyncPlan
    /// `parse` returns nil when the file could not be parsed.
    func apply(_ plan: SyncPlan, parse: (ContentFileRecord) -> [ContentChunk]?) throws
}
```

**不变量与约束**

- 分类：`size`、`mtime`、`parser` 三者全等才算 `unchanged`，否则 `changed`；无既有行则 `added`。
- `removed` 只在 `complete == true` 时算（扫 `SELECT path FROM files`，收集不在 `seen` 集合里的路径）。**枚举不完整时绝不删除**，否则一次取消会清空索引。
- Swift 有 `for ... where` 但没有 `while ... where`，删除扫描的写法要绕开这一点。
- `apply` 顺序：**先删**（`plan.removed`），再处理 `plan.added + plan.changed`。
- `parse` 返回 `nil`（解析失败）时**保持既有行不动**，不要把内容替换成空——否则一次瞬时失败（取消、文件被锁）会抹掉此前成功索引的内容。返回空数组是另一回事：文件解析成功且确实没有文本，应当清空。
- 失败的记录必须保留旧元数据，否则下次会被判成 `unchanged` 而永不重试。

**验收测试**（`ContentIndexSyncTests`）

- `testDetectsNewChangedAndRemovedFiles` — unchanged `[/a/1.txt]`、changed `[/a/2.txt]`、added `[/a/3.txt]`、removed `[]`。
- `testIncompleteEnumerationNeverDeletes` — `plan(candidates: [], complete: false).removed` 为空且 `count()` 仍为 1。
- `testApplyLeavesAFailedFileAlone` — parse 返回 nil 后 `chunkCount(file:) == 1` 且记录 `mtime == 1`。
- `testApplyStoresEmptyResultsAndClearsOldChunks` — parse 返回空数组后 `chunkCount == 0` 且 `record.size == 2`。

**验证**：`swift test --filter ContentIndexSyncTests` → 先失败（`has no member 'plan'`），后 PASS。
**提交**：`feat(content): diff file system snapshot against the index`

---

## Task 6: 图片 OCR 解析器

**Files:**
- Create: `Sources/OilFindApp/ContentSearch/Parsers/ContentParser.swift`
- Create: `Sources/OilFindApp/ContentSearch/Parsers/ImageOCRParser.swift`
- Test: `Tests/OilFindUITests/ImageOCRParserTests.swift`

**接口**

```swift
/// A format-specific text extractor. `ordinal` and `label` locate a chunk inside the document.
protocol ContentParser {
    /// Stable identifier stored in `files.parser`; changing it invalidates indexed rows.
    var identifier: String { get }
    /// File-index kinds this parser handles: 3 = document, 4 = image.
    var kinds: Set<UInt8> { get }
    /// Lowercased extensions, or `["*"]` for every file of those kinds.
    var extensions: Set<String> { get }
    func parse(url: URL, budget: AITopicWorkBudget, isCancelled: () -> Bool) throws -> [ContentChunk]
}

enum ContentParserError: Error { case unsupported, tooLarge, damaged }

/// Vision text recognition. Revision is part of the identifier so a revision change reindexes.
struct ImageOCRParser: ContentParser {
    static let revision = VNRecognizeTextRequestRevision3
    /// Formats `CGImageSource` can decode. SVG, PSD, AI and camera raw are deliberately absent.
    static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp",
                                                   "bmp", "tif", "tiff", "avif", "icns", "ico"]
    static let maximumDimension: CGFloat = 3000
    var identifier: String { "ocr-\(Self.revision)" }
    var kinds: Set<UInt8> { [4] }
    var extensions: Set<String> { Self.supportedExtensions }
    func parse(url: URL, budget: AITopicWorkBudget, isCancelled: () -> Bool) throws -> [ContentChunk]
}
```

**不变量与约束**

- `identifier` 里含 revision，**换 revision 必须能触发重建**（`files.parser` 变了 → `plan` 判为 `changed`）。
- 请求参数：`recognitionLevel = .accurate`、`recognitionLanguages = ["zh-Hans", "en-US"]`、`usesLanguageCorrection = true`。
- **降采样**：长边超过 `maximumDimension`（3000）先缩。理由：识别耗时随像素数增长，而 `perform` 同步阻塞、单张图内部无法让出 CPU——这是本功能唯一无法精细控制的地方，只能靠降采样压住单张耗时。
- 降采样时用 `kCGImageSourceCreateThumbnailWithTransform` 生成 `CGImage`：传 `CGImage` 会绕过 Vision 自己的 EXIF 处理，所以旋转必须在缩略图阶段做掉；拿不到缩略图时回退 `VNImageRequestHandler(url:)`。
- **取消必须在跑 Vision 之前检查，且抛 `ContentParserError.cancelled`，不返回 `[]`**（`guard !isCancelled() else { throw ContentParserError.cancelled }`）。返回 `[]` 的语义是"解析成功且确实没有文本"，同步层会据此清空该文件已索引的内容、写入当前元数据，此后该文件被判为 `unchanged` 而永不重解析——取消因此会静默且永久地抹掉内容。抛错则保留既有行并留待重试。
- 预算控制粒度只能到"每张图之间"，实现里不要假装能更细。

**验收测试**（`ImageOCRParserTests`；`CI == "true"` 时除取消测试外全部 `XCTSkip`）

- `testRecognizesChineseTextInAScreenshot` — 恰好 1 块，ordinal 0，文本含 `"发票"`。
- `testImageWithoutTextProducesNoChunks` — 空白图返回空数组。
- `testCancellationStopsBeforeRunningVision` — 取消后返回空，且不需要 Vision 运行时。
- `testDownsamplesVeryWideImages` — 4200x600 的图仍能出首块且含 `"发票"`。

**验证**：`swift test --filter ImageOCRParserTests` → 先失败（`cannot find 'ImageOCRParser' in scope`），后 PASS。
**提交**：`feat(content): extract text from images with Vision`

---

## Task 7: 纯文本 / Markdown 解析器

**Files:**
- Create: `Sources/OilFindApp/ContentSearch/Parsers/TextParser.swift`
- Test: `Tests/OilFindUITests/TextParserTests.swift`

**接口**

```swift
struct TextParser: ContentParser {
    var maximumBytes = 32 * 1024 * 1024
    var chunkBytes = 64 * 1024
    var identifier: String { "text-1" }
    var kinds: Set<UInt8> { [3] }
    var extensions: Set<String> { ["txt", "md", "markdown", "csv", "tsv", "log"] }
    func parse(url: URL, budget: AITopicWorkBudget, isCancelled: () -> Bool) throws -> [ContentChunk]
    static func decode(_ data: Data) throws -> String
}
```

**不变量与约束**

- 大小门限：`guard data.count <= maximumBytes else { throw ContentParserError.tooLarge }`。**必须先把文件 map 出来、用映射长度判断**，不能读文件属性里的 size——属性拿不到时会静默变成 0，放一个几 GB 的文件进 `String(data:encoding:)`。
- 解码顺序**必须**是 UTF-8 → UTF-16 → GB18030，且 **UTF-16 只在有 BOM（`[0xFF,0xFE]` 或 `[0xFE,0xFF]`）时才接受**：无 BOM 时几乎任何字节串都能"解码"成 UTF-16 乱码，会静默盖掉正确的 GB18030 结果。代价是无 BOM 的 UTF-16 文件按 GB18030 读——这是更少见的情况，可接受。
- 三种解码都失败 → 抛 `ContentParserError.damaged`。
- 解码结果为空 → 返回 `[]`。
- 分块：按 `"\n"` 切（`omittingEmptySubsequences: false`）；`buffer.utf8.count + piece.utf8.count + 1 > chunkBytes` 时先 flush；每块 label 是 `"第 \(firstLine) 行附近"`。
- 每行调用一次 `budget.checkpoint(isCancelled: isCancelled)`；`isCancelled()` 为真**抛 `ContentParserError.cancelled`**，理由同 Task 6（返回 `[]` 会永久抹掉已索引内容）。
- **单行超过 `chunkBytes` 时必须自行切分**：flush 条件是先判断后追加、且要求 buffer 非空，所以一行超长时永远不 flush，整行会变成一个块。超过 `ContentCompression.maxBodyBytes`（16 MiB）的块会被 `replaceChunks` 抛错，而该抛错来自 `apply` 内部、`ContentParser.parse` 已经正常返回，因此 `failedCount` 不计、整个 `synchronize` 中断，且**每次同步都在同一文件上重演**——索引永远建不完。切分必须按 `Character` 边界，不能按字节。
- 行分隔用 `split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })`。Swift 把 `"\r\n"` 视为**单个 `Character`**，所以按 `"\n"` 切**根本切不开 CRLF 文件**——整个文件会变成一个块、行号全为 1。解码后另需去掉开头的 `U+FEFF`。
- 测试会构造 `TextParser(maximumBytes: 512)`，所以 `maximumBytes` 必须留在 memberwise init 里。

**验收测试**（`TextParserTests`）

- `testReadsUTF8AndReportsLineLabels` — 单块，ordinal 0，文本含 `"第 200 行"`，label 以 `"第 1 行"` 开头。
- `testSplitsLongFilesIntoMultipleChunks` — 20000 行文件出多块，ordinal 为 `0..<count`。
- `testDetectsUTF16` — 含 BOM 的 UTF-16 正文能解出 `"开具发票"`。
- `testFallsBackToGB18030ForLegacyChineseFiles` — GB18030 正文能解出 `"开具发票"`。
- `testRejectsOversizedFiles` — 1024 字节文件在 `maximumBytes: 512` 下抛错。

**验证**：`swift test --filter TextParserTests` → 先失败（`cannot find 'TextParser' in scope`），后 PASS。
**提交**：`feat(content): parse plain text with encoding fallback`

---

## Task 8: 索引器（候选枚举 + 预算 + 取消）

**Files:**
- Create: `Sources/OilFindApp/ContentSearch/ContentIndexer.swift`
- Test: `Tests/OilFindUITests/ContentIndexerTests.swift`

**接口**

```swift
final class ContentIndexer {
    private(set) var failedCount = 0
    var batchSize = 20_000
    init(index: ContentIndex,
         parsers: [ContentParser],
         budget: AITopicWorkBudget = AITopicWorkBudget(fraction: 0.10),
         batchSize: Int = 20_000)
    func synchronize(store: IndexStore, isCancelled: () -> Bool) throws
    private func parser(for path: String, kind: UInt8) -> ContentParser?
}
```

**不变量与约束**

- **候选来自 `IndexStore`，不走文件系统**：现有索引范围、排除文件夹、排除扩展名全部自动继承。
- **分批读取**：`IndexStore` 的读锁会阻塞文件索引的写入与压实，不能持锁扫一百万条。`store.count` **只在锁内读**——扫描期间它会增长，锁外读会与写入竞争；批处理把总数带出来。
- `batchSize` 是实例属性而不是常量，好让测试调小。
- 候选过滤：`kind == 3 || kind == 4` **且** `store.flags[i] & SiftFlag.dir == 0`；解析器必须能解析出，否则跳过该条。
- 解析器选择是数据驱动的：`$0.kinds.contains(kind) && ($0.extensions.contains("*") || $0.extensions.contains(ext))`，`ext` 是 lowercased `pathExtension`。
- **批次循环顺序（关键）**：先读这一批，再 `offset += batchSize`，然后 `guard offset < total else { break }`。先判断再读会漏掉最后一批不满的。
- 取消：循环顶部 `if isCancelled() { complete = false; break }`；每批之后 `budget.checkpoint(isCancelled: isCancelled)`。`complete` 传给 `index.plan(candidates:complete:)`——这就是 Task 5「不完整枚举不删除」的来源。
- `failedCount` 在每次 `synchronize` 开头归零；每条 `parse` 抛错的记录计一次（该记录向 `index.apply` 返回 `nil`）。**但 `ContentParserError.cancelled` 必须单独 catch：同样返回 `nil`，且不计入 `failedCount`**，否则一次取消会报出成千上万条假失败。
- 测试会替换一个 `StubParser`（`extensions = ["*"]`，`parse` 返回固定块），所以 `parser(for:kind:)` 不能写死具体解析器类型。

**验收测试**（`ContentIndexerTests`）

- `testIndexesOnlyDocumentAndImageEntries` — 只索引 `note.txt`（kind 3）；count == 1，且 `search("发票")` 首条 path 指向它。
- `testSecondRunIsANoOp` — 第二次 `synchronize` 后 `revision` 不变。
- `testRemovedFileIsDroppedFromTheIndex` — 陈旧行在重扫时被删（count == 0）。
- `testImageEntriesUseTheImageParser` — kind 4 走 stub；`record.parser == "stub-ocr"`，count == 1。
- `testDamagedFileIsSkippedAndCounted` — 损坏文件被跳过且 `failedCount == 1`。
- `testBatchingCoversEveryEntry` — `batchSize: 2` 时 5 条全部索引（count == 5）。

**验证**：`swift test --filter ContentIndexerTests` → 先失败（`cannot find 'ContentIndexer' in scope`），后 PASS。
**提交**：`feat(content): index document and image entries from the file index`

**测试环境注意**：索引 0 必须是根目录且 `buildHash()` 要有值；`ScanBuffer` 上 `sizes` / `mtimes` 是 `[UInt32]`，不是 `UInt64` / `Int64`。

---

## Task 9: Provider —— 路径解析成 entryID

> **这是整个 M1 最容易出错的一环。必须有一条测试证明压实之后命中仍指向同一个文件。**

**Files:**
- Create: `Sources/OilFindApp/ContentSearch/ContentSearchProvider.swift`
- Test: `Tests/OilFindUITests/ContentSearchProviderTests.swift`

**接口**

```swift
/// Publishes content matches as supplementary hits on file rows.
final class ContentSearchProvider: SupplementarySearchProvider {
    /// Optional so a disabled manager can exist without opening a database.
    private let index: ContentIndex?
    var isEnabled = true

    init(index: ContentIndex?)

    /// The literals the user actually typed, ignoring filters such as `ext:` and `kind:`.
    /// Searching `raw` would ask the content index for the literal string "ext:pdf 发票".
    static func terms(from query: Query) -> String

    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource],
                       isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit]

    /// Image chunks carry no label, so they take one from the file kind instead: the detail line
    /// reads "图片中文字：…" for images and "第 3 页：…" for documents.
    private static func makeHit(hit: ContentHit, source: SearchSource, entryID: UInt32, version: UInt64)
        -> SupplementaryHit

    func sourcesDidChange(_ sources: [SearchSource])
    func userActivity(visible: Bool, typing: Bool)
}
```

**不变量与约束**

- **`terms(from:)` 必须只取用户真正输入的词**，忽略 `ext:` / `kind:` 这类过滤词法。直接拿原始 query 会让内容索引去搜 `"ext:pdf 发票"` 这个字面串。
- **`store.version` 的读取与 path→entryID 解析必须在同一个 `store.read { }` 内完成**，然后用该 version 盖戳。中途文件索引变化时，宿主按 `SearchPresentation.swift:139` 的 version 不匹配丢弃命中。
- 解析不到的路径直接丢弃（返回空），不要报错。
- `isEnabled == false` → 不返回任何东西（宿主也会走 `withoutSupplements()` 撤下，见 `SearchViewController.swift:87`）。
- detail 前缀：`label.isEmpty && kind == 4` 时用 `L10n.text("contentImageText")`，否则用 `hit.label`；`prefix = label.isEmpty ? "" : label + "："`。
- **高亮偏移**：`offset = (prefix as NSString).length`，每个 range 都要 `location + offset`，且满足 `NSMaxRange(range) <= (presentation.text as NSString).length`。
- `prepareSearch` 在主线程被调用（只做准备），返回的闭包在宿主 `supplementQueue` 上并发执行（`SearchViewController.swift:291-293`）。
- 内容命中能**凭空出现**：`SearchPresentation.supplement` 会把不在名称结果里的命中 append 成新行（`SearchPresentation.swift:137-152`），这是功能成立的前提，不要去"修正"它。
- 排序契约：内容命中永远排在名称命中之后（`SearchPresentation.swift:150-152`），宿主不做全局重排。搜"收据"时"图里写着收据"排在"文件名含收据"之后——这是既定契约，接受它。

**验收测试**（`ContentSearchProviderTests`）

- `testResolvesPathToTheCurrentEntryID` — 1 条命中；`store.path(hit.entryID) == "/note.txt"`，`hit.sourceVersion == store.version`。
- `testHitStillPointsAtTheSameFileAfterCompaction` — **回归测试**：打墓碑 + `compacted()` 重排后，命中仍解析到 `/note.txt`。
- `testUnresolvablePathsAreDropped` — store 里没有的路径不产生命中。
- `testDisabledProviderReturnsNothing` — `isEnabled = false` 时为空。
- `testDetailTextAndHighlightRangesStayInsideTheDetailString` — detail 含 `"发票"`；每个 range 都在串内且取出的子串等于 `"发票"`。

**验证**：`swift test --filter ContentSearchProviderTests` → 先失败（`cannot find 'ContentSearchProvider' in scope`），后 PASS。
**提交**：`feat(content): resolve hits to live entry ids and stamp store version`

**测试环境注意**：`store.buildHash()` 必须有值，否则测试会因为错误的原因通过；索引 0 要带 dir flag 且是活的（`resolve(path:)` 从 0 往下走）；测试路径用 `"/"` 的直接子项（如 `"/note.txt"`）。

---

## Task 10: supplementary 多路复用器

**Files:**
- Create: `Sources/OilFindApp/ContentSearch/SupplementaryMultiplexer.swift`
- Test: `Tests/OilFindUITests/SupplementaryMultiplexerTests.swift`

**接口**

```swift
final class SupplementaryMultiplexer: SupplementarySearchProvider {
    init(providers: [SupplementarySearchProvider])
    var isEnabled: Bool { get }
    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource],
                       isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit]
    func sourcesDidChange(_ sources: [SearchSource])
    func userActivity(visible: Bool, typing: Bool)
    func backgroundIndexingChanged(_ busy: Bool)
}
```

**不变量与约束**

- `supplementaryProvider` 是**单槽位**（`SearchViewController.swift:48`），当前被 `appExtension?.supplementarySearchProvider` 占用（`AppDelegate.swift:59`）。加一层合并，**不抢 Pro 的槽位**。
- `isEnabled` 语义：`providers.contains { $0.isEnabled }`——只要有一个启用就为真，**全部**禁用才为假。
- `prepareSearch` 只 fan-out 给 `isEnabled` 的 provider；`work` 为空时短路返回 `{ [] }`；否则返回 `{ work.flatMap { $0() } }`。
- 生命周期回调（`sourcesDidChange` / `userActivity` / `backgroundIndexingChanged`）**必须转发给每一个 provider，包括已禁用的**——否则禁用再启用后状态不同步。

**验收测试**（`SupplementaryMultiplexerTests`；测试内自带 `Provider` 替身）

- `testMergesHitsFromEveryEnabledProvider` — 两个启用 provider 的命中 detail 排序后为 `["A", "B"]`。
- `testDisabledProviderContributesNothing` — 禁用 B 后只剩 `["A"]`。
- `testReportsDisabledOnlyWhenEveryProviderIsDisabled` — 都启用为 true；禁用 B 仍 true；再禁用 A 才为 false。
- `testLifecycleCallbacksReachEveryProvider` — `userActivity(visible: true, …)` 与 `backgroundIndexingChanged(true)` 都到达两个 provider。

**验证**：`swift test --filter SupplementaryMultiplexerTests` → 先编译失败，后 PASS。
**提交**：`feat(content): multiplex the single supplementary provider slot`

---

## Task 11: Manager、设置分区与接线

**Files:**
- Create: `Sources/OilFindApp/ContentSearch/ContentManager.swift`
- Create: `Sources/OilFindApp/ContentSearch/ContentSettings.swift`
- Modify: `Sources/OilFindApp/ContentSearch/ContentIndex.swift`（加 `clear()`）
- Modify: `Sources/OilFindApp/ContentSearch/ContentSearchProvider.swift`（索引改可选，Task 9 已做，此处只核对）
- Modify: `Sources/OilFindApp/AppDelegate.swift:20,59,134,200,276`
- Modify: `Sources/OilFindApp/SettingsWindow.swift:7,368-369`
- Modify: `Sources/OilFindApp/L10n.swift`
- Test: `Tests/OilFindUITests/ContentSettingsTests.swift`

**接口**

```swift
// ContentIndex.swift
func clear() throws

// ContentSearchProvider.swift
private let index: ContentIndex?
init(index: ContentIndex?)

// ContentManager.swift
final class ContentManager: ObservableObject {
    static let enabledKey = "contentSearchEnabled"
    @Published private(set) var enabled: Bool
    @Published private(set) var indexing = false
    @Published private(set) var count = 0
    @Published private(set) var diskBytes: Int64 = 0
    @Published private(set) var failed = 0
    let provider: ContentSearchProvider
    var storeProvider: (() -> IndexStore?)?

    private let defaults: UserDefaults
    private let indexURL: URL?
    private let writer: ContentIndex?
    private let reader: ContentIndex?
    private let indexer: ContentIndexer?
    private let queue = DispatchQueue(label: "com.oiloil.find.content.index", qos: .utility)
    private let lock = NSLock()
    private var generation = 0
    private var cancelled = false

    init(defaults: UserDefaults = .standard, indexURL: URL? = ContentIndex.defaultURL)
    func setEnabled(_ value: Bool)
    func fileIndexChanged()
    func start()
    func stop()
    func clear()
    func rebuild()
    private func enqueueClear()
    private func isCancelled(_ mine: Int) -> Bool
    private static func diskBytes(at url: URL?) -> Int64
}
```

`SettingsModel`（`SettingsWindow.swift:7`）：加 `let contentSearch: ContentManager`；init 头部加参数（放在 `topics:` 之后）`contentSearch: ContentManager? = nil`；init 体内 `self.contentSearch = contentSearch ?? ContentManager(defaults: preferences, indexURL: nil)`。

`ContentSettings.swift`：照 `AITopicSettings(manager:)` 的写法，`@ObservedObject var manager: ContentManager`；调用点 `ContentSettings(manager: model.contentSearch)`。

`L10n.swift` 的 `strings` 字典新增：

```swift
"contentTitle": ("文件内容", "File contents"),
"contentEnabled": ("搜索图片和文档里的文字", "Search text inside images and documents"),
"contentImageText": ("图片中文字", "Text in image"),
"contentPrivacy": ("图片和文档都在本机处理，不会上传。", "Images and documents are processed on this Mac and never uploaded."),
"contentBuilding": ("正在建立内容索引…", "Building content index…"),
"contentDone": ("已索引 %@ 个文件", "Indexed %@ files"),
"contentRebuild": ("重建索引", "Rebuild index"),
"contentClear": ("清除索引", "Clear index"),
```

**不变量与约束**

- `clear()` 只有一句 `try sql.run("DELETE FROM files")`：`chunks` 的 `ON DELETE CASCADE` 加上 `chunk_postings_delete` 触发器会把块与 FTS 行一并带走，**不需要单独删**。
- **两个连接开同一个 WAL 库**：一个 SQLite 连接绝不能跨线程使用，而索引器在写、provider 在读。**先开 writer**，它会建库并迁移，reader 需要的就是这个 schema。
- `indexURL: nil` 是**完全惰性**的：不打开任何数据库、不写盘。测试靠它避免碰到用户真实的 Application Support 目录。
- 两次 open 发生在调用线程（启动时是主线程）。有界：`ContentIndex` 在迁移锁被抢占时 2 秒后放弃，所以并发重建会拖慢启动但**不会挂住**。
- `storeProvider` 提供宿主的文件索引；`AppDelegate` 在第一次 `start()` 之前装好；索引还在加载时它返回 nil，此时 `start()` 是 **no-op**。
- `setEnabled(_:)`：设 `enabled`、`provider.isEnabled`、写 `defaults`，然后 `if value { start() } else { stop() }`。关开关必须**立即**撤下命中。
- `fileIndexChanged()`：索引变更由 `AppDelegate` 调用；内容索引很贵，所以突发要合并——只在没有进行中的运行时才 `start()`。
- `start()`：`guard enabled, let indexer, storeProvider?() != nil else { return }`；**先 bump generation** 再跑，好让并发的 `stop()` 能作废它（`lock.lock(); generation += 1; let mine = generation; cancelled = false; lock.unlock()`）。
- store 可能在 guard 与队列 hop 之间消失；此时**要跑完本轮再退出**（`if let store = provider?()`），不能提前 return，否则 `indexing` 永远卡在 true。
- 计数只在 writer 的队列上读（`try? self.writer?.count()`），该连接上没有并发语句。
- 回填主线程：`DispatchQueue.main.async { guard !self.isCancelled(mine) else { return }; … }`。
- `failed = indexer.failedCount + (hardFailure ? 1 : 0)`（`synchronize` 抛错算一次 hard failure）。
- `stop()`：`generation += 1; cancelled = true` 作废进行中的运行；worker 在文件之间检查 `isCancelled`。
- `clear()`：`stop()` 然后 `enqueueClear()`；两者都走 indexer 的同一条 serial queue，**删除绝不会与 sync 重叠**。
- `rebuild()`：`clear(); start()`。
- `enabled` 是 `private(set)`，不能直接绑，要用显式 `Binding`（`get: { manager.enabled }, set: { manager.setEnabled($0) }`）。
- 中英文跟随父视图重绘（父视图观察 `model`），所以**不需要**额外传 `chinese:`，也**不要**调用 `languageDidChange`——`ContentManager` 没有语言相关状态。
- `SettingsModel` 加属性使其可观察 manager，**不影响现有 8 处构造点**；默认给一个不碰磁盘的 manager，所以 `snapshot: true` 的构造点与测试都不用改。

**接线（`AppDelegate.swift` 三处）**

1. 第 20 行附近，与 `topics` 并列：`private let contentSearch = ContentManager()`。
2. `startIndex(limited:)` 里，`self.manager = manager` 之后装来源并给初值；第 59 行改成多路复用器：

```swift
self.manager = manager; panel.searchController.manager = manager
contentSearch.storeProvider = { [weak manager] in manager?.store }
contentSearch.start()
panel.searchController.supplementaryProvider = SupplementaryMultiplexer(
    providers: [contentSearch.provider] + [appExtension?.supplementarySearchProvider].compactMap { $0 })
```

3. 第 134 行 `onIndexChange` 追加内容索引触发；第 200 行 `SettingsModel(...)` 传 `contentSearch: contentSearch`；`applicationWillTerminate` 里 `topics.stop()` 旁边加 `contentSearch.stop()`：

```swift
manager.onIndexChange = { [weak self] in
    self?.panel.searchController.indexChanged()
    self?.contentSearch.fileIndexChanged()
}
```

- `SettingsWindow.swift:368-369` 之后插入：`Section(L10n.text("contentTitle")) { ContentSettings(manager: model.contentSearch) }`

**验收测试**（`ContentSettingsTests`）

- `testManagerDefaultsToDisabledAndPersistsToggle` — 新 manager 默认 `enabled == false`；`setEnabled(true)` 后同 suite 新开的 manager 也是 true。
- `testDisablingProviderImmediatelyStopsHits` — `setEnabled(true)` 后 `provider.isEnabled == true`，`setEnabled(false)` 后为 false。
- `testLocalizedCopyExistsInBothLanguages` — 8 个 key 在 `chinese: true` 与 `chinese: false` 下都返回非 key 文案。

**验证**

```sh
swift test --filter ContentSettingsTests     # 先编译失败，后 PASS
swift build && swift test
OILFIND_FREE=1 swift build && OILFIND_FREE=1 swift test
python3 Tests/Scripts/test_open_core.py
scripts/build-app.sh --debug
"build/debug/Oil Find.app/Contents/MacOS/OilFind" --snapshot /tmp/content-settings.png --state settings --settings-scroll 0.78
```

**提交**：`feat(content): add content search manager, settings and wiring`

---

## M1 完成标准

- [x] `swift test` 与 `OILFIND_FREE=1 swift test` 全绿 —— UI 196 项（1 项预置 skip）、core 117 项，0 失败
- [x] `python3 Tests/Scripts/test_open_core.py` 通过
- [ ] **截图里的中文能被搜到，命中行有 detail 和高亮** —— 见下方说明，本项无截图证据
- [x] 纯文本/Markdown 文件内容能被搜到 —— `ContentSearchIntegrationTests.testTextFileIsFoundEndToEndByItsContent`
- [x] 压实之后命中仍指向正确的文件（Task 9 的回归测试）
- [x] 关掉开关立刻撤下命中 —— `ContentSettingsTests.testDisablingProviderImmediatelyStopsHits`
- [x] 设置分区中英文都有文案，切换语言即时刷新 —— `ContentSettingsTests.testLocalizedCopyExistsInBothLanguages`

第 3 条是唯一没有证据的一条。它由三层测试拼起来，但没有一层渲染 `ResultsView`：

| 层次 | 覆盖它的测试 |
| --- | --- |
| 解析（图片 OCR / 文本） | `ImageOCRParserTests`、`TextParserTests` |
| detail 文本与高亮偏移 | `ContentSearchProviderTests` |
| 真实解析器 → 索引器 → 检索整链 | `ContentSearchIntegrationTests` |
| 同步调度（在途变更触发一次跟进） | `ContentManagerTests` |

缺的是「命中行在列表里长什么样」。补它要让 `Snapshot` 安装多路复用器（公开库改动），超出 M1 范围，故如实记为未验证。

## 明确不在 M1 范围

- PDF、docx、xlsx、pptx、RTF、图片画面识别、外置盘路径 rebase、`chunk_fts` 的 `optimize`/`VACUUM` 一次性门闩、内容索引的体积门限测试（M2 做）。

### M1 评审中记录、留到 M2 的问题

以下都是评审确认存在、但判定不阻塞 M1 的问题，**不是已修项**：

- **块内片段对非中文文本是小写的**。schema 只存 folded 文本，修它需要新增一列未折叠摘录并升 `schemaVersion`。
- **`snippet` 可能在窗口边缘切开代理对**。仅影响观感；高亮仍正确，因为 UTF-16 长度守恒。
- **`removeFiles(prefix:)` 的 reset 不是异常安全的**。它的 reset 有意放在 `BEGIN IMMEDIATE` 之前，`defer` 会把它挪到事务之后、破坏原意，需要单独把 SELECT 圈进自己的作用域。
- **删除对账把全部已存路径物化进 Swift `Set`**。相比 `AITopicIndex.reconcile` 的临时表做法多一个常数因子，但候选列表本来就在内存里，改临时表等于拿内存换临时表写入。100 万文件量级值得重做。
- **`terms(from:)` 还会收进 `file:` / `folder:` / 未知键的字面量**。计划只点名 `ext:` / `kind:`，要严格"只取用户真正输入的词"需要判断 matcher 的来源。
- **`try? index.search(...)` 静默吞掉 `ContentIndexError`**。内容库损坏时内容搜索会无声退化成空结果。
- **`TextParser` 把一切读取失败都映射成 `.damaged`**。索引与解析之间被删掉的文件也会被计成解析失败。
- **行号 label（`第 N 行附近`）是索引期写死的中文**，英文界面会原样显示。要修得存结构化 label、在展示期本地化，属于 schema 变更。
- **DEBUG 的 `--snapshot` 会在第二个线程上跑 provider 闭包**（`SearchViewController.swift:429,439`）。串行队列并不能让 SQLite 连接跨线程安全；仅 DEBUG。
- **`CGImageSourceGetStatusAtIndex(source, 0) == .statusUnknownType` 这一条同时覆盖"只含 8 字节 PNG 签名的残片"**。该窗口极窄且会自愈——下载完成后 size/mtime 变化即重新解析。现有状态词汇无法区分二者。
- **内容搜索不认 `|` 或取反**。`terms(from:)` 把所有非取反的 `.name` atom 展平成一个空格串，而 `ContentIndex.search` 要求每个词都出现；名字搜索里同一 clause 的 alternatives 是 OR，于是 `发票|收据` 在内容侧被当成 AND，命中偏少。取反词被忽略，被名字搜索排除的文件可能以内容行重新出现。
- **`ContentIndex.removeFiles(prefix:)` 是死代码**，只有测试调用（外置盘 rebase 不在 M1 范围）；**`usesWAL` 只赋值不读**，注释说"Task 11 会打日志"，实际没有。
- **永久解析失败的文件会让设置里的按钮永远是"重试"**：`ContentSettings` 在 `failed > 0` 时把按钮文案换成 `action.retry`，而超过 32 MiB 的 `.txt` 或无法降采样的大图每次同步都会抛 `.tooLarge`，`failed` 永不归零，`rebuild()` 也只是重演。
- **一个写事务最长跨 256 次解析**（`applyChunkSize`）。图片 OCR 每次数百毫秒时，这是个多分钟的写事务：WAL 无界增长，且设置页的 `clear()`/`rebuild()` 要等这一批结束。正确性无碍（每个文件一个 `store` 事务，崩溃只回滚当前批）。文字解析器下无此问题。
- **设置分区没有设计里的"图片 / 文档分项开关"**，只有总开关、状态与两个按钮。lean 计划本身也没写，属于范围收缩而非实现遗漏。
- **多路复用器装得比以前晚**：原先在 `applicationDidFinishLaunching` 直接赋 `appExtension?.supplementarySearchProvider`，现改到 `startIndex` 里装多路复用器，而 `startIndex` 在欢迎/权限流程期间是延后的。面板在此之前不可用，影响很低，但属于本功能之外的时序变化。
- **`ImageOCRParser` 的 `statusUnknownType` 规则理论上仍可能把一张图永久记成无文本**：若 iCloud 未实体化的文件在这一刻被 ImageIO 答成 `unknownType` 而非读错误，该图内容会丢到文件本身变化为止。未能在本机证实，仅作为风险记录。
