import XCTest
import SQLite3
@testable import OilFindApp

/// Incremental sync: the diff between a candidate snapshot of the file index and the rows the
/// content index already holds, plus how that diff is applied.
final class ContentIndexSyncTests: XCTestCase {
    private var url: URL!
    private var index: ContentIndex!
    override func setUpWithError() throws {
        url = makeContentDatabaseURL()
        index = try ContentIndex(url: url)
    }
    override func tearDownWithError() throws { index = nil; removeContentDatabase(url) }

    /// Indexes one file with a single chunk so the stored metadata is non-trivial.
    private func seed(_ path: String, size: Int64, mtime: Int64, mtimeNsec: Int64 = 0) throws {
        try index.store(file: .init(path: path, size: size, mtime: mtime, mtimeNsec: mtimeNsec,
                                    kind: 3, parser: "text"),
                        chunks: [.init(ordinal: 0, label: "第 1 行附近", text: "开具发票的日期")])
    }

    /// Local copy of `ContentIndexWriteTests.ftsRowCount`, which is private to that file. Reads the
    /// postings table through the index's own connection so a leaked posting is observable.
    private func ftsRowCount() throws -> Int {
        let statement = try index.statement("SELECT COUNT(*) FROM chunk_fts")
        defer { sqlite3_reset(statement.handle) }
        guard try statement.next() else { return 0 }
        return Int(statement.int(0))
    }

    func testDetectsNewChangedAndRemovedFiles() throws {
        try seed("/a/1.txt", size: 10, mtime: 100)
        try seed("/a/2.txt", size: 10, mtime: 100)
        let plan = try index.plan(candidates: [
            .init(path: "/a/1.txt", size: 10, mtime: 100, kind: 3, parser: "text"),
            .init(path: "/a/2.txt", size: 20, mtime: 200, kind: 3, parser: "text"),
            .init(path: "/a/3.txt", size: 5, mtime: 50, kind: 3, parser: "text"),
        ])
        XCTAssertEqual(plan.unchanged.map(\.path), ["/a/1.txt"])
        XCTAssertEqual(plan.changed.map(\.path), ["/a/2.txt"])
        XCTAssertEqual(plan.added.map(\.path), ["/a/3.txt"])
        XCTAssertEqual(plan.removed, [])
    }

    func testIncompleteEnumerationNeverDeletes() throws {
        try seed("/a/1.txt", size: 10, mtime: 100)
        let plan = try index.plan(candidates: [], complete: false)
        XCTAssertEqual(plan.removed, [])
        XCTAssertEqual(try index.count(), 1)
    }

    func testApplyLeavesAFailedFileAlone() throws {
        try seed("/a/1.txt", size: 10, mtime: 1)
        let record = ContentFileRecord(path: "/a/1.txt", size: 20, mtime: 2, kind: 3, parser: "text")
        let plan = try index.plan(candidates: [record])
        XCTAssertEqual(plan.changed.map(\.path), ["/a/1.txt"])
        try index.apply(plan, parse: { _ in nil })
        let stored = try XCTUnwrap(try index.file(path: "/a/1.txt"))
        XCTAssertEqual(try index.chunkCount(file: stored.id), 1)
        // The old metadata must survive, or the next run classifies the file as unchanged and
        // never retries the parse that just failed.
        XCTAssertEqual(stored.record.mtime, 1)
        XCTAssertEqual(stored.record.size, 10)
    }

    func testApplyStoresEmptyResultsAndClearsOldChunks() throws {
        try seed("/a/1.txt", size: 10, mtime: 1)
        let record = ContentFileRecord(path: "/a/1.txt", size: 2, mtime: 2, kind: 3, parser: "text")
        try index.apply(try index.plan(candidates: [record]), parse: { _ in [] })
        let stored = try XCTUnwrap(try index.file(path: "/a/1.txt"))
        // An empty array means the file parsed and has no text, so the old chunks go.
        XCTAssertEqual(try index.chunkCount(file: stored.id), 0)
        XCTAssertEqual(stored.record.size, 2)
        // The chunk delete trigger must drop the postings too; a leaked posting would keep matching
        // searches against text the file no longer contains.
        XCTAssertEqual(try ftsRowCount(), 0)
    }

    func testRemovesPathsMissingFromACompleteSnapshot() throws {
        try seed("/a/1.txt", size: 10, mtime: 100)
        try seed("/a/2.txt", size: 10, mtime: 100)
        let plan = try index.plan(candidates: [
            .init(path: "/a/1.txt", size: 10, mtime: 100, kind: 3, parser: "text"),
        ])
        XCTAssertEqual(plan.removed, ["/a/2.txt"])
        try index.apply(plan, parse: { _ in [] })
        XCTAssertNil(try index.file(path: "/a/2.txt"))
        XCTAssertEqual(try index.count(), 1)
    }

