import CoreFoundation
import Foundation
import XCTest
@testable import OilFindApp

final class TextParserTests: XCTestCase {
    private var directory: URL!
    private let budget = AITopicWorkBudget(fraction: 1)

    /// GB18030 is not exposed as a `String.Encoding` constant, so it is derived from the Core
    /// Foundation encoding id. Tests use it both to write legacy files and to assert the fallback.
    private static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("M22-text-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func write(_ data: Data, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testReadsUTF8AndReportsLineLabels() throws {
        var lines = (1...199).map { "line \($0)" }
        lines.append("第 200 行 开具发票")
        let url = try write(Data(lines.joined(separator: "\n").utf8), name: "note.txt")

        let chunks = try TextParser().parse(url: url, budget: budget, isCancelled: { false })

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.ordinal, 0)
        XCTAssertTrue(chunks.first?.text.contains("第 200 行") == true)
        XCTAssertTrue(chunks.first?.label.hasPrefix("第 1 行") == true)
    }

    func testSplitsLongFilesIntoMultipleChunks() throws {
        let lines = (1...20_000).map { "line \($0)" }
        let url = try write(Data(lines.joined(separator: "\n").utf8), name: "long.log")

        let chunks = try TextParser().parse(url: url, budget: budget, isCancelled: { false })

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.ordinal), Array(0..<chunks.count))
    }

    func testDetectsUTF16() throws {
        let body = "这是正文，开具发票。"
        var data = Data([0xFF, 0xFE])
        data.append(try XCTUnwrap(body.data(using: .utf16LittleEndian)))
        let url = try write(data, name: "utf16.txt")

        let chunks = try TextParser().parse(url: url, budget: budget, isCancelled: { false })

        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks.first?.text.contains("开具发票") == true)
    }

    func testFallsBackToGB18030ForLegacyChineseFiles() throws {
        let body = "这是正文，开具发票。"
        let url = try write(try XCTUnwrap(body.data(using: Self.gb18030)), name: "legacy.txt")

        let chunks = try TextParser().parse(url: url, budget: budget, isCancelled: { false })

        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks.first?.text.contains("开具发票") == true)
    }

    func testRejectsOversizedFiles() throws {
        let url = try write(Data(count: 1024), name: "big.txt")

        XCTAssertThrowsError(try TextParser(maximumBytes: 512).parse(url: url, budget: budget,
                                                                    isCancelled: { false })) { error in
            guard case ContentParserError.tooLarge = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
    }
}
