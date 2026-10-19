import Foundation
import XCTest
@testable import OilFindCore
@testable import OilFindApp

final class SupplementaryMultiplexerTests: XCTestCase {
    private final class Provider: SupplementarySearchProvider {
        var isEnabled = true
        let detail: String
        private(set) var visibility: [Bool] = []
        private(set) var busy: [Bool] = []
        private(set) var sourceUpdates = 0

        init(detail: String) { self.detail = detail }

        func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource],
                           isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
            let detail = detail
            return { [SupplementaryHit(sourceID: "test", entryID: 0, detail: detail)] }
        }

        func sourcesDidChange(_ sources: [SearchSource]) { sourceUpdates += 1 }
        func userActivity(visible: Bool, typing: Bool) { visibility.append(visible) }
        func backgroundIndexingChanged(_ busy: Bool) { self.busy.append(busy) }
    }

    private func hits(_ multiplexer: SupplementaryMultiplexer) -> [String] {
        multiplexer.prepareSearch(Query.parse("text"), options: SearchOptions(), sources: [],
                                  isCancelled: { false })().map(\.detail).sorted()
    }

    func testMergesHitsFromEveryEnabledProvider() {
        let multiplexer = SupplementaryMultiplexer(providers: [Provider(detail: "A"), Provider(detail: "B")])

        XCTAssertEqual(hits(multiplexer), ["A", "B"])
    }

    func testDisabledProviderContributesNothing() {
        let first = Provider(detail: "A"), second = Provider(detail: "B")
        second.isEnabled = false
        let multiplexer = SupplementaryMultiplexer(providers: [first, second])

        XCTAssertEqual(hits(multiplexer), ["A"])
    }

    func testReportsDisabledOnlyWhenEveryProviderIsDisabled() {
        let first = Provider(detail: "A"), second = Provider(detail: "B")
        let multiplexer = SupplementaryMultiplexer(providers: [first, second])
        XCTAssertTrue(multiplexer.isEnabled)

        second.isEnabled = false
        XCTAssertTrue(multiplexer.isEnabled)

        first.isEnabled = false
        XCTAssertFalse(multiplexer.isEnabled)
    }

    func testLifecycleCallbacksReachEveryProvider() {
        let first = Provider(detail: "A"), second = Provider(detail: "B")
        second.isEnabled = false
        let multiplexer = SupplementaryMultiplexer(providers: [first, second])

        multiplexer.sourcesDidChange([])
        multiplexer.userActivity(visible: true, typing: false)
        multiplexer.backgroundIndexingChanged(true)

        for provider in [first, second] {
            XCTAssertEqual(provider.sourceUpdates, 1)
            XCTAssertEqual(provider.visibility, [true])
            XCTAssertEqual(provider.busy, [true])
        }
    }
}
