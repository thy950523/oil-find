# 内容搜索 M1 实施计划（内核 + 图片 OCR + 纯文本）

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让 Oil Find 能按图片里的文字和纯文本/Markdown 文件里的文字搜索，命中挂到文件行上并高亮。

**Architecture:** 新建 `Sources/OilFindApp/ContentSearch/`，与 `AITopics/` 平级，同在 `OilFindApp` module 内，直接复用其 SQLite 封装、gram 生成与 CPU 预算。独立一个 SQLite 库存 `files` / `chunks` / `chunk_fts`。查询时从 gram 索引取候选、逐字节字面验证，再把文件**路径**解析成文件索引当前的 entryID，通过 `SupplementarySearchProvider` 挂到结果行。

**Tech Stack:** Swift 5、SQLite3（系统库）、Vision、AppKit、XCTest。不引第三方包。

**设计依据:** `docs/plans/2026-10-19-content-search-design.md`

---

## 开工前必读

- 分支：`feat/content-search`
- 关键约束：**内容索引存绝对路径，不存 entryID**。`compacted()` 会重排 entryID（`IndexStore+Mutation.swift:175-199`），存 id 会导致命中挂到错误文件上。理由见设计文档第 2 节。
- 每完成一个 Task 都要跑一次免费版回归闸门。
- 测试放 `Tests/OilFindUITests/`（代码在 `OilFindApp` 内，需要 `@testable import OilFindApp`）。

## 验证命令

```sh
swift build
swift test --filter Content
OILFIND_FREE=1 swift build
OILFIND_FREE=1 swift test --filter Content
python3 Tests/Scripts/test_open_core.py
```

---

## Task 1: 放开 gram 的让出变体 + 压缩辅助

大文档构造 gram 时必须在块之间让出 CPU，但带 `checkpoint` 的重载是 `private`（`AITopicIndex.swift:193`）。改可见性即可，不动任何调用点。

**Files:**
- Modify: `Sources/OilFindApp/AITopics/AITopicIndex.swift:193`
- Create: `Sources/OilFindApp/ContentSearch/Support/ContentCompression.swift`
- Test: `Tests/OilFindUITests/ContentSearchSupportTests.swift`

**Step 1: 写失败测试**

```swift
import XCTest
@testable import OilFindApp

final class ContentSearchSupportTests: XCTestCase {
    /// Deterministic, so a failure is reproducible. `UInt8.random` here only adds flakiness.
    private func pseudorandomBytes(_ count: Int) -> Data {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return Data((0..<count).map { _ -> UInt8 in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        })
    }
    private func roundTrip(_ data: Data) throws {
        for compact in [false, true] {
            let packed = ContentCompression.pack(data, compact: compact)
            XCTAssertEqual(try ContentCompression.unpack(packed, bytes: data.count), data)
        }
    }
    func testCompressionRoundTrips() throws {
        for data in [Data(), Data("收据".utf8), Data(String(repeating: "开具发票的日期 ", count: 5000).utf8),
                     pseudorandomBytes(4096)] {
            try roundTrip(data)
        }
    }
    func testCompressibleInputActuallyCompresses() throws {
        let raw = Data(String(repeating: "开具发票的日期 ", count: 5000).utf8)
        XCTAssertLessThan(ContentCompression.pack(raw, compact: true).count, raw.count)
    }
    func testIncompressibleInputFallsBackToRaw() throws {
        // Random bytes cannot shrink, so pack must store them verbatim behind the raw codec.
        let raw = pseudorandomBytes(4096)
        let packed = ContentCompression.pack(raw, compact: true)
        XCTAssertEqual(packed.first, 0)
        XCTAssertEqual(Data(packed.dropFirst()), raw)
    }
    func testCodecBytesAreStable() throws {
        // The codec byte is persisted; changing it silently invalidates every existing index.
        let compressible = Data(String(repeating: "开具发票的日期 ", count: 5000).utf8)
        XCTAssertEqual(ContentCompression.pack(compressible, compact: true).first, 2)   // zlib
        XCTAssertEqual(ContentCompression.pack(compressible, compact: false).first, 1)  // lzfse
        XCTAssertEqual(ContentCompression.pack(Data([1]), compact: true).first, 0)      // raw fallback
    }
    func testWrongBodyLengthThrows() throws {
        let raw = Data(String(repeating: "abcdefghij", count: 1000).utf8)
        let packed = ContentCompression.pack(raw, compact: true)
        XCTAssertEqual(try ContentCompression.unpack(packed, bytes: raw.count), raw)
        XCTAssertThrowsError(try ContentCompression.unpack(packed, bytes: raw.count - 1))
        XCTAssertThrowsError(try ContentCompression.unpack(packed, bytes: raw.count + 1))
        XCTAssertThrowsError(try ContentCompression.unpack(packed, bytes: ContentCompression.maxBodyBytes + 1))
    }
    func testDamagedBodiesThrow() throws {
        XCTAssertThrowsError(try ContentCompression.unpack(Data(), bytes: 4))           // no codec byte
        XCTAssertThrowsError(try ContentCompression.unpack(Data([9, 1, 2]), bytes: 4))  // unknown codec
        XCTAssertThrowsError(try ContentCompression.unpack(Data([2, 1, 2]), bytes: 4))  // truncated zlib
        XCTAssertThrowsError(try ContentCompression.unpack(Data([0, 1, 2]), bytes: 4))  // raw length mismatch
    }
    func testGramCheckpointIsCalledAndCancellationPropagates() throws {
        var calls = 0
        let text = String(repeating: "发票 ", count: 20000)
        _ = try AITopicIndex.grams(text, checkpoint: { calls += 1 })
        XCTAssertGreaterThan(calls, 0)
        XCTAssertThrowsError(try AITopicIndex.grams(text, checkpoint: { throw CancellationError() }))
    }
}
```

**Step 2: 跑测试确认失败**

Run: `swift test --filter ContentSearchSupportTests`
Expected: 编译失败，`cannot find 'ContentCompression' in scope`

**Step 3: 实现**

`AITopicIndex.swift:193` 去掉 `private`：

```swift
    static func grams(_ text: String, query: Bool = false, checkpoint: (() throws -> Void)?) throws -> String {
```

新建 `Sources/OilFindApp/ContentSearch/Support/ContentCompression.swift`：

```swift
import Foundation
import Compression

/// Shared by every content search component. Defined here so Task 1 compiles on its own.
enum ContentIndexError: Error, LocalizedError {
    case database(String)
    var errorDescription: String? { if case .database(let message) = self { return message }; return nil }
}

/// Body compression for the content index.
///
/// The byte layout is deliberately identical to `AITopicIndex.pack` — a leading codec byte
/// (0 raw, 1 LZFSE, 2 ZLIB) followed by the payload — but this is a separate implementation.
/// The AI topic decoder writes into a reusable buffer to avoid allocating on its search path,
/// which is not worth sharing here. Callers store the uncompressed length next to the body, so
/// decoding is a single exact-size pass and needs no growth guessing.
///
/// There is no checksum: a bit flip that still decodes to exactly `bytes` bytes yields silently
/// wrong text. That is acceptable because the index is derived and rebuildable.
enum ContentCompression {
    private enum Codec: UInt8 { case raw = 0, lzfse = 1, zlib = 2 }

    /// Ceiling on a single body, so a corrupt `bytes` column cannot drive an unbounded
    /// allocation on the search path. Chunks are written at 32-64 KiB, so this is generous.
    static let maxBodyBytes = 16 * 1024 * 1024

    static func pack(_ data: Data, compact: Bool = false) -> Data {
        let capacity = data.count
        guard capacity > 0 else { return Data([Codec.raw.rawValue]) }
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let out = destination.bindMemory(to: UInt8.self).baseAddress,
                      let input = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(out, capacity, input, capacity, nil,
                                                 compact ? COMPRESSION_ZLIB : COMPRESSION_LZFSE)
            }
        }
        guard written > 0, written < capacity else { return Data([Codec.raw.rawValue]) + data }
        output.count = written
        return Data([(compact ? Codec.zlib : Codec.lzfse).rawValue]) + output
    }

    /// `bytes` is the uncompressed length stored alongside the body.
    static func unpack(_ data: Data, bytes: Int) throws -> Data {
        guard let codec = data.first.flatMap(Codec.init(rawValue:)) else {
            throw ContentIndexError.database("Missing compression codec")
        }
        let body = data.dropFirst()
        if codec == .raw {
            guard body.count == bytes else { throw ContentIndexError.database("Truncated raw body") }
            return Data(body)
        }
        guard bytes > 0, bytes <= maxBodyBytes else { throw ContentIndexError.database("Body length out of range") }
        // Decode into one extra byte. The decoder reports a partial fill as success, so without
        // the spare byte a body longer than `bytes` would be truncated silently instead of
        // rejected. A body that is exactly `bytes` long still reports `bytes`.
        var output = Data(count: bytes + 1)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            body.withUnsafeBytes { source -> Int in
                guard let out = destination.bindMemory(to: UInt8.self).baseAddress,
                      let input = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(out, bytes + 1, input, body.count, nil,
                                                 codec == .zlib ? COMPRESSION_ZLIB : COMPRESSION_LZFSE)
            }
        }
        guard written == bytes else { throw ContentIndexError.database("Cannot decompress body") }
        output.count = bytes
        return output
    }
}
```

**Step 4: 跑测试确认通过**

Run: `swift test --filter ContentSearchSupportTests`
Expected: PASS

**Step 5: 确认没有打破 AITopics**

Run: `swift test --filter AITopic`
Expected: 全部 PASS

**Step 6: 提交**

```sh
git add Sources/OilFindApp/AITopics/AITopicIndex.swift Sources/OilFindApp/ContentSearch/Support/ContentCompression.swift Tests/OilFindUITests/ContentSearchSupportTests.swift
git commit -m "feat(content): add compression helper and expose gram checkpoints"
```

---

## Task 2: 内容索引的表结构与迁移

**Files:**
- Create: `Sources/OilFindApp/ContentSearch/ContentIndex.swift`
- Test: `Tests/OilFindUITests/ContentIndexSchemaTests.swift`

**Step 1: 写失败测试**

