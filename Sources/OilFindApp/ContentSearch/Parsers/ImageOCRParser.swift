import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Vision text recognition. Revision is part of the identifier so a revision change reindexes.
struct ImageOCRParser: ContentParser {
    static let revision = VNRecognizeTextRequestRevision3
    /// Formats `CGImageSource` can decode. SVG, PSD, AI and camera raw are deliberately absent.
    static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp",
                                                   "bmp", "tif", "tiff", "avif", "icns", "ico"]
    static let maximumDimension: CGFloat = 3000
    var identifier: String { "ocr-\(Self.revision)" }
    var kinds: Set<UInt8> { [4] }
    var extensions: Set<String> { Self.supportedExtensions }

    /// Recognises the text in one image. `budget` is intentionally unused: `perform` blocks for the
    /// whole image and yields no checkpoint, so the only granularity the Vision API allows is one
    /// image. The indexer applies the budget between images; nothing finer is possible here.
    func parse(url: URL, budget: AITopicWorkBudget, isCancelled: () -> Bool) throws -> [ContentChunk] {
        // Cancellation is checked before Vision runs: `perform` is synchronous and does not yield,
        // so a cancel arriving mid-image cannot be honoured. Throwing rather than returning `[]`
        // keeps cancellation distinct from "parsed, no text", so the caller preserves existing rows.
        guard !isCancelled() else { throw ContentParserError.cancelled }
        guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw ContentParserError.unsupported
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ContentParserError.damaged
        }
        let request = VNRecognizeTextRequest()
        request.revision = Self.revision
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        // Recognition cost grows with pixel count and `perform` blocks, so downsampling is the only
        // lever on per-image latency. Below the threshold the URL handler is used directly, which
        // lets Vision apply EXIF orientation itself; a `CGImage` would bypass that, so the rotation
        // is baked in by the thumbnail transform when one is produced.
        let handler: VNImageRequestHandler
        if Self.longEdge(of: source) > Self.maximumDimension, let image = Self.thumbnail(of: source) {
            handler = VNImageRequestHandler(cgImage: image, options: [:])
        } else {
            handler = VNImageRequestHandler(url: url, options: [:])
        }
        do {
            try handler.perform([request])
        } catch {
            throw ContentParserError.damaged
        }
        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        // No recognisable text is not an error, and not one empty chunk: the file genuinely has none.
        guard !text.isEmpty else { return [] }
        // An image yields at most one chunk with no label: there is no page or section to point at,
        // so the presentation layer substitutes a kind-based prefix for an empty label.
        return [ContentChunk(ordinal: 0, label: "", text: text)]
    }

    /// Long edge in pixels, read from the image metadata without decoding it. Orientation is
    /// ignored: the raw pixel dimensions are what the decoder will actually process. A metadata
    /// read that fails returns 0, which skips downsampling rather than failing the parse.
    private static func longEdge(of source: CGImageSource) -> CGFloat {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
            return 0
        }
        return CGFloat(max(width, height))
    }

    /// A downsampled copy with the EXIF transform applied.
    ///
    /// `kCGImageSourceCreateThumbnailWithTransform` is required because handing Vision a `CGImage`
    /// bypasses its own EXIF handling: without it a rotated photo reaches OCR sideways and
    /// recognition degrades. `kCGImageSourceCreateThumbnailFromImageAlways` is required because
    /// `CGImageSourceCreateThumbnailAtIndex` otherwise returns a small embedded thumbnail (camera
    /// JPEGs often carry a ~160 px one), and OCR would then silently find nothing on a perfectly
    /// legible image. A nil result falls back to the URL handler in `parse`.
    private static func thumbnail(of source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maximumDimension),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
