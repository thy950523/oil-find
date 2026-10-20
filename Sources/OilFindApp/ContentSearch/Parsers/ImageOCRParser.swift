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
        // A zero-length file has no bytes to decode and cannot change until the file itself is
        // rewritten, so it can never yield text. Returning `[]` records it as genuinely textless;
        // throwing would instead count it as a failure that every later sync retries and re-counts
        // forever, so the failed count a user sees could never fall.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
           size.intValue == 0 {
            return []
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ContentParserError.damaged
        }
        // Bytes that are not an image at all (a text file named `.png`, an HTML error page saved as
        // `.jpg`, or random data) report `unknownType` for frame 0, which no transient state explains,
        // so re-feeding them to Vision on every sync would keep the failed count from ever falling.
        // They are recorded as textless instead. The status is read at the frame level because the
        // source-level status reports `invalidData` for every one of these fixtures, the transient
        // ones included, so it cannot tell a non-image from a truncated file. No frame-count guard
        // gates the read: ImageIO answers for index 0 even when the source holds no frames, and that
        // answer is exactly what separates a non-image (`unknownType`) from a header-only partial
        // download (which can report `unexpectedEOF` with no frames either), so requiring a positive
        // count would silence the rule. The rule stays deliberately narrow: truncated or
        // partially-downloaded files report `unexpectedEOF` or `incomplete` for frame 0, which can be
        // transient, and recording those as textless would permanently discard text that a later,
        // complete read could still extract.
        if CGImageSourceGetStatusAtIndex(source, 0) == .statusUnknownType {
            return []
        }
        // Everything past that check has readable bytes, because the type is taken from the header and
        // a header that could not be read leaves it nil. ImageIO hands back a source for a file it
        // cannot read at all — one the process may not open, or one it cannot open because its
        // descriptor table is full — rather than failing, and that source reports `unexpectedEOF` for
        // frame 0, which is otherwise the transient state of a partial download. Without this guard
        // the file reaches Vision, fails to decode there, and is reported as damaged, so a locked file
        // would look like a corrupt one and every later pass would retry it the same way.
        guard CGImageSourceGetType(source) != nil else { throw ContentParserError.unreadable }
        let request = VNRecognizeTextRequest()
        request.revision = Self.revision
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        // Recognition cost grows with pixel count and `perform` blocks, so downsampling is the only
        // lever on per-image latency. Below the threshold the URL handler is used directly, which
        // lets Vision apply EXIF orientation itself; a `CGImage` would bypass that, so the rotation
        // is baked in by the thumbnail transform when one is produced.
        let longEdge = Self.longEdge(of: source)
        let handler: VNImageRequestHandler
        if let longEdge = longEdge, longEdge > Self.maximumDimension {
            // Known to be large. Downsampling is mandatory here: Vision at full resolution on a very
            // large image (e.g. a 300 MP scan) decodes to a roughly 1.2 GB RGBA buffer and can OOM-kill
            // the app, so a thumbnail that cannot be produced must fail the parse rather than fall back
            // to the URL handler. Losing one un-indexable image beats an OOM kill, and the error
            // surfaces in the failed count.
            guard let image = Self.thumbnail(of: source) else { throw ContentParserError.tooLarge }
            handler = VNImageRequestHandler(cgImage: image, options: [:])
        } else if longEdge == nil, let image = Self.thumbnail(of: source) {
            // Size unknown, so there is no evidence the image is large: try the bounded thumbnail
            // anyway (cheap and safe) and use it if it succeeds.
            handler = VNImageRequestHandler(cgImage: image, options: [:])
        } else {
            // Known to be small, or the thumbnail could not be produced for an image of unknown size:
            // let Vision decode the URL and apply EXIF orientation itself.
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
    /// ignored: the raw pixel dimensions are what the decoder will actually process. `nil` means the
    /// metadata could not be read; `parse` treats that as "size unknown" rather than "small", because
    /// a failed metadata read must not silently hand a huge image to Vision at full resolution.
    /// Internal rather than private so tests can assert on the downsample decision directly.
    static func longEdge(of source: CGImageSource) -> CGFloat? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
            return nil
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
    /// legible image. A nil result makes `parse` throw `tooLarge` when the size is known to be large,
    /// and fall back to the URL handler when it is not. Internal rather than private so tests can
    /// assert on the clamp directly.
    static func thumbnail(of source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maximumDimension),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