```swift
import XCTest
@testable import OilFindApp

final class ContentIndexSchemaTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("content-" + UUID().uuidString + ".sqlite")
    }
    /// The database runs in WAL mode, so the sidecars are left behind if only the main file goes.
    private func removeDatabase(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
    func testOpenCreatesTablesAndIsIdempotent() throws {
        let url = tempURL(); defer { removeDatabase(url) }
        do { _ = try ContentIndex(url: url) }
        let index = try ContentIndex(url: url)
        let sql = try AITopicSQL(url, readOnly: true)
        XCTAssertEqual(try sql.tables().intersection(["files", "chunks"]), ["files", "chunks"])
        XCTAssertTrue(try sql.tables().contains("chunk_fts"))
        XCTAssertEqual(try index.count(), 0)
    }
    func testRebuildsWhenTheExistingSchemaIsNotCanonical() throws {
        let url = tempURL(); defer { removeDatabase(url) }
        do {
            let sql = try AITopicSQL(url)
            try sql.run("CREATE TABLE files(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE)")
        }
        _ = try ContentIndex(url: url)
        let sql = try AITopicSQL(url, readOnly: true)
        // Rebuilt from scratch, so the table is canonical rather than having columns bolted on.
        XCTAssertTrue(try sql.columns("files").isSuperset(of: ["size", "mtime", "kind", "parser", "revision"]))
        XCTAssertTrue(try sql.tables().contains("chunk_fts"))
    }
    func testReopenKeepsTheSchemaVersionAndDoesNotRebuild() throws {
        let url = tempURL(); defer { removeDatabase(url) }
        do {
            let index = try ContentIndex(url: url)
            try index.sql.run("INSERT INTO files(path,size,mtime,kind,parser) VALUES('/a/b.txt',1,1,3,'text')")
        }
        // A rebuild would drop the row; the version stamp must make the second open a no-op.
        XCTAssertEqual(try ContentIndex(url: url).count(), 1)
    }
}
```

**Step 2: 跑测试确认失败**

Run: `swift test --filter ContentIndexSchemaTests`
Expected: 编译失败，`cannot find 'ContentIndex' in scope`

**Step 3: 实现**

新建 `Sources/OilFindApp/ContentSearch/ContentIndex.swift`：

```swift
import Foundation
import SQLite3

// `ContentIndexError` lives in ContentSearch/Support/ContentCompression.swift (added in Task 1).

/// One unit of searchable text inside a file. `ordinal` orders chunks within the file; `label`
/// is the human-readable location, such as "第 3 页" or "第 1200 行附近".
struct ContentChunk {
    let ordinal: Int
    let label: String
    let text: String
}

/// A file as seen in the file index. `size` and `mtime` form the identity used by incremental
/// sync; `kind` is the file-index kind (3 = document, 4 = image) and `parser` is the identifier
/// of the `ContentParser` that produced its chunks.
struct ContentFileRecord {
    let path: String
    let size: Int64
    let mtime: Int64
    let kind: UInt8
    let parser: String
}

/// A read-only or read-write connection. Each connection is confined to its caller's queue.
final class ContentIndex {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Oil Find/content/index.sqlite")

    /// Bumped whenever the canonical schema changes. The index is derived and rebuildable, so a
    /// mismatch is repaired by rebuilding rather than migrated column by column.
    static let schemaVersion = 1

    let sql: AITopicSQL
    private let readOnly: Bool
    private var statements: [String: AITopicStatement] = [:]
    private var inTransaction = false

    init(url: URL, readOnly: Bool = false) throws {
        self.readOnly = readOnly
        if !readOnly {
            // `attributes` only applies when the directory is created, so set the mode on every
            // open: an older build or a manual mkdir may have left it wider than 0700.
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        sql = try Self.open(url, readOnly: readOnly)
        if !readOnly {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        try migrate()
    }

    /// Surfaces open failures as this module's error type, so callers need not know about the
    /// shared SQLite wrapper.
    private static func open(_ url: URL, readOnly: Bool) throws -> AITopicSQL {
        do { return try AITopicSQL(url, readOnly: readOnly) }
        catch { throw ContentIndexError.database(error.localizedDescription) }
    }

    private func migrate() throws {
        if readOnly { return }
        // Neither pragma can run inside a transaction.
        try sql.run("PRAGMA journal_mode=WAL")
        try sql.run("PRAGMA foreign_keys=ON")
        // BEGIN IMMEDIATE serialises two writable connections opening the same fresh database:
        // the loser waits, then sees the winner's version and skips the rebuild.
        try sql.run("BEGIN IMMEDIATE")
        do {
            let probe = try sql.prepare("PRAGMA user_version")
            let version = try probe.next() ? probe.int(0) : 0
            sqlite3_reset(probe.handle)
            if version != Int64(Self.schemaVersion) {
                try sql.run("""
                    DROP TRIGGER IF EXISTS chunk_postings_delete;
                    DROP TABLE IF EXISTS chunk_fts;
                    DROP TABLE IF EXISTS chunks;
                    DROP TABLE IF EXISTS files;
                    """)
                try sql.run("""
                    CREATE TABLE files(
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        path TEXT NOT NULL UNIQUE,
                        size INTEGER NOT NULL,
                        mtime INTEGER NOT NULL,
                        kind INTEGER NOT NULL,
                        parser TEXT NOT NULL,
                        revision INTEGER NOT NULL DEFAULT 1);
                    CREATE TABLE chunks(
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                        ordinal INTEGER NOT NULL,
                        label TEXT NOT NULL,
                        folded BLOB NOT NULL,
                        -- UNCOMPRESSED length of folded, so unpack is one exact pass. The bound
                        -- matches ContentCompression.maxBodyBytes.
                        bytes INTEGER NOT NULL CHECK(bytes BETWEEN 0 AND 16777216),
                        UNIQUE(file, ordinal));
                    CREATE INDEX chunks_file ON chunks(file);
                    CREATE VIRTUAL TABLE chunk_fts USING fts5(grams, content='', contentless_delete=1, detail=none);
                    -- Postings have no cascade of their own; this covers every path that deletes
                    -- a chunk, including the file cascade.
                    CREATE TRIGGER chunk_postings_delete AFTER DELETE ON chunks BEGIN
                        DELETE FROM chunk_fts WHERE rowid = old.id;
                    END;
                    """)
                try sql.run("PRAGMA user_version = \(Self.schemaVersion)")
            }
            try sql.run("COMMIT")
        } catch {
            try? sql.run("ROLLBACK")
            throw error
        }
    }

    func statement(_ query: String) throws -> AITopicStatement {
        if let existing = statements[query] {
            // Resetting a statement that an outer loop is iterating would end that loop silently.
            assert(sqlite3_stmt_busy(existing.handle) == 0, "Re-entrant use of \(query)")
            sqlite3_reset(existing.handle); sqlite3_clear_bindings(existing.handle); return existing
        }
        let created = try sql.prepare(query); statements[query] = created; return created
    }

    func count() throws -> Int {
        let statement = try statement("SELECT COUNT(*) FROM files")
        defer { sqlite3_reset(statement.handle) }
        guard try statement.next() else { return 0 }
        return Int(statement.int(0))
    }
}
```

**Step 4: 跑测试确认通过**

Run: `swift test --filter ContentIndexSchemaTests`
Expected: PASS

**Step 5: 提交**

```sh
git add Sources/OilFindApp/ContentSearch/ContentIndex.swift Tests/OilFindUITests/ContentIndexSchemaTests.swift
git commit -m "feat(content): add a versioned content index schema"
```

---

## Task 3: 写入文件与块

**Files:**
- Modify: `Sources/OilFindApp/ContentSearch/ContentIndex.swift`
- Test: `Tests/OilFindUITests/ContentIndexWriteTests.swift`

**Step 1: 写失败测试**

这些测试**不能用 `index.search`**——`search` 要到 Task 4 才有，用了 Task 3 就永远过不了自己那一步。改直接查 postings 表。

```swift
import XCTest
import SQLite3
@testable import OilFindApp

final class ContentIndexWriteTests: XCTestCase {
    private var url: URL!
    private var index: ContentIndex!
    /// The database runs in WAL mode, so the sidecars are left behind if only the main file goes.
    private func removeDatabase(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("content-" + UUID().uuidString + ".sqlite")
        index = try ContentIndex(url: url)
    }
    override func tearDownWithError() throws { index = nil; removeDatabase(url) }

    /// Reads the postings table through the index's own connection. `search` does not exist yet.
    private func ftsRowCount() throws -> Int {
        let statement = try index.statement("SELECT COUNT(*) FROM chunk_fts")
        defer { sqlite3_reset(statement.handle) }
        guard try statement.next() else { return 0 }
        return Int(statement.int(0))
    }

    func testUpsertIsIdempotentAndBumpsRevision() throws {
        let record = ContentFileRecord(path: "/a/b.pdf", size: 10, mtime: 100, kind: 3, parser: "pdf")
        let first = try index.upsert(file: record)
        XCTAssertEqual(try index.upsert(file: record), first)
        XCTAssertEqual(try index.count(), 1)
        // `ContentFileRecord` has `let` fields, so build a new record rather than mutating.
        let changed = ContentFileRecord(path: record.path, size: 20, mtime: record.mtime,
                                        kind: record.kind, parser: record.parser)
        XCTAssertEqual(try index.upsert(file: changed), first)
        XCTAssertEqual(try index.file(path: "/a/b.pdf")?.revision, 2)
        XCTAssertEqual(try index.file(path: "/a/b.pdf")?.record.size, 20)
    }

    func testReplaceChunksDropsOldChunksAndPostings() throws {
        let id = try index.upsert(file: .init(path: "/a/b.pdf", size: 10, mtime: 100, kind: 3, parser: "pdf"))
        try index.replaceChunks(file: id, chunks: [.init(ordinal: 0, label: "第 1 页", text: "开具发票的日期"),
                                                   .init(ordinal: 1, label: "第 2 页", text: "本月合计")])
        XCTAssertEqual(try index.chunkCount(file: id), 2)
        XCTAssertEqual(try ftsRowCount(), 2)
        try index.replaceChunks(file: id, chunks: [.init(ordinal: 0, label: "第 1 页", text: "已作废")])
        XCTAssertEqual(try index.chunkCount(file: id), 1)
        // Without the explicit postings delete this stays at 2 and leaks for the index's lifetime.
        XCTAssertEqual(try ftsRowCount(), 1)
    }

    func testRemoveFileCascadesToChunksAndPostings() throws {
        let id = try index.upsert(file: .init(path: "/a/b.txt", size: 10, mtime: 100, kind: 3, parser: "text"))
        try index.replaceChunks(file: id, chunks: [.init(ordinal: 0, label: "第 1 行附近", text: "开具发票的日期")])
        try index.removeFile(path: "/a/b.txt")
        XCTAssertEqual(try index.count(), 0)
        XCTAssertEqual(try index.chunkCount(file: id), 0)
        XCTAssertEqual(try ftsRowCount(), 0)
    }

    func testRemoveFilesByPrefix() throws {
        for path in ["/Volumes/X/a.txt", "/Volumes/X/b.txt", "/Users/me/c.txt"] {
            let id = try index.upsert(file: .init(path: path, size: 1, mtime: 1, kind: 3, parser: "text"))
            try index.replaceChunks(file: id, chunks: [.init(ordinal: 0, label: "", text: "开具发票")])
        }
        try index.removeFiles(prefix: "/Volumes/X/")
        XCTAssertEqual(try index.count(), 1)
        XCTAssertEqual(try ftsRowCount(), 1)
        XCTAssertNotNil(try index.file(path: "/Users/me/c.txt"))
    }

    /// Grams for a chunk must come from folded text. Task 4 folds the query before gramming it,
    /// so gramming raw text here would silently make content search case-sensitive.
    func testGramsAreBuiltFromFoldedText() throws {
        let id = try index.upsert(file: .init(path: "/a/Invoice.txt", size: 1, mtime: 1, kind: 3, parser: "text"))
        try index.replaceChunks(file: id, chunks: [.init(ordinal: 0, label: "", text: "INVOICE 发票")])
        let query = AITopicIndex.grams(AITopicIndex.fold("invoice"), query: true)
        let statement = try index.statement("SELECT COUNT(*) FROM chunk_fts WHERE chunk_fts MATCH ?")
        defer { sqlite3_reset(statement.handle) }
        statement.bind([query])
        XCTAssertTrue(try statement.next())
        XCTAssertEqual(statement.int(0), 1)
    }
}
```

