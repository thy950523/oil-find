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
            // A file the process may not read is not a damaged one: its bytes were never seen, and the
            // difference is what tells a user to grant Full Disk Access rather than to distrust the
            // file. Foundation reports a permission failure as this Cocoa code, not as the POSIX one.
            if (error as NSError).code == NSFileReadNoPermissionError { throw ContentParserError.unreadable }
            throw ContentParserError.damaged
        }
        guard data.count <= maximumBytes else { throw ContentParserError.tooLarge }
        guard !isCancelled() else { throw ContentParserError.cancelled }
        var text = try Self.decode(data)
        // Foundation's UTF-8 decoding already drops a leading BOM, but strip U+FEFF explicitly so the
        // first chunk's text and snippets never carry it whatever the decode path produced.
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard !text.isEmpty else { return [] }

        var chunks: [ContentChunk] = []
        var buffer = ""
        var firstLine = 1
        var line = 1
        // `isNewline` treats "\n", "\r" and the "\r\n" pair as separators, along with U+2028/U+2029.
        // Swift reads "\r\n" as a single Character, so splitting on the "\n" Character alone would
        // never break a CRLF file at all (it would stay one chunk), and a lone-"\r" classic-Mac file
        // would do the same.
        for piece in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
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
            if piece.utf8.count > chunkBytes {
                // A single line longer than the whole budget can never be joined into the buffer, so
                // the flush above leaves the buffer empty and this line must be split here. Emitting
                // it whole would hand `replaceChunks` a body past its 16 MiB ceiling; that throw
                // escapes `apply` and aborts the entire sync at this file on every subsequent run.
                Self.appendSplit(piece, line: line, chunkBytes: chunkBytes, into: &chunks)
                firstLine = line + 1
            } else {
                buffer = buffer.isEmpty ? piece : buffer + "\n" + piece
            }
            line += 1
        }
        if !buffer.isEmpty {
            chunks.append(ContentChunk(ordinal: chunks.count, label: Self.label(firstLine), text: buffer))
        }
        return chunks
    }

    /// Emits one over-long line as chunks of at most `chunkBytes` UTF-8 bytes, all carrying the same
    /// line label because they all come from that line. Pieces are cut on character boundaries, never
    /// bytes, so no UTF-8 sequence is split in half.
    private static func appendSplit(_ text: String, line: Int, chunkBytes: Int, into chunks: inout [ContentChunk]) {
        var piece = ""
        func flush() {
            guard !piece.isEmpty else { return }
            chunks.append(ContentChunk(ordinal: chunks.count, label: label(line), text: piece))
            piece = ""
        }
        for character in text {
            // A grapheme cluster wider than the entire budget is pathological, but it cannot be split
            // on a character boundary. Fall back to scalars, which still never cut a UTF-8 sequence.
            if character.utf8.count > chunkBytes {
                flush()
                for scalar in character.unicodeScalars {
                    let scalarText = String(scalar)
                    if !piece.isEmpty && piece.utf8.count + scalarText.utf8.count > chunkBytes { flush() }
                    piece += scalarText
                }
                continue
            }
            if !piece.isEmpty && piece.utf8.count + character.utf8.count > chunkBytes { flush() }
            piece.append(character)
        }
        flush()
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
