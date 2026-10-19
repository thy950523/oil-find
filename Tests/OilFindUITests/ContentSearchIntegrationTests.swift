import AppKit
import Foundation
import XCTest
@testable import OilFindCore
@testable import OilFindApp

/// End-to-end coverage of the real parser -> indexer -> search chain. `ContentIndexerTests` drives
/// the indexer with a `StubParser`, which proves each link in isolation but never the whole chain:
/// a wiring mistake between them (a wrong kind, a dropped `apply`, a label or highlight that never
/// reaches a hit) could pass every test there. These tests run the real parsers over real files on
/// disk and assert on the resulting search hit.
final class ContentSearchIntegrationTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!
    private var index: ContentIndex!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("M22-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = makeContentDatabaseURL()
        index = try ContentIndex(url: databaseURL)
    }

    override func tearDownWithError() throws {
        index = nil
        removeContentDatabase(databaseURL)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        databaseURL = nil
    }

    /// Vision's accuracy tracks the OS build and the installed language assets, so the OCR test only
    /// runs locally. The check matches the house pattern in this suite.
    private func skipOnCI(_ reason: String) throws {
        if ProcessInfo.processInfo.environment["CI"] != nil { throw XCTSkip(reason) }
    }

    private struct Entry {
        let name: String
        let kind: UInt8
    }

    /// Index 0 is the root directory, as the real scanner produces, and every entry is its direct
    /// child. The hash table must be built because a loaded store resolves paths through it.
    private func makeStore(_ entries: [Entry]) -> IndexStore {
        var buffer = ScanBuffer()
        Array("".utf8).withUnsafeBufferPointer {
            buffer.append(id: 0, parent: 0, size: 0, mtime: 0, flags: SiftFlag.dir, depth: 0, kind: 1, name: $0)
        }
        for (offset, entry) in entries.enumerated() {
            Array(entry.name.utf8).withUnsafeBufferPointer {
                buffer.append(id: UInt32(offset + 1), parent: 0, size: UInt32(offset + 1),
                              mtime: UInt32(offset + 1), flags: 0, depth: 1, kind: entry.kind, name: $0)
            }
        }
        let store = IndexStore(scan: ScanOutput(buffers: [buffer], count: entries.count + 1, homeIndex: .max,
                                                elapsed: 0, finishedAt: 0),
                               config: IndexConfig(rootPath: directory.path))
        store.write { store.buildHash() }
        return store
    }

    /// Draws `text` onto a white canvas and writes it as a PNG, mirroring the fixture helper in
    /// `ImageOCRParserTests`.
    private func writeImage(width: Int, height: Int, text: String, fontSize: CGFloat, name: String) throws -> URL {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.black,
        ]
        (text as NSString).draw(at: NSPoint(x: 60, y: CGFloat(height) / 2 - fontSize / 2),
                                withAttributes: attributes)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let url = directory.appendingPathComponent(name)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    /// The highlight ranges must land on the searched string itself, not merely somewhere in the
    /// snippet. An empty or mis-offset range would still make the file "found" while the UI would
    /// underline the wrong text.
    private func assertHighlights(_ hit: ContentHit, landOn term: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let snippet = hit.snippet as NSString
        XCTAssertTrue(hit.highlights.contains { snippet.substring(with: $0) == term },
                      "highlights \(hit.highlights) in snippet \(hit.snippet)", file: file, line: line)
    }

    /// A real `TextParser` writes a UTF-8 file's Chinese line into the index, and a real
    /// `ContentIndex` finds it by that string, labelling the hit with the line it came from.
    func testTextFileIsFoundEndToEndByItsContent() throws {
        let fileURL = directory.appendingPathComponent("invoice.txt")
        try Data("第一行\n开具发票的说明\n第三行\n".utf8).write(to: fileURL)

        let indexer = ContentIndexer(index: index, parsers: [TextParser()])
        try indexer.synchronize(store: makeStore([Entry(name: "invoice.txt", kind: 3)]),
                                isCancelled: { false })

        let hits = try index.search("开具发票", limit: 10, isCancelled: { false })
        XCTAssertEqual(hits.count, 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.path, fileURL.path)
        XCTAssertEqual(hit.kind, 3)
        // The text parser labels each chunk by the line it starts at, so the hit points at a line.
        XCTAssertTrue(hit.label.contains("行"), "label was \(hit.label)")
        assertHighlights(hit, landOn: "开具发票")
    }

    /// The same chain through Vision: a real `ImageOCRParser` OCRs a synthesised PNG, the indexer
    /// stores the recognised text, and a real search finds the file by a Chinese word in the image.
    func testImageIsFoundEndToEndByItsOCRedContent() throws {
        try skipOnCI("Vision accuracy varies with the OS and language assets")
        let fileURL = try writeImage(width: 1000, height: 320, text: "开具发票 12345",
                                     fontSize: 120, name: "invoice.png")

        let indexer = ContentIndexer(index: index, parsers: [ImageOCRParser()])
        try indexer.synchronize(store: makeStore([Entry(name: "invoice.png", kind: 4)]),
                                isCancelled: { false })

        let hits = try index.search("开具发票", limit: 10, isCancelled: { false })
        XCTAssertEqual(hits.count, 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.path, fileURL.path)
        XCTAssertEqual(hit.kind, 4)
        // An image has no line to point at, so the parser leaves the label empty; the recognised
        // text still reaches the snippet and the highlight lands on the searched string.
        XCTAssertEqual(hit.label, "")
        assertHighlights(hit, landOn: "开具发票")
    }
}