**Step 2: 跑测试确认失败**

Run: `swift test --filter ContentIndexWriteTests`
Expected: 编译失败，`value of type 'ContentIndex' has no member 'upsert'`（同时还会报 `file` / `replaceChunks` / `chunkCount` / `removeFile` / `removeFiles` 的同类错误）

**Step 3: 实现**

追加到 `ContentIndex.swift`：

```swift
extension ContentIndex {
    func file(path: String) throws -> (record: ContentFileRecord, id: Int64, revision: Int64)? {
        let statement = try statement("SELECT id, size, mtime, kind, parser, revision FROM files WHERE path=?")
        defer { sqlite3_reset(statement.handle) }
        statement.bind([path])
        guard try statement.next() else { return nil }
        let record = ContentFileRecord(path: path, size: statement.int(1), mtime: statement.int(2),
                                       kind: UInt8(truncatingIfNeeded: statement.int(3)), parser: statement.text(4))
        return (record, statement.int(0), statement.int(5))
    }

    // Note: do not add a second `file(path:)` overload that differs only in return type.
    // `try index.file(path: p)?.revision` is then ambiguous, and the tests rely on it.
    @discardableResult
    func upsert(file record: ContentFileRecord) throws -> Int64 {
        if let existing = try file(path: record.path) {
            guard existing.record.size != record.size || existing.record.mtime != record.mtime
                || existing.record.kind != record.kind || existing.record.parser != record.parser else {
                return existing.id
            }
            let statement = try statement("UPDATE files SET size=?, mtime=?, kind=?, parser=?, revision=revision+1 WHERE id=?")
            defer { sqlite3_reset(statement.handle) }
            statement.bind([String(record.size), String(record.mtime), String(record.kind),
                            record.parser, String(existing.id)])
            _ = try statement.next()
            return existing.id
        }
        let statement = try statement("INSERT INTO files(path,size,mtime,kind,parser) VALUES(?,?,?,?,?)")
        defer { sqlite3_reset(statement.handle) }
        statement.bind([record.path, String(record.size), String(record.mtime),
                        String(record.kind), record.parser])
        _ = try statement.next()
        return sqlite3_last_insert_rowid(sql.db)
    }

    func replaceChunks(file id: Int64, chunks: [ContentChunk]) throws {
        try transaction {
            // The `chunk_postings_delete` trigger added in Task 2 drops the matching postings.
            let drop = try statement("DELETE FROM chunks WHERE file=?")
            drop.bind([String(id)]); _ = try drop.next(); sqlite3_reset(drop.handle)
            // The blob column is last so the text binds can use one `bind` call.
            let insert = try statement("INSERT INTO chunks(file,ordinal,label,bytes,folded) VALUES(?,?,?,?,?)")
            let fts = try statement("INSERT INTO chunk_fts(rowid,grams) VALUES(?,?)")
            for chunk in chunks {
                // Grams must come from the folded text: `AITopicIndex` builds document grams
                // from folded text (AITopicIndex.swift:274) and folds the query before gramming
                // it (:618), so gramming raw text here would make matches case-sensitive.
                let foldedText = AITopicIndex.fold(chunk.text)
                let folded = Data(foldedText.utf8)
                let packed = ContentCompression.pack(folded, compact: true)
                // `bytes` is the UNCOMPRESSED length: unpack decodes in one exact-size pass.
                insert.bind([String(id), String(chunk.ordinal), chunk.label, String(folded.count)])
                Self.bindBlob(packed, at: 5, into: insert)
                _ = try insert.next()
                let rowid = sqlite3_last_insert_rowid(sql.db)
                sqlite3_reset(insert.handle)
                let grams = try AITopicIndex.grams(foldedText, checkpoint: nil)
                fts.bind([String(rowid), grams]); _ = try fts.next(); sqlite3_reset(fts.handle)
            }
        }
    }

    static func bindBlob(_ data: Data, at column: Int32, into statement: AITopicStatement) {
        let bytes = [UInt8](data)
        _ = bytes.withUnsafeBufferPointer {
            sqlite3_bind_blob(statement.handle, column, $0.baseAddress, Int32($0.count),
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    func chunkCount(file id: Int64) throws -> Int {
        let statement = try statement("SELECT COUNT(*) FROM chunks WHERE file=?")
        defer { sqlite3_reset(statement.handle) }
        statement.bind([String(id)])
        guard try statement.next() else { return 0 }
        return Int(statement.int(0))
    }

    func removeFile(path: String) throws {
        try transaction {
            guard let existing = try file(path: path) else { return }
            // Cascades to `chunks`, whose delete trigger drops the postings.
            let drop = try statement("DELETE FROM files WHERE id=?")
            drop.bind([String(existing.id)]); _ = try drop.next(); sqlite3_reset(drop.handle)
        }
    }

    func removeFiles(prefix: String) throws {
        let statement = try statement("SELECT path FROM files WHERE path LIKE ? ESCAPE '\\'")
        let escaped = prefix.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        statement.bind([escaped + "%"])
        var paths: [String] = []
        while try statement.next() { paths.append(statement.text(0)) }
        // Reset before writing: `BEGIN IMMEDIATE` while a SELECT is still active on this
        // connection is the lock pattern this project has already been bitten by.
        sqlite3_reset(statement.handle)
        // One transaction for the whole prefix, so a failure cannot leave half a volume gone.
        try transaction {
            for path in paths { try removeFile(path: path) }
        }
    }

    func transaction(_ work: () throws -> Void) throws {
        if inTransaction { try work(); return }
        try sql.run("BEGIN IMMEDIATE")
        // Only mark the transaction open once BEGIN succeeded, or a failure leaves the flag stuck.
        inTransaction = true
        do { try work(); try sql.run("COMMIT") }
        catch { try? sql.run("ROLLBACK"); inTransaction = false; throw error }
        inTransaction = false
    }
}
```

注意：`replaceChunks` 里的 blob 绑定写法在实现时统一成一个小 helper（`bindBlob(_:at:into:)`），别重复三遍。postings 的清理由 Task 2 建的 `chunk_postings_delete` 触发器负责，这里不要再手写 `DELETE FROM chunk_fts`。

**Step 4: 跑测试确认通过**

Run: `swift test --filter ContentIndexWriteTests`
Expected: PASS

**Step 5: 提交**

```sh
git add Sources/OilFindApp/ContentSearch/ContentIndex.swift Tests/OilFindUITests/ContentIndexWriteTests.swift
git commit -m "feat(content): store files and chunks with cascade delete"
```

---

## Task 4: 检索与字面验证

gram 检索会给出跨 gram 的假阳性，必须逐字节字面验证候选。

**Files:**
- Modify: `Sources/OilFindApp/ContentSearch/ContentIndex.swift`
- Test: `Tests/OilFindUITests/ContentIndexSearchTests.swift`

**Step 1: 写失败测试**

```swift
import XCTest
@testable import OilFindApp

final class ContentIndexSearchTests: XCTestCase {
    private var url: URL!
    private var index: ContentIndex!
    /// The database runs in WAL mode, so the sidecars are left behind if only the main file goes.
    private func removeDatabase(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("content-" + UUID().uuidString + ".sqlite")
        index = try ContentIndex(url: url)
    }
    override func tearDownWithError() throws { index = nil; removeDatabase(url) }

    private func add(_ path: String, chunks: [(Int, String, String)]) throws {
        let id = try index.upsert(file: .init(path: path, size: 1, mtime: 1, kind: 3, parser: "text"))
        try index.replaceChunks(file: id, chunks: chunks.map { .init(ordinal: $0.0, label: $0.1, text: $0.2) })
    }

    func testFindsChineseSubstringWithLabelAndHighlight() throws {
        try add("/a/report.pdf", chunks: [(2, "第 3 页", "本月开具发票的日期是三月五日")])
        let hits = try index.search("发票", limit: 10, isCancelled: { false })
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].path, "/a/report.pdf")
        XCTAssertEqual(hits[0].label, "第 3 页")
        let snippet = hits[0].snippet as NSString
        XCTAssertEqual(snippet.substring(with: hits[0].highlights[0]), "发票")
    }

    func testIsCaseInsensitiveAndFindsEnglish() throws {
        try add("/a/invoice.md", chunks: [(0, "第 1 行附近", "Invoice #1234 due Friday")])
        XCTAssertEqual(try index.search("invoice", limit: 10, isCancelled: { false }).count, 1)
        XCTAssertEqual(try index.search("INVOICE", limit: 10, isCancelled: { false }).count, 1)
    }

    func testDoesNotReportMatchesThatOnlyExistAcrossChunkBoundaries() throws {
        try add("/a/split.txt", chunks: [(0, "第 1 行附近", "本月的收"), (1, "第 900 行附近", "据已经归档")])
        XCTAssertTrue(try index.search("收据", limit: 10, isCancelled: { false }).isEmpty)
    }

    func testReturnsEachFileOnceWithItsBestChunk() throws {
        try add("/a/many.txt", chunks: [(0, "第 1 行附近", "发票"), (1, "第 500 行附近", "发票 发票 发票")])
        let hits = try index.search("发票", limit: 10, isCancelled: { false })
        XCTAssertEqual(hits.count, 1)
    }

    func testRespectsLimitAndCancellation() throws {
        for i in 0..<20 { try add("/a/\(i).txt", chunks: [(0, "第 1 行附近", "开具发票的日期")]) }
        XCTAssertEqual(try index.search("发票", limit: 5, isCancelled: { false }).count, 5)
        XCTAssertTrue(try index.search("发票", limit: 5, isCancelled: { true }).isEmpty)
    }
}
```

**Step 2: 跑测试确认失败**

Run: `swift test --filter ContentIndexSearchTests`
Expected: 编译失败，`has no member 'search'`

**Step 3: 实现**

