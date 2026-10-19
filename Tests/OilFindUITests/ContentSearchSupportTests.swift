import XCTest
@testable import OilFindApp

final class ContentSearchSupportTests: XCTestCase {
    private func roundTrip(_ data: Data) throws {
        for compact in [false, true] {
            let packed = ContentCompression.pack(data, compact: compact)
            XCTAssertEqual(try ContentCompression.unpack(packed, bytes: data.count), data)
        }
    }
    func testCompressionRoundTrips() throws {
        for text in ["", "收据", String(repeating: "开具发票的日期 ", count: 5000),
                     String((0..<4096).map { _ in Character(UnicodeScalar(UInt8.random(in: 32...126))) })] {
            try roundTrip(Data(text.utf8))
        }
    }
    func testCompressibleInputActuallyCompresses() throws {
        let raw = Data(String(repeating: "开具发票的日期 ", count: 5000).utf8)
        XCTAssertLessThan(ContentCompression.pack(raw, compact: true).count, raw.count)
    }
    func testIncompressibleInputFallsBackToRaw() throws {
        // Random bytes cannot shrink, so pack must store them verbatim behind the raw codec.
        let raw = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        let packed = ContentCompression.pack(raw, compact: true)
        XCTAssertEqual(packed.first, 0)
        XCTAssertEqual(Data(packed.dropFirst()), raw)
    }
    func testDamagedBodiesThrow() throws {
        XCTAssertThrowsError(try ContentCompression.unpack(Data(), bytes: 4))           // no codec byte
        XCTAssertThrowsError(try ContentCompression.unpack(Data([9, 1, 2]), bytes: 4))  // unknown codec
        XCTAssertThrowsError(try ContentCompression.unpack(Data([2, 1, 2]), bytes: 4))  // truncated zlib
        XCTAssertThrowsError(try ContentCompression.unpack(Data([0, 1, 2]), bytes: 4))  // raw length mismatch
    }
    func testGramCheckpointIsCalledAndCancellationPropagates() throws {
        var calls = 0
        let text = String(repeating: "发票 ", count: 20000)
        _ = try AITopicIndex.grams(text, checkpoint: { calls += 1 })
        XCTAssertGreaterThan(calls, 0)
        XCTAssertThrowsError(try AITopicIndex.grams(text, checkpoint: { throw CancellationError() }))
    }
}
