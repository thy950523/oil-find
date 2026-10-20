import XCTest
import Foundation
import Darwin
@testable import OilFindCore

final class DescriptorBudgetTests: XCTestCase {
    func testOpenCountCountsEveryDescriptorTheProcessHolds() throws {
        let before = try XCTUnwrap(DescriptorBudget.openCount())
        // `/dev/null` rather than a temporary file: the count must move by exactly the number opened,
        // and a descriptor opened and closed inside one expression would not.
        var descriptors: [Int32] = []
        defer { for descriptor in descriptors { close(descriptor) } }
        for _ in 0..<8 {
            let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            descriptors.append(descriptor)
        }
        XCTAssertEqual(try XCTUnwrap(DescriptorBudget.openCount()), before + 8)
    }

    func testSoftLimitMatchesTheKernelReading() throws {
        var limit = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &limit), 0)
        XCTAssertEqual(DescriptorBudget.softLimit(), Int(limit.rlim_cur))
    }

    func testTightnessComparesAgainstTheFractionOfTheLimit() {
        XCTAssertTrue(DescriptorBudget.isTight(open: 1280, limit: 2560, fraction: 0.5))
        XCTAssertTrue(DescriptorBudget.isTight(open: 2559, limit: 2560, fraction: 0.5))
        XCTAssertFalse(DescriptorBudget.isTight(open: 1279, limit: 2560, fraction: 0.5))
        XCTAssertFalse(DescriptorBudget.isTight(open: 20, limit: 2560, fraction: 0.5))
    }

    /// A process with room to spare must not report itself tight: stopping a pass early is a cost of
    /// its own, so the reading has to be false in the ordinary case. The limit is deliberately not
    /// lowered to test the other branch — a test that changes `RLIMIT_NOFILE` breaks every test that
    /// runs after it in the same process, and the threshold itself is covered above.
    func testAPassWithHeadroomIsNotTight() {
        XCTAssertFalse(DescriptorBudget.isTight())
    }
}