追加到 `ContentIndex.swift`：

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
    /// Candidates come from the gram index; every candidate is then verified byte by byte so
    /// matches spanning two grams or two chunks are never reported.
    func search(_ text: String, limit: Int, isCancelled: () -> Bool) throws -> [ContentHit] {
        let folded = AITopicIndex.fold(text)
        let terms = Array(Set(folded.split(whereSeparator: { $0.isWhitespace }).map(String.init))).sorted()
        guard limit > 0, !terms.isEmpty else { return [] }
        let needles = terms.map { Array($0.utf8) }
        // `grams` throws, so it cannot be called from inside `flatMap` without `try` there.
        let gramsPerTerm = try terms.map { AITopicIndex.grams($0, query: true) }
        let query = Set(gramsPerTerm.flatMap { $0.components(separatedBy: " AND ") })
            .sorted().joined(separator: " AND ")
        guard !query.isEmpty else { return [] }

        let statement = try statement("""
            SELECT c.id, f.path, f.kind, c.ordinal, c.label, c.folded, c.bytes
            FROM chunk_fts JOIN chunks c ON c.id = chunk_fts.rowid JOIN files f ON f.id = c.file
            WHERE chunk_fts MATCH ? ORDER BY rank
            """)
        defer { sqlite3_reset(statement.handle) }
        statement.bind([query])
        var best: [String: ContentHit] = [:]
        while try statement.next() {
            if isCancelled() { return [] }
            // A NULL or unreadable body skips this row; it must not abort the whole query.
            let stored = blob(statement, 5)
            guard !stored.isEmpty,
                  let body = try? ContentCompression.unpack(stored, bytes: Int(statement.int(6))) else { continue }
            let bytes = [UInt8](body)
            // The gram AND admits false positives; every term must also appear literally.
            guard needles.allSatisfy({ !Self.byteRanges(of: $0, in: bytes).isEmpty }) else { continue }
            let path = statement.text(1)
            let snippet = Self.snippet(text: String(decoding: bytes, as: UTF8.self), terms: terms)
            if let existing = best[path], existing.highlights.count >= snippet.highlights.count { continue }
            best[path] = ContentHit(path: path, kind: UInt8(truncatingIfNeeded: statement.int(2)),
                                    label: statement.text(4), snippet: snippet.text,
                                    highlights: snippet.highlights)
            if best.count >= limit { break }
        }
        return best.values.sorted { $0.path < $1.path }
    }

    /// Byte-level verification. A match can never start inside a multi-byte scalar, because a
    /// valid UTF-8 lead byte is never a continuation byte, so this cannot report a partial match.
    private static func byteRanges(of needle: [UInt8], in haystack: [UInt8]) -> [Range<Int>] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        var result: [Range<Int>] = []
        var i = 0
        while i + needle.count <= haystack.count {
            if haystack[i] == needle[0], haystack[i..<i + needle.count].elementsEqual(needle) {
                result.append(i..<i + needle.count)
                i += needle.count
            } else { i += 1 }
        }
        return result
    }

    /// `before` / `after` count UTF-16 units, not characters. Ranges are computed on the decoded
    /// text rather than the bytes, because byte offsets do not map linearly to UTF-16 offsets and
    /// `ResultsView` colours with `NSRange`. The caller has already verified the terms are present.
    private static func snippet(text: String, terms: [String], before: Int = 40,
                                after: Int = 60) -> (text: String, highlights: [NSRange]) {
        var ranges: [NSRange] = []
        for term in terms {
            var search = text.startIndex..<text.endIndex
            while let found = text.range(of: term, range: search) {
                ranges.append(NSRange(found, in: text))
                guard ranges.count < 20 else { break }
                search = found.upperBound..<text.endIndex
            }
        }
        guard let first = ranges.min(by: { $0.location < $1.location }) else { return (text, []) }
        let base = max(0, first.location - before)
        let limit = min(text.utf16.count, NSMaxRange(first) + after)
        guard let window = Range(NSRange(location: base, length: limit - base), in: text) else {
            return (text, ranges)
        }
        let shown = NSRange(window, in: text)
        let highlights = ranges.compactMap { range -> NSRange? in
            guard range.location >= shown.location, NSMaxRange(range) <= NSMaxRange(shown) else { return nil }
            return NSRange(location: range.location - shown.location, length: range.length)
        }
        return (String(text[window]), highlights)
    }

    private func blob(_ statement: AITopicStatement, _ column: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(statement.handle, column) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement.handle, column)))
    }
}
```

**Step 4: 跑测试确认通过**

Run: `swift test --filter ContentIndexSearchTests`
Expected: PASS

**Step 5: 提交**

```sh
git add Sources/OilFindApp/ContentSearch/ContentIndex.swift Tests/OilFindUITests/ContentIndexSearchTests.swift
git commit -m "feat(content): search chunks with byte-level verification"
```

---

## Task 5: 增量同步

**Files:**
- Modify: `Sources/OilFindApp/ContentSearch/ContentIndex.swift`
- Test: `Tests/OilFindUITests/ContentIndexSyncTests.swift`

**Step 1: 写失败测试**

```swift
import XCTest
@testable import OilFindApp

final class ContentIndexSyncTests: XCTestCase {
    private var url: URL!
    private var index: ContentIndex!
    /// The database runs in WAL mode, so the sidecars are left behind if only the main file goes.
    private func removeDatabase(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("content-" + UUID().uuidString + ".sqlite")
        index = try ContentIndex(url: url)
    }
    override func tearDownWithError() throws { index = nil; removeDatabase(url) }

    func testDetectsNewChangedAndRemovedFiles() throws {
        try index.replaceChunks(file: try index.upsert(file: .init(path: "/a/1.txt", size: 1, mtime: 1, kind: 3, parser: "text")),
                                chunks: [.init(ordinal: 0, label: "", text: "发票")])
        try index.replaceChunks(file: try index.upsert(file: .init(path: "/a/2.txt", size: 1, mtime: 1, kind: 3, parser: "text")),
                                chunks: [.init(ordinal: 0, label: "", text: "发票")])
        // 1.txt unchanged, 2.txt edited, 3.txt new; every indexed file is in the snapshot.
        let plan = try index.plan(candidates: [
            .init(path: "/a/1.txt", size: 1, mtime: 1, kind: 3, parser: "text"),
            .init(path: "/a/2.txt", size: 9, mtime: 9, kind: 3, parser: "text"),
            .init(path: "/a/3.txt", size: 1, mtime: 1, kind: 3, parser: "text")])
        XCTAssertEqual(plan.unchanged.map(\.path), ["/a/1.txt"])
        XCTAssertEqual(plan.changed.map(\.path), ["/a/2.txt"])
        XCTAssertEqual(plan.added.map(\.path), ["/a/3.txt"])
        XCTAssertEqual(plan.removed, [])
    }

    func testIncompleteEnumerationNeverDeletes() throws {
        try index.replaceChunks(file: try index.upsert(file: .init(path: "/a/1.txt", size: 1, mtime: 1, kind: 3, parser: "text")),
                                chunks: [.init(ordinal: 0, label: "", text: "发票")])
        let plan = try index.plan(candidates: [], complete: false)
        XCTAssertEqual(plan.removed, [])
        XCTAssertEqual(try index.count(), 1)
    }
}
```

**Step 2: 跑测试确认失败**

Run: `swift test --filter ContentIndexSyncTests`
Expected: 编译失败，`has no member 'plan'`

**Step 3: 实现**

追加到 `ContentIndex.swift`：

```swift
extension ContentIndex {
    struct SyncPlan {
        var added: [ContentFileRecord] = []
        var changed: [ContentFileRecord] = []
        var unchanged: [ContentFileRecord] = []
        var removed: [String] = []
    }

    /// Diffs the file-system snapshot against the index. `complete` is false when the candidate
    /// enumeration could not finish, in which case nothing is deleted.
    func plan(candidates: [ContentFileRecord], complete: Bool = true) throws -> SyncPlan {
        var plan = SyncPlan()
        var seen = Set<String>()
        for candidate in candidates {
            seen.insert(candidate.path)
            guard let existing = try file(path: candidate.path) else { plan.added.append(candidate); continue }
            if existing.record.size == candidate.size, existing.record.mtime == candidate.mtime,
               existing.record.parser == candidate.parser { plan.unchanged.append(candidate) }
            else { plan.changed.append(candidate) }
        }
        guard complete else { return plan }
        // Swift has `for ... where` but not `while ... where`.
        let statement = try statement("SELECT path FROM files")
        defer { sqlite3_reset(statement.handle) }
        while try statement.next() {
            let path = statement.text(0)
            if !seen.contains(path) { plan.removed.append(path) }
        }
        return plan
    }

    func apply(_ plan: SyncPlan, parse: (ContentFileRecord) throws -> [ContentChunk]) throws {
        for path in plan.removed { try removeFile(path: path) }
        for record in plan.added + plan.changed {
            let id = try upsert(file: record)
            try replaceChunks(file: id, chunks: try parse(record))
        }
    }
}
```

**Step 4: 跑测试确认通过**

Run: `swift test --filter ContentIndexSyncTests`
Expected: PASS

**Step 5: 提交**

```sh
git add Sources/OilFindApp/ContentSearch/ContentIndex.swift Tests/OilFindUITests/ContentIndexSyncTests.swift
git commit -m "feat(content): diff file system snapshot against the index"
```

---

## Task 6: 图片 OCR 解析器

**Files:**
- Create: `Sources/OilFindApp/ContentSearch/Parsers/ContentParser.swift`
- Create: `Sources/OilFindApp/ContentSearch/Parsers/ImageOCRParser.swift`
- Test: `Tests/OilFindUITests/ImageOCRParserTests.swift`

**Step 1: 写失败测试**

```swift
import AppKit
import XCTest
@testable import OilFindApp

final class ImageOCRParserTests: XCTestCase {
    // `lockFocus` / `unlockFocus` are deprecated on macOS 14; the drawing-handler initialiser is not.
    private func screenshot(_ text: String, size: NSSize = NSSize(width: 900, height: 260)) throws -> URL {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            (text as NSString).draw(at: NSPoint(x: 40, y: 110),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 64),
                                                     .foregroundColor: NSColor.black])
            return true
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-" + UUID().uuidString + ".png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    func testRecognizesChineseTextInAScreenshot() throws {
        guard ProcessInfo.processInfo.environment["CI"] != "true" else { throw XCTSkip("OCR needs a real Vision runtime") }
        let url = try screenshot("开具发票")
        defer { try? FileManager.default.removeItem(at: url) }
        let chunks = try ImageOCRParser().parse(url: url, budget: AITopicWorkBudget(), isCancelled: { false })
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].ordinal, 0)
        XCTAssertTrue(chunks[0].text.contains("发票"), "recognized: \(chunks[0].text)")
    }

    func testImageWithoutTextProducesNoChunks() throws {
        guard ProcessInfo.processInfo.environment["CI"] != "true" else { throw XCTSkip("OCR needs a real Vision runtime") }
        let url = try screenshot("")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try ImageOCRParser().parse(url: url, budget: AITopicWorkBudget(), isCancelled: { false }).isEmpty)
    }

    func testCancellationStopsBeforeRunningVision() throws {
        let url = try screenshot("开具发票")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try ImageOCRParser().parse(url: url, budget: AITopicWorkBudget(), isCancelled: { true }).isEmpty)
    }
}
```

**Step 2: 跑测试确认失败**

Run: `swift test --filter ImageOCRParserTests`
Expected: 编译失败，`cannot find 'ImageOCRParser' in scope`

**Step 3: 实现**

新建 `Sources/OilFindApp/ContentSearch/Parsers/ContentParser.swift`：

```swift
import Foundation

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
```

新建 `Sources/OilFindApp/ContentSearch/Parsers/ImageOCRParser.swift`：

```swift
import Foundation
import Vision

