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

    func testCancellationThrowsRatherThanReturningAnEmptyResult() throws {
        // `[]` means "parsed, genuinely no text", which makes the indexer clear the file's rows and
        // stop retrying it. Cancellation must throw instead, so the existing rows survive. Flip the
        // flag after the pre-decode check so the in-loop throw is the one exercised.
        let lines = (1...50).map { "line \($0)" }
        let url = try write(Data(lines.joined(separator: "\n").utf8), name: "cancel.txt")
        var calls = 0
        let isCancelled = { () -> Bool in calls += 1; return calls > 1 }

        XCTAssertThrowsError(try TextParser().parse(url: url, budget: budget, isCancelled: isCancelled)) { error in
            guard case ContentParserError.cancelled = error else {
                return XCTFail("expected cancelled, got \(error)")
            }
        }
    }

    /// A file the process may not read is not a damaged one: its bytes were never seen, and the
    /// difference is what tells a user to grant Full Disk Access rather than to distrust the file.
    /// Both are counted the same by the indexer, so this only pins the parser's own answer.
    func testAnUnreadableFileIsReportedAsUnreadable() throws {
        let url = try write(Data("secret".utf8), name: "locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        XCTAssertThrowsError(try TextParser().parse(url: url, budget: budget, isCancelled: { false })) { error in
            guard case ContentParserError.unreadable = error else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }

    func testSingleOverlongLineIsSplitIntoBoundedChunks() throws {
        // One line with no newline at all. The old flush-before-append test never split it: the
        // buffer was empty on entry, nothing flushed, and the whole line became one chunk. A line
        // past 16 MiB then made `replaceChunks` throw and abort the entire sync.
        let line = String(repeating: "发票", count: 2_000)  // 12 000 bytes, over the 1 KiB budget
        let url = try write(Data(line.utf8), name: "oneline.txt")

        let chunks = try TextParser(chunkBytes: 1024).parse(url: url, budget: budget, isCancelled: { false })

        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.text.utf8.count, 1024)
            // Every piece comes from the same line, so they all share its label.
            XCTAssertEqual(chunk.label, "第 1 行附近")
        }
        // Splitting cuts the line, it does not drop or reorder any of it.
        XCTAssertEqual(chunks.map(\.text).joined(), line)
    }

    func testCRLFDoesNotBecomeOneChunk() throws {
        // Swift reads "\r\n" as a single Character, so a "\n"-only split never breaks a CRLF file:
        // it stays one chunk and every label reads 第 1 行. A small budget makes the line labels
        // observable. The BOM is also checked because it must never surface in the text.
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data((1...5).map { "line \($0) 发票" }.joined(separator: "\r\n").utf8))
        let url = try write(data, name: "crlf.txt")

        let chunks = try TextParser(chunkBytes: 24).parse(url: url, budget: budget, isCancelled: { false })

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertFalse(chunks.allSatisfy { $0.label == "第 1 行附近" })
        for chunk in chunks {
            XCTAssertFalse(chunk.text.contains("\u{FEFF}"))
            XCTAssertFalse(chunk.text.contains("\r\n"))
        }
    }

    func testClassicMacLineEndingsProduceDistinctLabels() throws {
        // A lone-"\r" file is one line under a "\n"-only split, so every chunk would read 第 1 行.
        let body = (1...5).map { "line \($0) 发票" }.joined(separator: "\r")
        let url = try write(Data(body.utf8), name: "cr.txt")

        let chunks = try TextParser(chunkBytes: 24).parse(url: url, budget: budget, isCancelled: { false })

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertFalse(chunks.allSatisfy { $0.label == "第 1 行附近" })
    }
}
