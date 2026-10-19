import XCTest
@testable import OilFindApp

final class ContentIndexSearchTests: XCTestCase {
    private var url: URL!
    private var index: ContentIndex!

    override func setUpWithError() throws {
        url = makeContentDatabaseURL()
        index = try ContentIndex(url: url)
    }

    override func tearDownWithError() throws {
        index = nil
        removeContentDatabase(url)
    }

    @discardableResult
    private func store(path: String, kind: UInt8 = 3, chunks: [(String, String)]) throws -> Int64 {
        try index.store(file: .init(path: path, size: 1, mtime: 1, kind: kind, parser: "test"),
                        chunks: chunks.enumerated().map {
                            .init(ordinal: $0.offset, label: $0.element.0, text: $0.element.1)
                        })
    }

    private func search(_ text: String, limit: Int = 10) throws -> [ContentHit] {
        try index.search(text, limit: limit, isCancelled: { false })
    }

    func testFindsChineseSubstringWithLabelAndHighlight() throws {
        try store(path: "/note.txt", chunks: [("第 1 行附近", "本月开具发票的日期")])
        let hits = try search("发票")
        XCTAssertEqual(hits.count, 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.path, "/note.txt")
        XCTAssertEqual(hit.label, "第 1 行附近")
        let range = try XCTUnwrap(hit.highlights.first)
        XCTAssertEqual((hit.snippet as NSString).substring(with: range), "发票")
    }

    func testIsCaseInsensitiveAndFindsEnglish() throws {
        try store(path: "/a.txt", chunks: [("第 1 行附近", "Invoice #1234 due Friday")])
        XCTAssertEqual(try search("invoice").count, 1)
        XCTAssertEqual(try search("INVOICE").count, 1)
    }

    func testDoesNotReportMatchesThatOnlyExistAcrossChunkBoundaries() throws {
        try store(path: "/a.txt", chunks: [("第 1 行附近", "收"), ("第 2 行附近", "据")])
        XCTAssertTrue(try search("收据").isEmpty)
    }

    func testReturnsEachFileOnceWithItsBestChunk() throws {
        try store(path: "/a.txt", chunks: [("第 1 行附近", "发票"), ("第 2 行附近", "发票 发票 发票")])
        let hits = try search("发票")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.label, "第 2 行附近")
    }

    func testRespectsLimitAndCancellation() throws {
        for i in 0..<20 {
            try store(path: "/file\(i).txt", chunks: [("第 1 行附近", "发票")])
        }
        XCTAssertEqual(try search("发票", limit: 5).count, 5)
        XCTAssertTrue(try index.search("发票", limit: 5, isCancelled: { true }).isEmpty)
    }
}