/// Vision text recognition. Revision is part of the identifier so a revision change reindexes.
struct ImageOCRParser: ContentParser {
    static let revision = VNRecognizeTextRequestRevision3
    /// Formats `CGImageSource` can decode. SVG, PSD, AI and camera raw are deliberately absent.
    static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp",
                                                   "bmp", "tif", "tiff", "avif", "icns", "ico"]
    var identifier: String { "ocr-\(Self.revision)" }
    var kinds: Set<UInt8> { [4] }
    var extensions: Set<String> { Self.supportedExtensions }

    /// Long edges above this are downsampled first: recognition cost grows with pixel count and
    /// `perform` cannot yield, so a smaller image keeps single-file latency bounded.
    static let maximumDimension: CGFloat = 3000

    func parse(url: URL, budget: AITopicWorkBudget, isCancelled: () -> Bool) throws -> [ContentChunk] {
        guard !isCancelled() else { return [] }
        let request = VNRecognizeTextRequest()
        request.revision = Self.revision
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(url: url, options: [:])
        do { try handler.perform([request]) }
        catch { throw ContentParserError.damaged }
        guard !isCancelled(), let observations = request.results, !observations.isEmpty else { return [] }
        // Vision returns observations in no guaranteed order; sort top-to-bottom then left-to-right.
        let lines = observations
            .sorted { a, b in
                let ay = a.boundingBox.midY, by = b.boundingBox.midY
                return abs(ay - by) > 0.01 ? ay > by : a.boundingBox.minX < b.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty else { return [] }
        return [ContentChunk(ordinal: 0, label: "", text: text)]
    }
}
```

**Step 4: 跑测试确认通过**

Run: `swift test --filter ImageOCRParserTests`
Expected: PASS

**Step 5: 提交**

```sh
git add Sources/OilFindApp/ContentSearch/Parsers/ Tests/OilFindUITests/ImageOCRParserTests.swift
git commit -m "feat(content): extract text from images with Vision"
```

---

## Task 7: 纯文本 / Markdown 解析器

**Files:**
- Create: `Sources/OilFindApp/ContentSearch/Parsers/TextParser.swift`
- Test: `Tests/OilFindUITests/TextParserTests.swift`

**Step 1: 写失败测试**

```swift
import XCTest
@testable import OilFindApp

final class TextParserTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("text-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name); try data.write(to: url); return url
    }

    func testReadsUTF8AndReportsLineLabels() throws {
        let body = (1...200).map { "第 \($0) 行" }.joined(separator: "\n")
        let chunks = try TextParser().parse(url: try write("a.txt", Data(body.utf8)), budget: AITopicWorkBudget(), isCancelled: { false })
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].ordinal, 0)
        XCTAssertTrue(chunks[0].text.contains("第 200 行"))
        XCTAssertTrue(chunks[0].label.hasPrefix("第 1 行"))
    }

    func testSplitsLongFilesIntoMultipleChunks() throws {
        let body = (1...20000).map { "第 \($0) 行，这里是一些足够长的中文内容用来撑大文件体积。" }.joined(separator: "\n")
        let chunks = try TextParser().parse(url: try write("big.log", Data(body.utf8)), budget: AITopicWorkBudget(), isCancelled: { false })
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.ordinal), Array(0..<chunks.count))
    }

    func testDetectsUTF16() throws {
        let body = "开具发票的日期"
        let data = try XCTUnwrap(body.data(using: .utf16))
        let chunks = try TextParser().parse(url: try write("u16.txt", data), budget: AITopicWorkBudget(), isCancelled: { false })
        XCTAssertTrue(chunks[0].text.contains("开具发票"))
    }

    func testFallsBackToGB18030ForLegacyChineseFiles() throws {
        let body = "开具发票的日期是三月五日"
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let data = try XCTUnwrap(body.data(using: encoding))
        let chunks = try TextParser().parse(url: try write("gbk.txt", data), budget: AITopicWorkBudget(), isCancelled: { false })
        XCTAssertTrue(chunks[0].text.contains("开具发票"), "decoded: \(chunks[0].text)")
    }

    func testRejectsOversizedFiles() throws {
        let url = try write("huge.txt", Data(repeating: 0x41, count: 1024))
        XCTAssertThrowsError(try TextParser(maximumBytes: 512).parse(url: url, budget: AITopicWorkBudget(), isCancelled: { false }))
    }
}
```

**Step 2: 跑测试确认失败**

Run: `swift test --filter TextParserTests`
Expected: 编译失败，`cannot find 'TextParser' in scope`

**Step 3: 实现**

新建 `Sources/OilFindApp/ContentSearch/Parsers/TextParser.swift`：

```swift
import Foundation

/// Plain text, Markdown, CSV/TSV and logs. Splits on line boundaries into ~64 KiB chunks.
struct TextParser: ContentParser {
    var maximumBytes = 32 * 1024 * 1024
    var chunkBytes = 64 * 1024
    var identifier: String { "text-1" }
    var kinds: Set<UInt8> { [3] }
    var extensions: Set<String> { ["txt", "md", "markdown", "csv", "tsv", "log"] }

    func parse(url: URL, budget: AITopicWorkBudget, isCancelled: () -> Bool) throws -> [ContentChunk] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size <= maximumBytes else { throw ContentParserError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let text = try Self.decode(data)
        guard !text.isEmpty else { return [] }

        var chunks: [ContentChunk] = []
        var buffer = "", firstLine = 1, line = 1
        for piece in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if buffer.utf8.count + piece.utf8.count + 1 > chunkBytes, !buffer.isEmpty {
                chunks.append(ContentChunk(ordinal: chunks.count, label: "第 \(firstLine) 行附近", text: buffer))
                buffer = ""; firstLine = line
            }
            if !buffer.isEmpty { buffer += "\n" }
            buffer += piece
            line += 1
            try budget.checkpoint(isCancelled: isCancelled)
            if isCancelled() { return [] }
        }
        if !buffer.isEmpty { chunks.append(ContentChunk(ordinal: chunks.count, label: "第 \(firstLine) 行附近", text: buffer)) }
        return chunks
    }

    /// UTF-8 first, then UTF-16 when a BOM says so, then GB18030 for the legacy Chinese files
    /// that are still common in exports and downloads.
    ///
    /// UTF-16 is only accepted with a BOM. Without one, almost any byte sequence "decodes" as
    /// UTF-16 into garbage, which would silently win over the correct GB18030 reading. The cost
    /// is that a BOM-less UTF-16 file is read as GB18030 instead; that is the rarer case.
    static func decode(_ data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        let prefix = [UInt8](data.prefix(2))
        if prefix == [0xFF, 0xFE] || prefix == [0xFE, 0xFF],
           let text = String(data: data, encoding: .utf16) { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb18030) { return text }
        throw ContentParserError.damaged
    }
}
```

**Step 4: 跑测试确认通过**

Run: `swift test --filter TextParserTests`
Expected: PASS

**Step 5: 提交**

```sh
git add Sources/OilFindApp/ContentSearch/Parsers/TextParser.swift Tests/OilFindUITests/TextParserTests.swift
git commit -m "feat(content): parse plain text with encoding fallback"
```

---

## Task 8: 索引器（候选枚举 + 预算 + 取消）

**Files:**
- Create: `Sources/OilFindApp/ContentSearch/ContentIndexer.swift`
- Test: `Tests/OilFindUITests/ContentIndexerTests.swift`

**Step 1: 写失败测试**

```swift
import XCTest
import OilFindCore
@testable import OilFindApp

/// Stands in for a real parser where the test only cares about selection, not extraction.
private struct StubParser: ContentParser {
    let identifier: String
    let kinds: Set<UInt8>
    var extensions: Set<String> { ["*"] }
    func parse(url: URL, budget: AITopicWorkBudget, isCancelled: () -> Bool) throws -> [ContentChunk] {
        [ContentChunk(ordinal: 0, label: "", text: "开具发票")]
    }
}

final class ContentIndexerTests: XCTestCase {
    private var dir: URL!, db: URL!, index: ContentIndex!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("idx-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = dir.appendingPathComponent("index.sqlite")
        index = try ContentIndex(url: db)
    }
    override func tearDownWithError() throws { index = nil; try? FileManager.default.removeItem(at: dir) }

    /// Index 0 must be the root directory: `IndexStore.resolve(path:)` walks down from it.
    /// `sizes` and `mtimes` are `[UInt32]` on `ScanBuffer`, not `UInt64`/`Int64`.
    private func store(root: String, names: [String], kinds: [UInt8]) -> IndexStore {
        var buffer = ScanBuffer()
        let count = names.count
        buffer.ids = (0..<UInt32(count)).map { $0 }
        buffer.parents = [UInt32](repeating: 0, count: count)
        buffer.sizes = [UInt32](repeating: 1, count: count)
        buffer.mtimes = [UInt32](repeating: 1, count: count)
        buffer.flags = [SiftFlag.dir] + [UInt8](repeating: SiftFlag.userArea, count: count - 1)
        buffer.depths = [0] + [UInt8](repeating: 1, count: count - 1)
        buffer.kinds = kinds
        buffer.nameLens = names.map { UInt32($0.utf8.count) }
        buffer.nameBytes = Array(names.joined().utf8)
        return IndexStore(scan: ScanOutput(buffers: [buffer], count: count, homeIndex: .max, elapsed: 0, finishedAt: 0),
                          config: IndexConfig(rootPath: root))
    }

    func testIndexesOnlyDocumentAndImageEntries() throws {
        let text = dir.appendingPathComponent("note.txt"); try Data("开具发票的日期".utf8).write(to: text)
        let store = store(root: dir.path, names: ["", "note.txt", "app.bin"], kinds: [1, 3, 0])
        let indexer = ContentIndexer(index: index, parsers: [TextParser()])
        try indexer.synchronize(store: store, isCancelled: { false })
        XCTAssertEqual(try index.count(), 1)
        XCTAssertEqual(try index.search("发票", limit: 10, isCancelled: { false }).first?.path, text.path)
    }

    func testSecondRunIsANoOp() throws {
        let text = dir.appendingPathComponent("note.txt"); try Data("开具发票的日期".utf8).write(to: text)
        let store = store(root: dir.path, names: ["", "note.txt"], kinds: [1, 3])
        let indexer = ContentIndexer(index: index, parsers: [TextParser()])
        try indexer.synchronize(store: store, isCancelled: { false })
        let first = try index.file(path: text.path)
        try indexer.synchronize(store: store, isCancelled: { false })
        XCTAssertEqual(try index.file(path: text.path)?.revision, first?.revision)
    }

