import Foundation
import XCTest
@testable import OilFindCore
@testable import OilFindApp

final class ContentIndexerTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!
    private var index: ContentIndex!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("M22-indexer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = makeContentDatabaseURL()
        index = try ContentIndex(url: databaseURL)
    }

    override func tearDownWithError() throws {
        index = nil
        removeContentDatabase(databaseURL)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        databaseURL = nil
    }

    /// A parser that never touches the file system, so tests can build a store from a synthetic
    /// scan buffer instead of creating every file. `throwingPaths` simulates a damaged file;
    /// `cancellingPaths` simulates the cancellation path, which must not be counted as a failure.
    private struct StubParser: ContentParser {
        var identifier = "stub"
        var kinds: Set<UInt8> = [3, 4]
        var extensions: Set<String> = ["*"]
        var text = "发票 收据"
        var throwingPaths: Set<String> = []
        var cancellingPaths: Set<String> = []

        func parse(url: URL, budget: AITopicWorkBudget, isCancelled: () -> Bool) throws -> [ContentChunk] {
            if cancellingPaths.contains(url.path) { throw ContentParserError.cancelled }
            if throwingPaths.contains(url.path) { throw ContentParserError.damaged }
            return [ContentChunk(ordinal: 0, label: "stub", text: text)]
        }
    }

    private struct Entry {
        let name: String
        let kind: UInt8
        var flags: UInt8 = 0
        /// Sub-second part of the entry's mtime. Two entries that differ only here stand for two
        /// edits inside one second that left the size alone.
        var mtimeNsec: UInt32 = 0
    }

    /// Index 0 is the root directory, as the real scanner produces, and every entry is its direct
    /// child. The hash table must be built because a loaded store resolves paths through it.
    private func makeStore(_ entries: [Entry]) -> IndexStore {
        var buffer = ScanBuffer()
        Array("".utf8).withUnsafeBufferPointer {
            buffer.append(id: 0, parent: 0, size: 0, mtime: 0, flags: SiftFlag.dir, depth: 0, kind: 1, name: $0)
        }
        for (offset, entry) in entries.enumerated() {
            Array(entry.name.utf8).withUnsafeBufferPointer {
                buffer.append(id: UInt32(offset + 1), parent: 0, size: UInt32(offset + 1),
                              mtime: UInt32(offset + 1), mtimeNsec: entry.mtimeNsec,
                              flags: entry.flags, depth: 1, kind: entry.kind, name: $0)
            }
        }
        let store = IndexStore(scan: ScanOutput(buffers: [buffer], count: entries.count + 1, homeIndex: .max,
                                                elapsed: 0, finishedAt: 0),
                               config: IndexConfig(rootPath: directory.path))
        store.write { store.buildHash() }
        return store
    }

    func testIndexesOnlyDocumentAndImageEntries() throws {
        let store = makeStore([Entry(name: "note.txt", kind: 3),
                               Entry(name: "folder.txt", kind: 3, flags: SiftFlag.dir),
                               Entry(name: "photo.png", kind: 4),
                               Entry(name: "app.bin", kind: 1)])
        let indexer = ContentIndexer(index: index, parsers: [StubParser(kinds: [3])])

        try indexer.synchronize(store: store, isCancelled: { false })

        XCTAssertEqual(try index.count(), 1)
        XCTAssertEqual(try index.search("发票", limit: 10, isCancelled: { false }).first?.path,
                       directory.appendingPathComponent("note.txt").path)
    }

    func testSecondRunIsANoOp() throws {
        let store = makeStore([Entry(name: "note.txt", kind: 3)])
        let indexer = ContentIndexer(index: index, parsers: [StubParser()])
        let path = directory.appendingPathComponent("note.txt").path

        try indexer.synchronize(store: store, isCancelled: { false })
        let revision = try XCTUnwrap(index.file(path: path)).revision
        try indexer.synchronize(store: store, isCancelled: { false })

        XCTAssertEqual(try XCTUnwrap(index.file(path: path)).revision, revision)
    }

    /// A second edit inside the same second that leaves the size alone must still be re-parsed. The
    /// file index's sub-second stamp has to reach the content index's identity, or the edit is
    /// invisible and the first edit's text stays searchable.
    func testReparsesASameSecondSameSizeEdit() throws {
        let indexer = ContentIndexer(index: index, parsers: [StubParser()])
        let path = directory.appendingPathComponent("note.txt").path

        try indexer.synchronize(store: makeStore([Entry(name: "note.txt", kind: 3)]), isCancelled: { false })
        XCTAssertEqual(try XCTUnwrap(index.file(path: path)).revision, 1)

        // Same name, same size, same second: only the sub-second part of the mtime moved.
        try indexer.synchronize(store: makeStore([Entry(name: "note.txt", kind: 3, mtimeNsec: 500)]),
                                isCancelled: { false })

        XCTAssertEqual(try XCTUnwrap(index.file(path: path)).revision, 2)
    }

    func testRemovedFileIsDroppedFromTheIndex() throws {
        let indexer = ContentIndexer(index: index, parsers: [StubParser()])
        try indexer.synchronize(store: makeStore([Entry(name: "note.txt", kind: 3)]), isCancelled: { false })
        XCTAssertEqual(try index.count(), 1)

        try indexer.synchronize(store: makeStore([]), isCancelled: { false })

        XCTAssertEqual(try index.count(), 0)
    }

    func testImageEntriesUseTheImageParser() throws {
        let store = makeStore([Entry(name: "photo.png", kind: 4)])
        let indexer = ContentIndexer(index: index, parsers: [StubParser(identifier: "stub-ocr", kinds: [4])])

        try indexer.synchronize(store: store, isCancelled: { false })

        let record = try XCTUnwrap(index.file(path: directory.appendingPathComponent("photo.png").path))
        XCTAssertEqual(record.record.parser, "stub-ocr")
        XCTAssertEqual(try index.count(), 1)
    }

    func testDamagedFileIsSkippedAndCounted() throws {
        let damaged = directory.appendingPathComponent("broken.txt").path
        let store = makeStore([Entry(name: "broken.txt", kind: 3),
                               Entry(name: "note.txt", kind: 3)])
        let indexer = ContentIndexer(index: index, parsers: [StubParser(throwingPaths: [damaged])])

        try indexer.synchronize(store: store, isCancelled: { false })

        XCTAssertEqual(indexer.failedCount, 1)
        XCTAssertEqual(try index.count(), 1)
        XCTAssertNil(try index.file(path: damaged))
    }

    func testBatchingCoversEveryEntry() throws {
        // Four entries plus the synthetic root make five store rows, which is not a multiple of
        // `batchSize`, so the loop's final partial batch is exercised. Five entries would make six
        // rows, an exact multiple, and a loop that dropped the last batch would still pass.
        let entries = (0..<4).map { Entry(name: "note\($0).txt", kind: 3) }
        let indexer = ContentIndexer(index: index, parsers: [StubParser()], batchSize: 2)

        try indexer.synchronize(store: makeStore(entries), isCancelled: { false })

        XCTAssertEqual(try index.count(), 4)
    }

    func testCancelledEnumerationDeletesNothing() throws {
        let indexer = ContentIndexer(index: index, parsers: [StubParser()], batchSize: 2)
        let keepPath = directory.appendingPathComponent("keep.txt").path
        try indexer.synchronize(store: makeStore([Entry(name: "a.txt", kind: 3),
                                                  Entry(name: "keep.txt", kind: 3)]),
                                isCancelled: { false })
        XCTAssertEqual(try index.count(), 2)

        // Cancel after the first batch. The candidate set then holds only a.txt, so `keep.txt` is
        // absent from an enumeration that is incomplete: a plan built as if it were complete would
        // delete it. Nothing may be deleted, and cancellation is not a parse failure.
        var calls = 0
        let cancelled = { () -> Bool in calls += 1; return calls > 1 }
        try indexer.synchronize(store: makeStore([Entry(name: "a.txt", kind: 3),
                                                  Entry(name: "b.txt", kind: 3),
                                                  Entry(name: "c.txt", kind: 3)]),
                                isCancelled: cancelled)

        XCTAssertEqual(try index.count(), 2)
        XCTAssertNotNil(try index.file(path: keepPath))
        XCTAssertEqual(indexer.failedCount, 0)
    }

    func testParserCancellationIsNotCountedAsAFailure() throws {
        // The dedicated `catch ContentParserError.cancelled` returns nil before the generic catch,
        // so a cancelled parse leaves the file to be retried without raising `failedCount`.
        let path = directory.appendingPathComponent("note.txt").path
        let indexer = ContentIndexer(index: index, parsers: [StubParser(cancellingPaths: [path])])

        try indexer.synchronize(store: makeStore([Entry(name: "note.txt", kind: 3)]),
                                isCancelled: { false })

        XCTAssertEqual(indexer.failedCount, 0)
        XCTAssertNil(try index.file(path: path))
        XCTAssertEqual(try index.count(), 0)
    }
}