    func testApplyStoresAnAddedRecord() throws {
        let record = ContentFileRecord(path: "/a/1.txt", size: 10, mtime: 100, kind: 3, parser: "text")
        let plan = try index.plan(candidates: [record])
        XCTAssertEqual(plan.added.map(\.path), ["/a/1.txt"])
        try index.apply(plan, parse: { _ in
            [.init(ordinal: 0, label: "第 1 行附近", text: "开具发票的日期")]
        })
        let stored = try XCTUnwrap(try index.file(path: "/a/1.txt"))
        XCTAssertEqual(stored.record.size, 10)
        XCTAssertEqual(try index.chunkCount(file: stored.id), 1)
        XCTAssertEqual(try ftsRowCount(), 1)
    }

    /// `size` alone is not the identity: the stored mtime must be compared too, or a same-size edit
    /// would be classified `unchanged` and never re-parsed.
    func testClassifierTreatsAnMtimeOnlyChangeAsChanged() throws {
        try seed("/a/1.txt", size: 10, mtime: 100)
        let plan = try index.plan(candidates: [
            .init(path: "/a/1.txt", size: 10, mtime: 200, kind: 3, parser: "text"),
        ])
        XCTAssertEqual(plan.changed.map(\.path), ["/a/1.txt"])
    }

    /// A parser change with identical size and mtime must also force a re-parse: a better parser
    /// arriving must not be skipped because the file itself did not move.
    func testClassifierTreatsAParserOnlyChangeAsChanged() throws {
        try seed("/a/1.txt", size: 10, mtime: 100)
        let plan = try index.plan(candidates: [
            .init(path: "/a/1.txt", size: 10, mtime: 100, kind: 3, parser: "ocr"),
        ])
        XCTAssertEqual(plan.changed.map(\.path), ["/a/1.txt"])
    }

    /// Two edits inside one second that leave the size alone are indistinguishable at second
    /// resolution, so the sub-second part of the modification time is part of the identity too.
    /// Without it the second edit is classified `unchanged` and the old text stays searchable.
    func testClassifierTreatsANanosecondOnlyChangeAsChanged() throws {
        try seed("/a/1.txt", size: 10, mtime: 100, mtimeNsec: 100_000_000)
        let plan = try index.plan(candidates: [
            .init(path: "/a/1.txt", size: 10, mtime: 100, mtimeNsec: 900_000_000, kind: 3, parser: "text"),
        ])
        XCTAssertEqual(plan.changed.map(\.path), ["/a/1.txt"])
    }

    /// The complement of the test above: an identical sub-second part must still classify as
    /// `unchanged`, or every sync would re-parse the whole index.
    func testClassifierTreatsAnIdenticalNanosecondAsUnchanged() throws {
        try seed("/a/1.txt", size: 10, mtime: 100, mtimeNsec: 250_000_000)
        let plan = try index.plan(candidates: [
            .init(path: "/a/1.txt", size: 10, mtime: 100, mtimeNsec: 250_000_000, kind: 3, parser: "text"),
        ])
        XCTAssertEqual(plan.unchanged.map(\.path), ["/a/1.txt"])
    }

    /// A chunk size that does not divide the record count leaves a final partial batch; the loop
    /// must still write it. Assert the paths, not just the count: a loop that wrote the wrong
    /// records would keep the count right.
    func testApplyWritesEveryRecordAcrossAChunkRemainder() throws {
        index.applyChunkSize = 2
        let paths = (1...5).map { "/a/\($0).txt" }
        let plan = try index.plan(candidates: paths.map {
            ContentFileRecord(path: $0, size: 10, mtime: 100, kind: 3, parser: "text")
        })
        XCTAssertEqual(plan.added.count, 5)
        try index.apply(plan, parse: { _ in
            [.init(ordinal: 0, label: "第 1 行附近", text: "开具发票的日期")]
        })
        XCTAssertEqual(try index.count(), 5)
        for path in paths { XCTAssertNotNil(try index.file(path: path), path) }
    }

    /// An exact multiple of the chunk size must not leave an empty trailing batch that skips the
    /// last records, nor one that re-writes already-written ones.
    func testApplyWritesEveryRecordWhenTheChunkSizeDividesExactly() throws {
        index.applyChunkSize = 2
        let paths = (1...4).map { "/a/\($0).txt" }
        let plan = try index.plan(candidates: paths.map {
            ContentFileRecord(path: $0, size: 10, mtime: 100, kind: 3, parser: "text")
        })
        XCTAssertEqual(plan.added.count, 4)
        try index.apply(plan, parse: { _ in
            [.init(ordinal: 0, label: "第 1 行附近", text: "开具发票的日期")]
        })
        XCTAssertEqual(try index.count(), 4)
        for path in paths { XCTAssertNotNil(try index.file(path: path), path) }
    }
}
