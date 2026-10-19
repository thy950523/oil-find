import Foundation
import XCTest
@testable import OilFindCore
@testable import OilFindApp

final class ContentSearchProviderTests: XCTestCase {
    private var databaseURL: URL!
    private var index: ContentIndex!

    override func setUpWithError() throws {
        databaseURL = makeContentDatabaseURL()
        index = try ContentIndex(url: databaseURL)
    }

    override func tearDownWithError() throws {
        index = nil
        removeContentDatabase(databaseURL)
        databaseURL = nil
    }

    /// Index 0 must be a live root directory: `resolve(path:)` walks down from it, and a missing
    /// root would make every test pass for the wrong reason.
    private func makeStore(_ names: [String]) -> IndexStore {
        var buffer = ScanBuffer()
        Array("".utf8).withUnsafeBufferPointer {
            buffer.append(id: 0, parent: 0, size: 0, mtime: 0, flags: SiftFlag.dir, depth: 0, kind: 1, name: $0)
        }
        for (offset, name) in names.enumerated() {
            Array(name.utf8).withUnsafeBufferPointer {
                buffer.append(id: UInt32(offset + 1), parent: 0, size: 10, mtime: 1, flags: 0,
                              depth: 1, kind: 3, name: $0)
            }
        }
        let store = IndexStore(scan: ScanOutput(buffers: [buffer], count: names.count + 1, homeIndex: .max,
                                                elapsed: 0, finishedAt: 0),
                               config: IndexConfig(rootPath: "/"))
        store.write { store.buildHash() }
        return store
    }

    private func addContent(_ path: String, kind: UInt8 = 3, label: String = "第 1 行附近",
                            text: String = "这是一张发票，请查收") throws {
        var plan = ContentIndex.SyncPlan()
        plan.added = [ContentFileRecord(path: path, size: 1, mtime: 1, kind: kind, parser: "stub")]
        try index.apply(plan) { _ in [ContentChunk(ordinal: 0, label: label, text: text)] }
    }

    private func source(_ store: IndexStore) -> SearchSource {
        SearchSource(id: "startup", displayName: "", isOnline: true, store: store)
    }

    private func search(_ provider: ContentSearchProvider, _ store: IndexStore,
                        _ text: String = "发票") -> [SupplementaryHit] {
        provider.prepareSearch(Query.parse(text), options: SearchOptions(), sources: [source(store)],
                               isCancelled: { false })()
    }

    func testResolvesPathToTheCurrentEntryID() throws {
        let store = makeStore(["note.txt"])
        try addContent("/note.txt")
        let provider = ContentSearchProvider(index: index)

        let hits = search(provider, store)

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(store.path(try XCTUnwrap(hits.first).entryID), "/note.txt")
        XCTAssertEqual(hits.first?.sourceVersion, store.version)
    }

    func testTermsIgnoreFilters() throws {
        // `terms(from:)` must return the literals the user typed, not the raw query: searching the
        // content index for "ext:pdf 发票" would match nothing.
        let terms = ContentSearchProvider.terms(from: Query.parse("ext:pdf 发票"))

        XCTAssertEqual(terms, "发票")
        XCTAssertNotEqual(terms, "ext:pdf 发票")
    }

    func testHitStillPointsAtTheSameFileAfterCompaction() throws {
        let store = makeStore(["a.txt", "b.txt", "note.txt"])
        try addContent("/note.txt")
        let provider = ContentSearchProvider(index: index)

        // Before compaction the target sits at entry 3. A provider that cached that id (or returned a
        // constant one) would land on a different file, or off the end, once the entry in front is
        // tombstoned and the ids renumber.
        let before = try XCTUnwrap(search(provider, store).first)
        XCTAssertEqual(before.entryID, 3)
        XCTAssertEqual(store.path(before.entryID), "/note.txt")

        store.write { _ = store.remove(1) }
        let compacted = store.write { store.compacted() }
        let hits = search(provider, compacted)

        let hit = try XCTUnwrap(hits.first)
        XCTAssertNotEqual(hit.entryID, before.entryID)
        XCTAssertEqual(compacted.path(hit.entryID), "/note.txt")
        XCTAssertTrue(compacted.isLive(hit.entryID))
    }

    func testUnresolvablePathsAreDropped() throws {
        let store = makeStore(["note.txt"])
        try addContent("/missing.txt")
        let provider = ContentSearchProvider(index: index)

        XCTAssertTrue(search(provider, store).isEmpty)
    }

    func testDisabledProviderReturnsNothing() throws {
        let store = makeStore(["note.txt"])
        try addContent("/note.txt")
        let provider = ContentSearchProvider(index: index)
        provider.isEnabled = false

        XCTAssertTrue(search(provider, store).isEmpty)
    }

    func testDetailTextAndHighlightRangesStayInsideTheDetailString() throws {
        let store = makeStore(["note.txt"])
        try addContent("/note.txt", text: "这是一张发票，请查收。")
        let provider = ContentSearchProvider(index: index)

        let hit = try XCTUnwrap(search(provider, store).first)
        let detail = hit.detail
        let length = (detail as NSString).length
        XCTAssertTrue(detail.contains("发票"))
        XCTAssertFalse(hit.highlights.isEmpty)
        for range in hit.highlights {
            XCTAssertLessThanOrEqual(NSMaxRange(range), length)
            XCTAssertEqual((detail as NSString).substring(with: range), "发票")
        }
    }
}
