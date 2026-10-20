import XCTest
@testable import OilFindCore

final class FullDiskAccessStateTests: XCTestCase {
    func testRepeatedReadingsKeepTheCurrentLimitedMode() {
        var limited = FullDiskAccessState(limited: true)
        XCTAssertFalse(limited.observe(granted: false))
        XCTAssertTrue(limited.limited)
        var full = FullDiskAccessState(limited: false)
        XCTAssertFalse(full.observe(granted: true))
        XCTAssertFalse(full.limited)
    }
    func testGrantingAccessLeavesLimitedModeOnce() {
        var state = FullDiskAccessState(limited: true)
        XCTAssertTrue(state.observe(granted: true))
        XCTAssertFalse(state.limited)
        XCTAssertFalse(state.observe(granted: true))
    }
    func testRevokingAccessReEntersLimitedMode() {
        var state = FullDiskAccessState(limited: false)
        XCTAssertTrue(state.observe(granted: false))
        XCTAssertTrue(state.limited)
    }
}