    func testRemovedFileIsDroppedFromTheIndex() throws {
        let text = dir.appendingPathComponent("note.txt"); try Data("开具发票".utf8).write(to: text)
        let indexer = ContentIndexer(index: index, parsers: [TextParser()])
        try indexer.synchronize(store: store(root: dir.path, names: ["", "note.txt"], kinds: [1, 3]), isCancelled: { false })
        try FileManager.default.removeItem(at: text)
        try indexer.synchronize(store: store(root: dir.path, names: [""], kinds: [1]), isCancelled: { false })
        XCTAssertEqual(try index.count(), 0)
    }

    func testImageEntriesUseTheImageParser() throws {
        // A stub keeps this test off the Vision runtime; it only checks parser selection.
        let png = dir.appendingPathComponent("shot.png"); try Data([0x89]).write(to: png)
        let indexer = ContentIndexer(index: index, parsers: [StubParser(identifier: "stub-ocr", kinds: [4])])
        try indexer.synchronize(store: store(root: dir.path, names: ["", "shot.png"], kinds: [1, 4]),
                                isCancelled: { false })
        XCTAssertEqual(try index.file(path: png.path)?.record.parser, "stub-ocr")
        XCTAssertEqual(try index.count(), 1)
    }

    func testDamagedFileIsSkippedAndCounted() throws {
        let bad = dir.appendingPathComponent("bad.txt")
        try Data([0xFF, 0xFE, 0x00, 0x01, 0xFF]).write(to: bad)
        let indexer = ContentIndexer(index: index, parsers: [TextParser()])
        try indexer.synchronize(store: store(root: dir.path, names: ["", "bad.txt"], kinds: [1, 3]), isCancelled: { false })
        XCTAssertEqual(indexer.failedCount, 1)
    }
}
```

**Step 2: 跑测试确认失败**

Run: `swift test --filter ContentIndexerTests`
Expected: 编译失败，`cannot find 'ContentIndexer' in scope`

**Step 3: 实现**

新建 `Sources/OilFindApp/ContentSearch/ContentIndexer.swift`：

```swift
import Foundation
import OilFindCore

/// Walks the file index for document and image entries and keeps the content index in sync.
/// Candidates come from `IndexStore` rather than the file system, so the existing index scope
/// and exclusions apply automatically.
final class ContentIndexer {
    private let index: ContentIndex
    private let parsers: [ContentParser]
    private let budget: AITopicWorkBudget
    private(set) var failedCount = 0

    /// The store's read lock blocks index writes, so candidates are copied out in batches.
    static let batchSize = 20_000

    init(index: ContentIndex, parsers: [ContentParser], budget: AITopicWorkBudget = AITopicWorkBudget(fraction: 0.10)) {
        self.index = index; self.parsers = parsers; self.budget = budget
    }

    func synchronize(store: IndexStore, isCancelled: () -> Bool) throws {
        failedCount = 0
        var candidates: [ContentFileRecord] = []
        var complete = true
        var offset = 1
        while offset < store.count {
            if isCancelled() { complete = false; break }
            let batch = store.read { () -> [ContentFileRecord] in
                let upper = min(store.count, offset + Self.batchSize)
                var records: [ContentFileRecord] = []
                records.reserveCapacity(upper - offset)
                for i in offset..<upper where store.isLive(UInt32(i)) {
                    let kind = store.kind[i]
                    guard kind == 3 || kind == 4, store.flags[i] & SiftFlag.dir == 0 else { continue }
                    let path = store.path(UInt32(i))
                    guard let parser = parser(for: path, kind: kind) else { continue }
                    records.append(ContentFileRecord(path: path, size: Int64(store.size(UInt32(i))),
                                                     mtime: Int64(store.mtime[i]), kind: kind, parser: parser.identifier))
                }
                return records
            }
            candidates.append(contentsOf: batch)
            offset += Self.batchSize
            try budget.checkpoint(isCancelled: isCancelled)
        }
        let plan = try index.plan(candidates: candidates, complete: complete)
        try index.apply(plan) { record in
            guard let parser = parsers.first(where: { $0.identifier == record.parser }) else { return [] }
            do { return try parser.parse(url: URL(fileURLWithPath: record.path), budget: budget, isCancelled: isCancelled) }
            catch { failedCount += 1; return [] }
        }
    }

    /// Selection is data-driven so a parser's reach is declared where the parser lives, and so a
    /// test can substitute a stub without depending on Vision.
    private func parser(for path: String, kind: UInt8) -> ContentParser? {
        let ext = (path as NSString).pathExtension.lowercased()
        return parsers.first {
            $0.kinds.contains(kind) && ($0.extensions.contains("*") || $0.extensions.contains(ext))
        }
    }
}
```

**Step 4: 跑测试确认通过**

Run: `swift test --filter ContentIndexerTests`
Expected: PASS

**Step 5: 提交**

```sh
git add Sources/OilFindApp/ContentSearch/ContentIndexer.swift Tests/OilFindUITests/ContentIndexerTests.swift
git commit -m "feat(content): index document and image entries from the file index"
```

---

## Task 9: Provider —— 路径解析成 entryID

这是整个 M1 最容易出错的一环。必须有一条测试证明**压实之后命中仍然指向同一个文件**。

**Files:**
- Create: `Sources/OilFindApp/ContentSearch/ContentSearchProvider.swift`
- Test: `Tests/OilFindUITests/ContentSearchProviderTests.swift`

**Step 1: 写失败测试**

```swift
import XCTest
import OilFindCore
@testable import OilFindApp

final class ContentSearchProviderTests: XCTestCase {
    private var dir: URL!, index: ContentIndex!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("prov-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        index = try ContentIndex(url: dir.appendingPathComponent("index.sqlite"))
    }
    override func tearDownWithError() throws { index = nil; try? FileManager.default.removeItem(at: dir) }

    /// Builds a store whose root is "/": index 0 is the directory and every entry in `paths` is a
    /// direct child, so pass "/note.txt", not "sub/note.txt". `resolve(path:)` walks down from
    /// index 0, which must carry the dir flag and must be live.
    private func store(paths: [String]) -> IndexStore {
        var buffer = ScanBuffer()
        let names = [""] + paths.map { ($0 as NSString).lastPathComponent }
        let count = names.count
        buffer.ids = (0..<UInt32(count)).map { $0 }
        buffer.parents = [UInt32](repeating: 0, count: count)
        buffer.sizes = [UInt32](repeating: 1, count: count)
        buffer.mtimes = [UInt32](repeating: 1, count: count)
        buffer.flags = [SiftFlag.dir] + [UInt8](repeating: SiftFlag.userArea, count: count - 1)
        buffer.depths = [0] + [UInt8](repeating: 1, count: count - 1)
        buffer.kinds = [1] + [UInt8](repeating: 3, count: count - 1)
        buffer.nameLens = names.map { UInt32($0.utf8.count) }
        buffer.nameBytes = Array(names.joined().utf8)
        return IndexStore(scan: ScanOutput(buffers: [buffer], count: count, homeIndex: .max, elapsed: 0, finishedAt: 0),
                          config: IndexConfig(rootPath: "/"))
    }

    func testResolvesPathToTheCurrentEntryID() throws {
        let store = store(paths: ["/note.txt"])
        store.buildHash()
        let id = try index.upsert(file: .init(path: "/note.txt", size: 1, mtime: 1, kind: 3, parser: "text-1"))
        try index.replaceChunks(file: id, chunks: [.init(ordinal: 0, label: "", text: "开具发票的日期")])
        let provider = ContentSearchProvider(index: index)
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store)
        let hits = provider.prepareSearch(Query.parse("发票"), options: SearchOptions(), sources: [source], isCancelled: { false })()
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(store.path(hits[0].entryID), "/note.txt")
        XCTAssertEqual(hits[0].sourceVersion, store.read { store.version })
    }

    /// The regression this design exists to prevent: compaction renumbers entries, so a stored
    /// entry ID would point at a different file. Storing paths keeps the hit on the right file.
    func testHitStillPointsAtTheSameFileAfterCompaction() throws {
        let store = store(paths: ["/gone.txt", "/note.txt"])
        store.write { _ = store.remove(1) }         // "gone.txt" is now a tombstone
        let compacted = store.read { store.compacted() }   // renumbers every live entry
        XCTAssertEqual(compacted.path(compacted.resolve(path: "/note.txt")!), "/note.txt")
        let id = try index.upsert(file: .init(path: "/note.txt", size: 1, mtime: 1, kind: 3, parser: "text-1"))
        try index.replaceChunks(file: id, chunks: [.init(ordinal: 0, label: "", text: "开具发票的日期")])
        let provider = ContentSearchProvider(index: index)
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: compacted)
        let hits = provider.prepareSearch(Query.parse("发票"), options: SearchOptions(), sources: [source], isCancelled: { false })()
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(compacted.path(hits[0].entryID), "/note.txt")
    }

    func testUnresolvablePathsAreDropped() throws {
        let id = try index.upsert(file: .init(path: "/not/indexed.txt", size: 1, mtime: 1, kind: 3, parser: "text-1"))
        try index.replaceChunks(file: id, chunks: [.init(ordinal: 0, label: "", text: "开具发票")])
        let provider = ContentSearchProvider(index: index)
        let store = store(paths: ["/note.txt"]); store.buildHash()   // without this the test would pass for the wrong reason
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store)
        XCTAssertTrue(provider.prepareSearch(Query.parse("发票"), options: SearchOptions(), sources: [source], isCancelled: { false })().isEmpty)
    }

    func testDisabledProviderReturnsNothing() throws {
        let store = store(paths: ["/note.txt"]); store.buildHash()
        let id = try index.upsert(file: .init(path: "/note.txt", size: 1, mtime: 1, kind: 3, parser: "text-1"))
        try index.replaceChunks(file: id, chunks: [.init(ordinal: 0, label: "", text: "开具发票")])
        let provider = ContentSearchProvider(index: index); provider.isEnabled = false
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store)
        XCTAssertTrue(provider.prepareSearch(Query.parse("发票"), options: SearchOptions(), sources: [source], isCancelled: { false })().isEmpty)
    }

    func testDetailTextAndHighlightRangesStayInsideTheDetailString() throws {
        let store = store(paths: ["/note.txt"]); store.buildHash()
        let id = try index.upsert(file: .init(path: "/note.txt", size: 1, mtime: 1, kind: 3, parser: "text-1"))
        try index.replaceChunks(file: id, chunks: [.init(ordinal: 0, label: "", text: "本月开具发票的日期是三月五日")])
        let provider = ContentSearchProvider(index: index)
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store)
        let hit = try XCTUnwrap(provider.prepareSearch(Query.parse("发票"), options: SearchOptions(), sources: [source], isCancelled: { false })().first)
        let presentation = hit.presentation
        XCTAssertTrue(presentation.text.contains("发票"))
        for range in presentation.highlights {
            XCTAssertLessThanOrEqual(NSMaxRange(range), (presentation.text as NSString).length)
            XCTAssertEqual((presentation.text as NSString).substring(with: range), "发票")
        }
    }
}
```

**Step 2: 跑测试确认失败**

Run: `swift test --filter ContentSearchProviderTests`
Expected: 编译失败，`cannot find 'ContentSearchProvider' in scope`

**Step 3: 实现**

新建 `Sources/OilFindApp/ContentSearch/ContentSearchProvider.swift`：

```swift
import AppKit
import OilFindCore

