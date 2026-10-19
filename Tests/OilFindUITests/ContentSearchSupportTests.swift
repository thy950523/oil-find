import XCTest
@testable import OilFindApp

final class ContentSearchSupportTests: XCTestCase {
    func testCompressionRoundTrips() throws {
        for text in ["", "收据", String(repeating: "开具发票的日期 ", count: 5000),
                     String((0..<4096).map { _ in Character(UnicodeScalar(UInt8.random(in: 32...126))) })] {
            let raw = Data(text.utf8)
            XCTAssertEqual(try Compression.unpack(Compression.pack(raw)), raw)
        }
    }
    func testGramCheckpointIsCalledAndCancellationPropagates() throws {
        var calls = 0
        let text = String(repeating: "发票 ", count: 20000)
        _ = try AITopicIndex.grams(text, checkpoint: { calls += 1 })
        XCTAssertGreaterThan(calls, 0)
        XCTAssertThrowsError(try AITopicIndex.grams(text, checkpoint: { throw CancellationError() }))
    }
}
