import AppKit
import XCTest
@testable import OilFindApp

final class ImageOCRParserTests: XCTestCase {
    private var directory: URL!
    private let parser = ImageOCRParser()
    /// Parsing never spends the budget on a single image, so the fraction is irrelevant here.
    private let budget = AITopicWorkBudget(fraction: 1)

    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("M22-ocr-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    /// Vision's accuracy tracks the OS build and the installed language assets, so only the
    /// cancellation test runs on CI. The check matches the house pattern in this suite.
    private func skipOnCI(_ reason: String) throws {
        if ProcessInfo.processInfo.environment["CI"] != nil { throw XCTSkip(reason) }
    }

    /// Draws `text` onto a white canvas and writes it as a PNG. A nil `text` produces a blank image.
    private func writeImage(width: Int, height: Int, text: String?, fontSize: CGFloat, name: String) throws -> URL {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        if let text {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.black,
            ]
            (text as NSString).draw(at: NSPoint(x: 60, y: CGFloat(height) / 2 - fontSize / 2),
                                    withAttributes: attributes)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let url = directory.appendingPathComponent(name)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    func testRecognizesChineseTextInAScreenshot() throws {
        try skipOnCI("Vision accuracy varies with the OS and language assets")
        let url = try writeImage(width: 1000, height: 320, text: "发票号码 12345", fontSize: 120, name: "invoice.png")
        let chunks = try parser.parse(url: url, budget: budget, isCancelled: { false })
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.ordinal, 0)
        XCTAssertEqual(chunks.first?.label, "")
        XCTAssertTrue(try XCTUnwrap(chunks.first?.text).contains("发票"))
    }

    func testImageWithoutTextProducesNoChunks() throws {
        try skipOnCI("Vision accuracy varies with the OS and language assets")
        let url = try writeImage(width: 400, height: 200, text: nil, fontSize: 0, name: "blank.png")
        XCTAssertTrue(try parser.parse(url: url, budget: budget, isCancelled: { false }).isEmpty)
    }

    /// Must not need Vision: cancellation is checked before the image is even opened, so a
    /// nonexistent file is enough. The error is distinct from an empty parse, which would let the
    /// caller clear rows a previous successful parse had stored.
    func testCancellationStopsBeforeRunningVision() throws {
        let url = directory.appendingPathComponent("never-opened.png")
        XCTAssertThrowsError(try parser.parse(url: url, budget: budget, isCancelled: { true })) { error in
            guard case ContentParserError.cancelled = error else {
                return XCTFail("Expected ContentParserError.cancelled, got \(error)")
            }
        }
    }

    func testDownsamplesVeryWideImages() throws {
        try skipOnCI("Vision accuracy varies with the OS and language assets")
        // 4200 -> 3000 is a 0.71 scale, so the glyphs are drawn oversized to survive it.
        let url = try writeImage(width: 4200, height: 600, text: "发票 2026", fontSize: 200, name: "wide.png")
        let chunks = try parser.parse(url: url, budget: budget, isCancelled: { false })
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(try XCTUnwrap(chunks.first?.text).contains("发票"))
    }
}