/// Publishes content matches as supplementary hits on file rows.
final class ContentSearchProvider: SupplementarySearchProvider {
    private let index: ContentIndex?
    private let queue = DispatchQueue(label: "com.oiloil.find.content.search", qos: .userInitiated)
    var isEnabled = true

    /// Optional so a disabled manager can exist without opening a database.
    init(index: ContentIndex?) { self.index = index }

    /// The literals the user actually typed, ignoring filters such as `ext:` and `kind:`.
    /// Searching `raw` would ask the content index for the literal string "ext:pdf 发票".
    static func terms(from query: Query) -> String {
        query.clauses
            .flatMap { $0.alternatives }
            .compactMap { atom -> String? in
                guard !atom.negated else { return nil }
                switch atom.matcher {
                case .name(let needle, _), .fileName(let needle):
                    return String(decoding: needle, as: UTF8.self)
                default:
                    return nil
                }
            }
            .joined(separator: " ")
    }

    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource],
                       isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        guard isEnabled, !sources.isEmpty else { return { [] } }
        let text = Self.terms(from: query)
        guard !text.isEmpty else { return { [] } }
        let captured = sources
        return { [index] in
            guard let index else { return [] }
            guard let found = try? index.search(text, limit: 200, isCancelled: isCancelled), !found.isEmpty else { return [] }
            if isCancelled() { return [] }
            var hits: [SupplementaryHit] = []
            for source in captured {
                // Resolve under one read lock so the stamped version matches the resolution.
                let resolved = source.store.read { () -> (version: UInt64, rows: [(ContentHit, UInt32)]) in
                    // Until the hash is built nothing resolves, and a hit without an entry id
                    // would be dropped by the host anyway.
                    guard source.store.hashReady else { return (source.store.version, []) }
                    let rows = found.compactMap { hit -> (ContentHit, UInt32)? in
                        guard let id = source.store.resolve(path: hit.path), source.store.isLive(id) else { return nil }
                        return (hit, id)
                    }
                    return (source.store.version, rows)
                }
                for (hit, id) in resolved.rows {
                    hits.append(ContentSearchProvider.makeHit(hit: hit, source: source, entryID: id,
                                                              version: resolved.version))
                }
            }
            return hits
        }
    }

    private static func makeHit(hit: ContentHit, source: SearchSource, entryID: UInt32, version: UInt64) -> SupplementaryHit {
        let prefix = hit.label.isEmpty ? "" : hit.label + "："
        let detail = prefix + hit.snippet
        // `highlights` are offsets inside `hit.snippet`; shift them past the label prefix.
        let offset = (prefix as NSString).length
        let ranges = hit.highlights.map { NSRange(location: $0.location + offset, length: $0.length) }
        return SupplementaryHit(sourceID: source.id, entryID: entryID, detail: detail,
                                highlights: ranges, thumbnail: hit.kind == 4, sourceVersion: version)
    }

    func sourcesDidChange(_ sources: [SearchSource]) { }
    func userActivity(visible: Bool, typing: Bool) { }
}
```

实现时把 `isImage` 换成按 `files.kind` 判断（`ContentHit` 里带上 `kind`），别用扩展名猜。

**Step 4: 跑测试确认通过**

Run: `swift test --filter ContentSearchProviderTests`
Expected: PASS

**Step 5: 提交**

```sh
git add Sources/OilFindApp/ContentSearch/ContentSearchProvider.swift Tests/OilFindUITests/ContentSearchProviderTests.swift
git commit -m "feat(content): resolve hits to live entry ids and stamp store version"
```

---

## Task 10: supplementary 多路复用器

`supplementaryProvider` 是单槽位（`SearchViewController.swift:48`），当前被 Pro 扩展占用。加一层合并，不抢槽位。

**Files:**
- Create: `Sources/OilFindApp/ContentSearch/SupplementaryMultiplexer.swift`
- Test: `Tests/OilFindUITests/SupplementaryMultiplexerTests.swift`

**Step 1: 写失败测试**

```swift
import XCTest
import OilFindCore
@testable import OilFindApp

final class SupplementaryMultiplexerTests: XCTestCase {
    private final class Provider: SupplementarySearchProvider {
        var isEnabled = true
        var lastVisible: Bool?
        var lastBusy: Bool?
        var sourceCount = 0
        let label: String
        init(label: String) { self.label = label }
        func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
            let enabled = isEnabled, label = label
            return { enabled ? [.init(sourceID: "startup", entryID: 1, detail: label)] : [] }
        }
        func sourcesDidChange(_ sources: [SearchSource]) { sourceCount = sources.count }
        func userActivity(visible: Bool, typing: Bool) { lastVisible = visible }
        func backgroundIndexingChanged(_ busy: Bool) { lastBusy = busy }
    }

    func testMergesHitsFromEveryEnabledProvider() throws {
        let a = Provider(label: "A"), b = Provider(label: "B")
        let multiplexer = SupplementaryMultiplexer(providers: [a, b])
        let hits = multiplexer.prepareSearch(Query.parse("x"), options: SearchOptions(), sources: [], isCancelled: { false })()
        XCTAssertEqual(hits.map(\.detail).sorted(), ["A", "B"])
    }

    func testDisabledProviderContributesNothing() throws {
        let a = Provider(label: "A"), b = Provider(label: "B")
        b.isEnabled = false
        let multiplexer = SupplementaryMultiplexer(providers: [a, b])
        XCTAssertEqual(multiplexer.prepareSearch(Query.parse("x"), options: SearchOptions(), sources: [], isCancelled: { false })().map(\.detail), ["A"])
    }

    func testReportsDisabledOnlyWhenEveryProviderIsDisabled() throws {
        let a = Provider(label: "A"), b = Provider(label: "B")
        let multiplexer = SupplementaryMultiplexer(providers: [a, b])
        XCTAssertTrue(multiplexer.isEnabled)
        b.isEnabled = false
        XCTAssertTrue(multiplexer.isEnabled)
        a.isEnabled = false
        XCTAssertFalse(multiplexer.isEnabled)
    }

    func testLifecycleCallbacksReachEveryProvider() throws {
        let a = Provider(label: "A"), b = Provider(label: "B")
        let multiplexer = SupplementaryMultiplexer(providers: [a, b])
        multiplexer.userActivity(visible: true, typing: false)
        multiplexer.backgroundIndexingChanged(true)
        XCTAssertEqual(a.lastVisible, true); XCTAssertEqual(b.lastVisible, true)
        XCTAssertEqual(a.lastBusy, true); XCTAssertEqual(b.lastBusy, true)
    }
}
```

**Step 2: 跑测试确认失败**

Run: `swift test --filter SupplementaryMultiplexerTests`
Expected: 编译失败

**Step 3: 实现**

新建 `Sources/OilFindApp/ContentSearch/SupplementaryMultiplexer.swift`：

```swift
import OilFindCore

/// Fans one supplementary slot out to several providers. `supplementaryProvider` on
/// `SearchViewController` is a single slot, and the Pro extension already needs it.
final class SupplementaryMultiplexer: SupplementarySearchProvider {
    private let providers: [SupplementarySearchProvider]
    init(providers: [SupplementarySearchProvider]) { self.providers = providers }
    var isEnabled: Bool { providers.contains { $0.isEnabled } }

    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource],
                       isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        let work = providers.filter(\.isEnabled).map { $0.prepareSearch(query, options: options, sources: sources, isCancelled: isCancelled) }
        guard !work.isEmpty else { return { [] } }
        return { work.flatMap { $0() } }
    }
    func sourcesDidChange(_ sources: [SearchSource]) { providers.forEach { $0.sourcesDidChange(sources) } }
    func userActivity(visible: Bool, typing: Bool) { providers.forEach { $0.userActivity(visible: visible, typing: typing) } }
    func backgroundIndexingChanged(_ busy: Bool) { providers.forEach { $0.backgroundIndexingChanged(busy) } }
}
```

**Step 4: 跑测试确认通过**

Run: `swift test --filter SupplementaryMultiplexerTests`
Expected: PASS

**Step 5: 提交**

```sh
git add Sources/OilFindApp/ContentSearch/SupplementaryMultiplexer.swift Tests/OilFindUITests/SupplementaryMultiplexerTests.swift
git commit -m "feat(content): multiplex the single supplementary provider slot"
```

---

## Task 11: Manager、设置分区与接线

**Files:**
- Create: `Sources/OilFindApp/ContentSearch/ContentManager.swift`
- Create: `Sources/OilFindApp/ContentSearch/ContentSettings.swift`
- Modify: `Sources/OilFindApp/ContentSearch/ContentIndex.swift`（加 `clear()`）
- Modify: `Sources/OilFindApp/ContentSearch/ContentSearchProvider.swift`（索引改可选已在 Task 9 完成，此处只核对）
- Modify: `Sources/OilFindApp/AppDelegate.swift:20,59,134,200,276`
- Modify: `Sources/OilFindApp/SettingsWindow.swift:7,368-369`
- Modify: `Sources/OilFindApp/L10n.swift`
- Test: `Tests/OilFindUITests/ContentSettingsTests.swift`

**Step 1: 写失败测试**

```swift
import XCTest
@testable import OilFindApp

final class ContentSettingsTests: XCTestCase {
    func testManagerDefaultsToDisabledAndPersistsToggle() throws {
        let defaults = UserDefaults(suiteName: "content-" + UUID().uuidString)!
        let manager = ContentManager(defaults: defaults, indexURL: nil)
        XCTAssertFalse(manager.enabled)
        manager.setEnabled(true)
        XCTAssertTrue(ContentManager(defaults: defaults, indexURL: nil).enabled)
    }
    func testDisablingProviderImmediatelyStopsHits() throws {
        let defaults = UserDefaults(suiteName: "content-" + UUID().uuidString)!
        let manager = ContentManager(defaults: defaults, indexURL: nil)
        manager.setEnabled(true)
        XCTAssertTrue(manager.provider.isEnabled)
        manager.setEnabled(false)
        XCTAssertFalse(manager.provider.isEnabled)
    }
    func testLocalizedCopyExistsInBothLanguages() throws {
        for key in ["contentTitle", "contentEnabled", "contentPrivacy", "contentBuilding", "contentDone"] {
            XCTAssertNotEqual(L10n.text(key, chinese: true), key)
            XCTAssertNotEqual(L10n.text(key, chinese: false), key)
        }
    }
}
```

**Step 2: 跑测试确认失败**

Run: `swift test --filter ContentSettingsTests`
Expected: 编译失败

**Step 3: 实现**

先在 `ContentIndex.swift` 补一个清空方法。`chunks` 上的 `ON DELETE CASCADE` 加上 `chunk_postings_delete` 触发器，删 `files` 就会把块与 FTS 行一并带走，不需要单独删：

```swift
/// Drops every indexed file. Chunks and their postings go with them through the cascade
/// and the `chunk_postings_delete` trigger, so this is the only statement needed.
func clear() throws { try sql.run("DELETE FROM files") }
```

`ContentSearchProvider` 的索引改为可选，好让未启用的 manager 不必打开数据库（同时改 Task 9 的实现与它的 `guard`）：

```swift
    private let index: ContentIndex?
    init(index: ContentIndex?) { self.index = index }
    // inside prepareSearch's returned closure:
    guard let index else { return [] }
    guard let found = try? index.search(...), !found.isEmpty else { return [] }
