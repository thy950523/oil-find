import Foundation

/// A format-specific text extractor. `ordinal` and `label` locate a chunk inside the document.
protocol ContentParser {
    /// Stable identifier stored in `files.parser`; changing it invalidates indexed rows.
    var identifier: String { get }
    /// File-index kinds this parser handles: 3 = document, 4 = image.
    var kinds: Set<UInt8> { get }
    /// Lowercased extensions, or `["*"]` for every file of those kinds.
    var extensions: Set<String> { get }
    func parse(url: URL, budget: AITopicWorkBudget, isCancelled: () -> Bool) throws -> [ContentChunk]
}

/// Why a parser refused a file.
///
/// `cancelled` is deliberately distinct from an empty result: `[]` means the file parsed and
/// genuinely contains no text, so the caller may clear its chunks, while cancellation must leave
/// the file's existing rows untouched. Conflating the two would let a routine cancel (quit, toggling
/// the setting, rebuild, a superseding sync) wipe text that had indexed successfully and commit the
/// current metadata, after which the file is classified `unchanged` and never re-parsed.
enum ContentParserError: Error {
    case unsupported
    case tooLarge
    case damaged
    case cancelled
}
