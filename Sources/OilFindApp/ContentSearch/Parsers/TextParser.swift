import CoreFoundation
import Foundation

/// Plain text and Markdown. The file is memory mapped and split into line-aligned chunks so a
/// search hit can report the line it came from.
struct TextParser: ContentParser {
    var maximumBytes = 32 * 1024 * 1024
    var chunkBytes = 64 * 1024
    var identifier: String { "text-1" }
    var kinds: Set<UInt8> { [3] }
    var extensions: Set<String> { ["txt", "md", "markdown", "csv", "tsv", "log"] }

    /// GB18030 has no `String.Encoding` constant because it is a Core Foundation encoding id.
    private static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    func parse(url: URL, budget: AITopicWorkBudget, isCancelled: () -> Bool) throws -> [ContentChunk] {
        guard extensions.contains(url.pathExtension.lowercased()) else { throw ContentParserError.unsupported }
        // The mapped length is authoritative: file attributes can silently read as 0, which would
        // let an enormous file reach `String(data:encoding:)` and allocate the whole document.
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ContentParserError.damaged
        }
        guard data.count <= maximumBytes else { throw ContentParserError.tooLarge }
        guard !isCancelled() else { throw ContentParserError.cancelled }
        let text = try Self.decode(data)
        guard !text.isEmpty else { return [] }

        var chunks: [ContentChunk] = []
        var buffer = ""
        var firstLine = 1
        var line = 1
        for piece in text.split(separator: "\n", omittingEmptySubsequences: false) {
            budget.checkpoint(isCancelled: isCancelled)
            // Cancellation throws rather than returning `[]`: the caller preserves existing rows
            // on a cancelled parse, while an empty array means the file really has no text.
            guard !isCancelled() else { throw ContentParserError.cancelled }
            let piece = String(piece)
            if !buffer.isEmpty && buffer.utf8.count + piece.utf8.count + 1 > chunkBytes {
                chunks.append(ContentChunk(ordinal: chunks.count, label: Self.label(firstLine), text: buffer))
                buffer = ""
                firstLine = line
            }
            buffer = buffer.isEmpty ? piece : buffer + "\n" + piece
            line += 1
        }
        if !buffer.isEmpty {
            chunks.append(ContentChunk(ordinal: chunks.count, label: Self.label(firstLine), text: buffer))
        }
        return chunks
    }

    private static func label(_ line: Int) -> String { "第 \(line) 行附近" }

    /// UTF-8 first, then UTF-16 only when a BOM says so, then GB18030.
    ///
    /// Without the BOM check almost any byte sequence "decodes" as UTF-16 and silently masks the
    /// correct GB18030 result. The cost is that BOM-less UTF-16 is read as GB18030, which is rare.
    static func decode(_ data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.count >= 2 {
            let prefix = [UInt8](data.prefix(2))
            if prefix == [0xFF, 0xFE] || prefix == [0xFE, 0xFF],
               let text = String(data: data, encoding: .utf16) {
                return text
            }
        }
        if let text = String(data: data, encoding: gb18030) { return text }
        throw ContentParserError.damaged
    }
}