```

新建 `Sources/OilFindApp/ContentSearch/ContentManager.swift`：

```swift
import Combine
import Foundation
import OilFindCore

/// Owns the content index, its background indexer and the search provider. Mirrors
/// `AITopicManager`'s shape so the settings window can observe one object.
final class ContentManager: ObservableObject {
    static let enabledKey = "contentSearchEnabled"

    @Published private(set) var enabled: Bool
    @Published private(set) var indexing = false
    @Published private(set) var count = 0
    @Published private(set) var diskBytes: Int64 = 0
    @Published private(set) var failed = 0

    let provider: ContentSearchProvider

    /// Supplies the host's file index. `AppDelegate` installs it before the first `start()`.
    /// Returns nil while the index is still loading, which makes `start()` a no-op.
    var storeProvider: (() -> IndexStore?)?

    private let defaults: UserDefaults
    private let indexURL: URL?
    private let store: ContentIndex?
    private let indexer: ContentIndexer?
    private let queue = DispatchQueue(label: "com.oiloil.find.content.index", qos: .utility)
    private let lock = NSLock()
    private var generation = 0
    private var cancelled = false

    /// `indexURL: nil` is fully inert: no database is opened and nothing is written to disk.
    /// Tests use it so they never touch the user's real Application Support folder.
    init(defaults: UserDefaults = .standard, indexURL: URL? = ContentIndex.defaultURL) {
        self.defaults = defaults
        self.indexURL = indexURL
        let store = indexURL.flatMap { try? ContentIndex(url: $0) }
        self.store = store
        self.indexer = store.map { ContentIndexer(index: $0, parsers: [TextParser(), ImageOCRParser()]) }
        let enabled = defaults.bool(forKey: Self.enabledKey)
        self.enabled = enabled
        self.provider = ContentSearchProvider(index: store)
        self.provider.isEnabled = enabled
        refresh()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        provider.isEnabled = value
        defaults.set(value, forKey: Self.enabledKey)
        if value { start() } else { stop() }
    }

    /// Called by `AppDelegate` when the host index changes. Content indexing is expensive, so
    /// bursts are coalesced: a run only starts when nothing is already in flight.
    func fileIndexChanged() { if !indexing { start() } }

    func start() {
        guard enabled, let indexer, storeProvider?() != nil else { return }
        // Bump the generation before the run so a concurrent `stop()` can invalidate it.
        lock.lock(); generation += 1; let mine = generation; cancelled = false; lock.unlock()
        indexing = true
        let provider = storeProvider
        queue.async { [weak self] in
            guard let self else { return }
            let isCancelled = { self.isCancelled(mine) }
            var hardFailure = false
            // The store can disappear between the guard above and this hop; finish the run
            // rather than returning early, or `indexing` would stay stuck on.
            if let store = provider?() {
                do { try indexer.synchronize(store: store, isCancelled: isCancelled) }
                catch { hardFailure = true }
            }
            let failed = indexer.failedCount + (hardFailure ? 1 : 0)
            let count = (try? self.store?.count()) ?? 0
            DispatchQueue.main.async {
                guard !self.isCancelled(mine) else { return }
                self.indexing = false
                self.failed = failed
                self.count = count
                self.diskBytes = Self.diskBytes(at: self.indexURL)
            }
        }
    }

    /// Invalidates the in-flight run. The worker checks `isCancelled` between files and stops.
    func stop() { lock.lock(); generation += 1; cancelled = true; lock.unlock() }

    func rebuild() { stop(); try? store?.clear(); refresh(); start() }
    func clear() { stop(); try? store?.clear(); refresh() }

    private func refresh() {
        count = (try? store?.count()) ?? 0
        diskBytes = Self.diskBytes(at: indexURL)
    }

    private func isCancelled(_ mine: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled || mine != generation
    }

    private static func diskBytes(at url: URL?) -> Int64 {
        guard let url else { return 0 }
        return [url.path, url.path + "-wal", url.path + "-shm"].reduce(0) { total, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}
```

`SettingsModel.swift`（`Sources/OilFindApp/SettingsWindow.swift:7`）加一个属性，让它能观察 manager，同时不影响现有 8 处构造点：

```swift
    let contentSearch: ContentManager
    // in init(...), after `self.topics = topics`:
    self.contentSearch = contentSearch ?? ContentManager(defaults: preferences, indexURL: nil)
```

`init` 头部加参数（放在 `topics:` 之后）：`contentSearch: ContentManager? = nil`。默认给一个不碰磁盘的 manager，所以 `snapshot: true` 的构造点与测试都不用改。

`L10n.swift` 键加进现有 `strings` 字典（中英对照）：

```swift
"contentTitle": ("文件内容", "File contents"),
"contentEnabled": ("搜索图片和文档里的文字", "Search text inside images and documents"),
"contentPrivacy": ("图片和文档都在本机处理，不会上传。", "Images and documents are processed on this Mac and never uploaded."),
"contentBuilding": ("正在建立内容索引…", "Building content index…"),
"contentDone": ("已索引 %@ 个文件", "Indexed %@ files"),
"contentRebuild": ("重建索引", "Rebuild index"),
"contentClear": ("清除索引", "Clear index"),
```

`ContentSettings.swift`：照 `AITopicSettings(manager:)` 的写法，`@ObservedObject var manager: ContentManager`。内容依次为总开关、`contentPrivacy` 说明文字、索引状态、磁盘占用、两个按钮。`enabled` 是 `private(set)`，不能直接绑，用显式 binding：

```swift
Toggle(L10n.text("contentEnabled"), isOn: Binding(
    get: { manager.enabled },
    set: { manager.setEnabled($0) }))
Text(manager.indexing ? L10n.text("contentBuilding")
                      : L10n.text("contentDone", "\(manager.count)"))
Button(L10n.text("contentRebuild")) { manager.rebuild() }
Button(L10n.text("contentClear")) { manager.clear() }
```

失败数在 `manager.failed > 0` 时附一行。中英文跟随父视图重绘（父视图观察 `model`），所以不需要额外传 `chinese:`。

`AppDelegate.swift` 接线（三处）：

1. 第 20 行附近加属性，与 `topics` 并列：`private let contentSearch = ContentManager()`
2. `startIndex(limited:)` 里，在 `self.manager = manager` 之后装来源并提供初值；第 59 行改为多路复用器：

```swift
        self.manager = manager; panel.searchController.manager = manager
        contentSearch.storeProvider = { [weak manager] in manager?.store }
        contentSearch.start()
        panel.searchController.supplementaryProvider = SupplementaryMultiplexer(
            providers: [contentSearch.provider] + [appExtension?.supplementarySearchProvider].compactMap { $0 })
```

3. 第 134 行 `onIndexChange` 追加内容索引的触发；第 200 行 `SettingsModel(...)` 传 `contentSearch: contentSearch`；`applicationWillTerminate` 里 `topics.stop()` 旁边加 `contentSearch.stop()`：

```swift
        manager.onIndexChange = { [weak self] in
            self?.panel.searchController.indexChanged()
            self?.contentSearch.fileIndexChanged()
        }
```

不要调用 `languageDidChange`：`ContentManager` 没有语言相关状态，文案在视图里读 `L10n`，语言切换由父视图重绘覆盖。

`SettingsWindow.swift:368-369` 之后插入：

```swift
Section(L10n.text("contentTitle")) { ContentSettings(manager: model.contentSearch) }
```

**Step 4: 跑测试确认通过**

Run: `swift test --filter ContentSettingsTests`
Expected: PASS

**Step 5: 全量验证**

```sh
swift build
swift test
OILFIND_FREE=1 swift build
OILFIND_FREE=1 swift test
python3 Tests/Scripts/test_open_core.py
```

Expected: 全部通过。注意 `OILFIND_FREE=1` 下内容搜索仍在（它是免费功能），只有 Pro 扩展被排除。

**Step 6: 界面快照验证**

```sh
scripts/build-app.sh --debug
"build/debug/Oil Find.app/Contents/MacOS/OilFind" --snapshot /tmp/content-settings.png --state settings --settings-scroll 0.3
"build/debug/Oil Find.app/Contents/MacOS/OilFind" --snapshot /tmp/content-hit.png --query 发票
```

Expected: 第一张能看到内容分区；第二张能看到命中行带 detail 和高亮。

注意 `--settings-scroll` 收的是 **0…1 的滚动比例**，不是分区名（`Snapshot.swift:130` 用 `Double(value)` 解析，传字符串会报 `Invalid settings scroll fraction`）。内容分区在 AI 话题之后，具体取多少要看实际布局，先用 `0.3`，看不全就调大。

**Step 7: 提交**

```sh
git add Sources/OilFindApp/ContentSearch/ContentManager.swift \
        Sources/OilFindApp/ContentSearch/ContentSettings.swift \
        Sources/OilFindApp/ContentSearch/ContentIndex.swift \
        Sources/OilFindApp/ContentSearch/ContentSearchProvider.swift \
        Sources/OilFindApp/AppDelegate.swift \
        Sources/OilFindApp/SettingsWindow.swift \
        Sources/OilFindApp/L10n.swift \
        Tests/OilFindUITests/ContentSettingsTests.swift
git commit -m "feat(content): add content search manager, settings and wiring"
```

不要用 `git add -A`：这个仓库不提交构建产物与本机索引，`Pro/` 也必须保持未跟踪。

---

## M1 完成标准

- [ ] `swift test` 与 `OILFIND_FREE=1 swift test` 全绿
- [ ] `python3 Tests/Scripts/test_open_core.py` 通过
- [ ] 截图里的中文能被搜到，命中行有 detail 和高亮
- [ ] 纯文本/Markdown 文件内容能被搜到
- [ ] 压实之后命中仍指向正确的文件（Task 9 的回归测试）
- [ ] 关掉开关立刻撤下命中
- [ ] 设置分区中英文都有文案，切换语言即时刷新

## 明确不在 M1 范围

PDF、docx、xlsx、pptx、RTF、图片画面识别、外置盘路径 rebase、`chunk_fts` 的 `optimize`/`VACUUM` 一次性门闩、内容索引的体积门限测试（M2 做）。
