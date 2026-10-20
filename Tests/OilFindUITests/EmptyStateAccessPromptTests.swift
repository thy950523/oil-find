import AppKit
import XCTest
@testable import OilFindCore
@testable import OilFindApp

final class EmptyStateAccessPromptTests: XCTestCase {
    private func source(noAccess: Bool) -> SearchSource {
        var stats = CoverageStats()
        if noAccess { Array("/Users/demo/Library/Mail".utf8).withUnsafeBufferPointer { stats.record(.noAccess, path: $0) } }
        let config = IndexConfig(rootPath: "/")
        let store = IndexStore(scan: ScanOutput(buffers: [], count: 1, homeIndex: .max, elapsed: 0, finishedAt: 0, coverage: stats), config: config)
        return SearchSource(id: "local", displayName: "Local", isOnline: true, store: store)
    }
    func testAccessPromptOnlyAppearsWhileFullDiskAccessIsMissing() {
        let inaccessible = [source(noAccess: true)], accessible = [source(noAccess: false)]
        XCTAssertTrue(SearchViewController.showsAccessPrompt(override: false, granted: false, sources: inaccessible))
        XCTAssertFalse(SearchViewController.showsAccessPrompt(override: false, granted: true, sources: inaccessible))
        XCTAssertFalse(SearchViewController.showsAccessPrompt(override: false, granted: false, sources: accessible))
        XCTAssertTrue(SearchViewController.showsAccessPrompt(override: true, granted: true, sources: accessible))
    }
    func testPanelWillShowNotifiesTheOwner() {
        _ = NSApplication.shared
        let controller = SearchViewController(snapshot: true)
        _ = controller.view
        var calls = 0
        controller.onWillShow = { calls += 1 }
        controller.panelWillShow()
        XCTAssertEqual(calls, 1)
    }
}
