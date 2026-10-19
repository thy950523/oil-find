import XCTest
import SQLite3
@testable import OilFindApp

final class ContentIndexWriteTests: XCTestCase {
    private var url: URL!
    private var index: ContentIndex!
    override func setUpWithError() throws {
        url = makeContentDatabaseURL()
        index = try ContentIndex(url: url)
    }
    override func tearDownWithError() throws { index = nil; removeContentDatabase(url) }

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
        // Without the postings delete this stays at 2 and leaks for the index's lifetime.
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
