import Combine
import Foundation
import XCTest
@testable import OilFindCore
@testable import OilFindApp

/// How the manager schedules sync passes in response to the file index. The database is a temp file
/// and the store is synthetic, so no test opens the real content index in Application Support.
final class ContentManagerTests: XCTestCase {
    private var databaseURL: URL!

    override func setUpWithError() throws {
        databaseURL = makeContentDatabaseURL()
    }

    override func tearDownWithError() throws {
        removeContentDatabase(databaseURL)
        databaseURL = nil
    }

    private func makeSuite() -> (name: String, defaults: UserDefaults) {
        let name = "oilfind-content-manager-" + UUID().uuidString
        return (name, UserDefaults(suiteName: name)!)
    }

    /// A store holding only its root directory: the pass has nothing to parse, so it finishes fast
    /// and the test measures scheduling rather than indexing.
    private func makeEmptyStore() -> IndexStore {
        var buffer = ScanBuffer()
        Array("".utf8).withUnsafeBufferPointer {
            buffer.append(id: 0, parent: 0, size: 0, mtime: 0, flags: SiftFlag.dir, depth: 0, kind: 1, name: $0)
        }
        let store = IndexStore(scan: ScanOutput(buffers: [buffer], count: 1, homeIndex: .max,
                                                elapsed: 0, finishedAt: 0),
                               config: IndexConfig(rootPath: "/generated"))
        store.write { store.buildHash() }
        return store
    }

    /// A file-index change that lands while a pass is in flight must not be dropped. The pass
    /// snapshotted the file index when it began, so it cannot see the change, and dropping it would
    /// leave the announced file unsearchable until some unrelated later change happened to arrive.
    ///
    /// `storeProvider` is called exactly twice per pass — once by the guard in `start()`, once on the
    /// worker queue — so its call count is a deterministic proxy for how many passes ran.
    func testChangeDuringPassRunsExactlyOneFollowUp() throws {
        let (suite, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = ContentManager(defaults: defaults, indexURL: databaseURL)
        let store = makeEmptyStore()
        var calls = 0
        let firstPassStarted = expectation(description: "the first pass began")
        manager.storeProvider = {
            calls += 1
            if calls == 2 { firstPassStarted.fulfill() }
            return store
        }

        manager.setEnabled(true)
        // `setEnabled` starts the pass synchronously, so `indexing` is already true here, and the
        // pass completion is queued to the main thread — which cannot run until this test method
        // returns to the run loop. Calling this now therefore lands mid-pass for certain, with no
        // race to lose.
        manager.fileIndexChanged()

        // Pass 1's two calls, then the follow-up's two. Without the pending flag the change is
        // dropped, the follow-up never starts and this settles at 2.
        wait(for: [firstPassStarted], timeout: 5)
        let settled = expectation(description: "any chained pass would have started by now")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(calls, 4, "expected the first pass plus exactly one follow-up, no more")
        XCTAssertFalse(manager.indexing)
    }

    /// The settings pane reads `progress` to show how far along a pass is. Every phase change must
    /// reach it — including the switch from scanning to parsing, which is the only signal that the
    /// pass has moved on to the expensive part — and the value must be cleared once the pass ends so
    /// the pane cannot keep advancing a bar for work that is over.
    func testProgressIsPublishedDuringAPassAndClearedWhenItEnds() throws {
        let (suite, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = ContentManager(defaults: defaults, indexURL: databaseURL)
        let store = makeEmptyStore()
        manager.storeProvider = { store }

        var seen: [ContentIndexProgress] = []
        let published = manager.$progress.sink { if let value = $0 { seen.append(value) } }
        defer { published.cancel() }

        let finished = expectation(description: "the pass ended")
        let indexing = manager.$indexing.dropFirst().sink { value in if !value { finished.fulfill() } }
        defer { indexing.cancel() }

        manager.setEnabled(true)
        wait(for: [finished], timeout: 5)

        // The synthetic store holds only its root, so scanning totals one row and parsing totals no
        // candidates. Both phases still have to arrive: the pane shows the phase, not just a number.
        XCTAssertTrue(seen.contains { $0.phase == .scanning && $0.total == 1 },
                      "the pane never learned that scanning had started")
        XCTAssertTrue(seen.contains { $0.phase == .parsing },
                      "the pane never learned that parsing had started")
        XCTAssertNil(manager.progress, "progress outlived the pass")
    }
}
