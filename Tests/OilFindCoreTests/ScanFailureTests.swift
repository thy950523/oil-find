import XCTest
import Foundation
import Darwin
@testable import OilFindCore

/// What a scan says when it publishes nothing, and what the manager does about it. The two are tested
/// together because the failure is only useful if a caller can tell the two kinds apart: a scan root
/// that is missing is not repaired by trying again, while a process that ran out of descriptors is.
final class ScanFailureTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindScanFailure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base { try? FileManager.default.removeItem(at: base) }
        base = nil
    }

    private func eventually(_ seconds: Double = 8, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return predicate()
    }

    func testAScanThatPublishesACatalogReportsNoFailure() throws {
        try FileManager.default.createDirectory(at: base.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try Data([65]).write(to: base.appendingPathComponent("dir/leaf.txt"))
        let scanner = Scanner(config: IndexConfig(rootPath: base.path), threads: 2)
        XCTAssertNotNil(scanner.run())
        XCTAssertNil(scanner.failure)
    }

    func testAMissingRootIsReportedAsUnavailable() throws {
        let missing = base.appendingPathComponent("absent").path
        let scanner = Scanner(config: IndexConfig(rootPath: missing), threads: 2)
        XCTAssertNil(scanner.run())
        XCTAssertEqual(scanner.failure, .rootUnavailable)
    }

    /// A root that exists but is not a directory fails for the same reason as a missing one: there is
    /// nothing to walk, and no retry will change that.
    func testARootThatIsNotADirectoryIsReportedAsUnavailable() throws {
        let file = base.appendingPathComponent("leaf.txt")
        try Data([65]).write(to: file)
        let scanner = Scanner(config: IndexConfig(rootPath: file.path), threads: 2)
        XCTAssertNil(scanner.run())
        XCTAssertEqual(scanner.failure, .rootUnavailable)
    }

    /// The failure that made a rebuild look endless: the walk carried on past a directory it could not
    /// open, so the catalog it published was smaller than the disk and nothing in it said so.
    func testAWalkThatRunsOutOfDescriptorsPublishesNothing() throws {
        try skipIfCI("Lowering RLIMIT_NOFILE is process-wide and would disturb other tests.")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try Data([65]).write(to: base.appendingPathComponent("dir/leaf.txt"))
        // The walk holds one directory handle at a time, so a table with a few descriptors of room
        // opens the scan root and still has nothing left for the directory under it. The limit is
        // restored below, and the hard limit is what makes that certain.
        let original = try XCTUnwrap(DescriptorBudget.softLimit())
        let room = try XCTUnwrap(DescriptorBudget.openCount()) + 4
        try XCTSkipUnless(original > room, "the process's table is already smaller than the test needs")
        try Self.setSoftLimit(room)
        defer { try? Self.setSoftLimit(original) }
        let scanner = Scanner(config: IndexConfig(rootPath: base.path), threads: 1)
        var consumed: [Int32] = []
        var walkStarted = 0
        defer { for descriptor in consumed { close(descriptor) } }
        scanner.installDirectoryOpenHook { _ in
            // The scan root has already been opened and closed by the time the first hook runs, so the
            // descriptor the walk needs next — a directory handle — is the one that meets `EMFILE`.
            walkStarted += 1
            guard consumed.isEmpty else { return }
            while true {
                let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
                guard descriptor >= 0 else { return }
                consumed.append(descriptor)
            }
        }

        XCTAssertNil(scanner.run())
        // Without this the test would pass on a root that never opened, which is a different path.
        XCTAssertEqual(walkStarted, 1)
        XCTAssertEqual(scanner.failure, .descriptorsExhausted)
    }

    /// Both branches of the exhaustion classification, which is what tells a caller whether a retry
    /// can help at all. The file system is not involved: the code `open` leaves behind is the input.
    func testDescriptorExhaustionCoversBothKernelCodes() {
        XCTAssertEqual(Scanner.rootFailure(openCode: EMFILE), .descriptorsExhausted)
        XCTAssertEqual(Scanner.rootFailure(openCode: ENFILE), .descriptorsExhausted)
        XCTAssertEqual(Scanner.rootFailure(openCode: ENOENT), .rootUnavailable)
        XCTAssertEqual(Scanner.rootFailure(openCode: EPERM), .rootUnavailable)
        XCTAssertEqual(Scanner.rootFailure(openCode: ENOTDIR), .rootUnavailable)
    }

    private static func setSoftLimit(_ value: Int) throws {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { throw XCTSkip("RLIMIT_NOFILE cannot be read") }
        limit.rlim_cur = rlim_t(value)
        guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else { throw XCTSkip("RLIMIT_NOFILE cannot be lowered") }
    }

    func testACancelledScanIsNotReportedAsAFailure() throws {        let scanner = Scanner(config: IndexConfig(rootPath: base.path), threads: 2)
        scanner.cancel()
        XCTAssertNil(scanner.run())
        XCTAssertEqual(scanner.failure, .cancelled)
    }

    func testTheRetryDelayDoublesAndStopsGrowing() {
        let manager = IndexManager(config: IndexConfig(rootPath: base.path), dbURL: base.appendingPathComponent("index.oilfind"))
        manager.retryBaseDelay = 60
        manager.retryDelayLimit = 900
        XCTAssertEqual(manager.retryDelay(afterFailures: 1), 60)
        XCTAssertEqual(manager.retryDelay(afterFailures: 2), 120)
        XCTAssertEqual(manager.retryDelay(afterFailures: 3), 240)
        XCTAssertEqual(manager.retryDelay(afterFailures: 4), 480)
        // Capped rather than unbounded: a disk that stays unreadable must still be picked up again.
        XCTAssertEqual(manager.retryDelay(afterFailures: 5), 900)
        XCTAssertEqual(manager.retryDelay(afterFailures: 40), 900)
    }

    /// The failure that made the index appear never to finish: the first scan fails, nothing is
    /// published, and no later scan is ever attempted because the manager only knew how to rescan an
    /// index it already had.
    func testAFailedFirstScanIsRetried() throws {
        try skipIfCI("Retry scheduling is timing-sensitive in CI.")
        let manager = IndexManager(config: IndexConfig(rootPath: base.appendingPathComponent("absent").path),
                                   dbURL: base.appendingPathComponent("index.oilfind"))
        manager.retryBaseDelay = 0.05
        manager.retryDelayLimit = 0.2
        manager.start()
        defer { manager.stop() }
        XCTAssertTrue(eventually { manager.consecutiveScanFailuresForTesting >= 3 },
                      "expected repeated retries, saw \(manager.consecutiveScanFailuresForTesting)")
        // Nothing was published, so there is no catalog for a later scan to have replaced.
        XCTAssertNil(manager.store)
        XCTAssertEqual(manager.state, .idle)
    }

    /// The backoff is reset by a published catalog rather than by a scan merely starting, so a run of
    /// failures cannot leave a healthy index on a retry delay.
    func testAPublishedCatalogResetsTheBackoff() throws {
        try skipIfCI("Live scan scheduling is timing-sensitive in CI.")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try Data([65]).write(to: base.appendingPathComponent("dir/leaf.txt"))
        let missing = base.appendingPathComponent("absent")
        let manager = IndexManager(config: IndexConfig(rootPath: missing.path),
                                   dbURL: base.appendingPathComponent("index.oilfind"))
        manager.retryBaseDelay = 0.05
        manager.retryDelayLimit = 0.2
        manager.start()
        defer { manager.stop() }
        XCTAssertTrue(eventually { manager.consecutiveScanFailuresForTesting >= 2 })
        // The root appears, as a volume being mounted does, and the next retry finds it.
        try FileManager.default.moveItem(at: base.appendingPathComponent("dir"), to: missing)
        XCTAssertTrue(eventually(20) { manager.state == .ready })
        XCTAssertEqual(manager.consecutiveScanFailuresForTesting, 0)
        XCTAssertNotNil(manager.store)
    }
}
