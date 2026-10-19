import AppKit
import ImageIO
import UniformTypeIdentifiers
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

    /// Draws `text` onto a white canvas and writes it as a JPEG carrying an embedded thumbnail,
    /// reproducing the camera-style files the downsample path exists for. A `CGImage` from
    /// `NSBitmapImageRep` carries no EXIF, so orientation is not exercised here.
    private func writeJPEGWithEmbeddedThumbnail(width: Int, height: Int, text: String,
                                                fontSize: CGFloat, name: String) throws -> URL {
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
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
                                                                        UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.cgImage),
                                   [kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// Wraps a written image in a `CGImageSource` so the downsample helpers can be exercised directly.
    private func source(for url: URL) throws -> CGImageSource {
        try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
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

    /// Asserts on the downsample itself rather than on the OCR result: `testDownsamplesVeryWideImages`
    /// would also pass if the image reached Vision at full resolution. Fails if
    /// `kCGImageSourceThumbnailMaxPixelSize` is dropped (the long edge stays at 4200) or if
    /// `kCGImageSourceCreateThumbnailFromImageAlways` is dropped (a synthesised PNG has no embedded
    /// thumbnail, so the call returns nil). Needs no Vision, so it runs on CI.
    func testThumbnailClampsTheLongEdgeOfALargeImage() throws {
        let url = try writeImage(width: 4200, height: 600, text: nil, fontSize: 0, name: "clamp.png")
        let imageSource = try source(for: url)
        XCTAssertEqual(try XCTUnwrap(ImageOCRParser.longEdge(of: imageSource)), 4200)
        let thumbnail = try XCTUnwrap(ImageOCRParser.thumbnail(of: imageSource))
        let longEdge = max(thumbnail.width, thumbnail.height)
        XCTAssertLessThanOrEqual(CGFloat(longEdge), ImageOCRParser.maximumDimension)
        // A real downsample, not an embedded thumbnail: a tiny result would be something Vision
        // cannot read, which is the failure mode `kCGImageSourceCreateThumbnailFromImageAlways` guards.
        XCTAssertGreaterThan(longEdge, 1000)
    }

    /// The trap the design calls out as most likely to ship unnoticed. A JPEG written with
    /// `kCGImageDestinationEmbedThumbnail` carries a small (~160 px) embedded thumbnail, so without
    /// `kCGImageSourceCreateThumbnailFromImageAlways`, `CGImageSourceCreateThumbnailAtIndex` returns
    /// that tiny copy and OCR finds nothing. The PNG fixtures cannot catch this: they carry no
    /// embedded thumbnail, so the same call returns nil instead of a small image. The text is 120 pt
    /// rather than the 200 pt used elsewhere on purpose: at 200 pt Vision still reads the 160 px
    /// thumbnail on this OS, which would let the test pass with the flag removed.
    func testRecognizesTextWhenTheImageCarriesAnEmbeddedThumbnail() throws {
        try skipOnCI("Vision accuracy varies with the OS and language assets")
        let url = try writeJPEGWithEmbeddedThumbnail(width: 4200, height: 600, text: "发票 2026",
                                                     fontSize: 120, name: "embedded.jpg")
        let chunks = try parser.parse(url: url, budget: budget, isCancelled: { false })
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(try XCTUnwrap(chunks.first?.text).contains("发票"))
    }

    /// A zero-byte `.png` is not an image and never will be, so it must parse as "no text" rather
    /// than throw: throwing would count it as a failure on every sync forever, so the failed count a
    /// user sees could never fall. Needs no Vision, so it runs on CI.
    func testZeroByteImageProducesNoChunks() throws {
        let url = directory.appendingPathComponent("empty.png")
        try Data().write(to: url)
        XCTAssertTrue(try parser.parse(url: url, budget: budget, isCancelled: { false }).isEmpty)
    }

    /// A text file named `.png` is not an image and never will be, so it must parse as "no text"
    /// rather than throw: throwing would count it as a failure on every sync forever, so the failed
    /// count a user sees could never fall. ImageIO reports `unknownType` for frame 0 (the
    /// source-level status is `invalidData`, which the transient fixtures report too), so the check
    /// has to be made at the frame level. Needs no Vision, so it runs on CI.
    func testNonImageBytesWithAnImageExtensionProduceNoChunks() throws {
        let url = directory.appendingPathComponent("not-an-image.png")
        try Data("this file is plain text, not a PNG image at all".utf8).write(to: url)
        XCTAssertTrue(try parser.parse(url: url, budget: budget, isCancelled: { false }).isEmpty)
    }
}
