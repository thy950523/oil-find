import XCTest
@testable import OilFindApp

final class ContentSearchSupportTests: XCTestCase {
    private func roundTrip(_ data: Data) throws {
        for compact in [false, true] {
            let packed = ContentCompression.pack(data, compact: compact)
            XCTAssertEqual(try ContentCompression.unpack(packed, bytes: data.count), data)
        }
    }
    private func pseudorandomBytes(_ count: Int) -> Data {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return Data((0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        })
    }
    func testCompressionRoundTrips() throws {
        for text in ["", "收据", String(repeating: "开具发票的日期 ", count: 5000)] {
            try roundTrip(Data(text.utf8))
        }
        try roundTrip(pseudorandomBytes(4096))
    }
    func testCompressibleInputActuallyCompresses() throws {
        let raw = Data(String(repeating: "开具发票的日期 ", count: 5000).utf8)
        XCTAssertLessThan(ContentCompression.pack(raw, compact: true).count, raw.count)
    }
    func testIncompressibleInputFallsBackToRaw() throws {
        // Random bytes cannot shrink, so pack must store them verbatim behind the raw codec.
        let raw = pseudorandomBytes(4096)
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
    func testCodecBytesAreStable() throws {
        // The codec byte is persisted; changing it silently invalidates every existing index.
        let compressible = Data(String(repeating: "开具发票的日期 ", count: 5000).utf8)
        XCTAssertEqual(ContentCompression.pack(compressible, compact: true).first, 2)   // zlib
        XCTAssertEqual(ContentCompression.pack(compressible, compact: false).first, 1)  // lzfse
        XCTAssertEqual(ContentCompression.pack(Data([1]), compact: true).first, 0)      // raw fallback
    }

    func testWrongBodyLengthThrows() throws {
        let raw = Data(String(repeating: "abcdefghij", count: 1000).utf8)
        let packed = ContentCompression.pack(raw, compact: true)
        XCTAssertEqual(try ContentCompression.unpack(packed, bytes: raw.count), raw)
        XCTAssertThrowsError(try ContentCompression.unpack(packed, bytes: raw.count - 1))
        XCTAssertThrowsError(try ContentCompression.unpack(packed, bytes: raw.count + 1))
        XCTAssertThrowsError(try ContentCompression.unpack(packed, bytes: ContentCompression.maxBodyBytes + 1))
    }
    func testGramCheckpointIsCalledAndCancellationPropagates() throws {
        var calls = 0
        let text = String(repeating: "发票 ", count: 20000)
        _ = try AITopicIndex.grams(text, checkpoint: { calls += 1 })
        XCTAssertGreaterThan(calls, 0)
        XCTAssertThrowsError(try AITopicIndex.grams(text, checkpoint: { throw CancellationError() }))
    }
}
