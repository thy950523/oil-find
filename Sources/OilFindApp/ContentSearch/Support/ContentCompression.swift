import Foundation
import Compression

/// Shared by every content search component. Defined here so Task 1 compiles on its own.
enum ContentIndexError: Error, LocalizedError {
    case database(String)
    var errorDescription: String? { if case .database(let message) = self { return message }; return nil }
}

/// Body compression for the content index.
///
/// The byte layout is deliberately identical to `AITopicIndex.pack` — a leading codec byte
/// (0 raw, 1 LZFSE, 2 ZLIB) followed by the payload — but this is a separate implementation.
/// The AI topic decoder writes into a reusable buffer to avoid allocating on its search path,
/// which is not worth sharing here. Callers store the uncompressed length next to the body, so
/// decoding is a single exact-size pass and needs no growth guessing. There is no checksum: a bit
/// flip that still decodes to exactly `bytes` bytes yields silently wrong text, which is acceptable
/// because the index is derived and can be rebuilt.
enum ContentCompression {
    private enum Codec: UInt8 { case raw = 0, lzfse = 1, zlib = 2 }

    /// Ceiling on a single body, so a corrupt `bytes` column cannot drive an unbounded
    /// allocation on the search path. Chunks are written at 32-64 KiB, so this is generous.
    static let maxBodyBytes = 16 * 1024 * 1024

    static func pack(_ data: Data, compact: Bool = false) -> Data {
        let capacity = data.count
        guard capacity > 0 else { return Data([Codec.raw.rawValue]) }
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let out = destination.bindMemory(to: UInt8.self).baseAddress,
                      let input = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(out, capacity, input, capacity, nil,
                                                 compact ? COMPRESSION_ZLIB : COMPRESSION_LZFSE)
            }
        }
        guard written > 0, written < capacity else { return Data([Codec.raw.rawValue]) + data }
        output.count = written
        return Data([(compact ? Codec.zlib : Codec.lzfse).rawValue]) + output
    }

    /// `bytes` is the uncompressed length stored alongside the body.
    static func unpack(_ data: Data, bytes: Int) throws -> Data {
        guard let codec = data.first.flatMap(Codec.init(rawValue:)) else {
            throw ContentIndexError.database("Missing compression codec")
        }
        let body = data.dropFirst()
        if codec == .raw {
            guard body.count == bytes else { throw ContentIndexError.database("Truncated raw body") }
            return Data(body)
        }
        guard bytes > 0, bytes <= maxBodyBytes else { throw ContentIndexError.database("Body length out of range") }
        // Decode into one extra byte. The decoder reports a partial fill as success, so without
        // the spare byte a body longer than `bytes` would be truncated silently instead of
        // rejected. A body that is exactly `bytes` long still reports `bytes`.
        var output = Data(count: bytes + 1)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            body.withUnsafeBytes { source -> Int in
                guard let out = destination.bindMemory(to: UInt8.self).baseAddress,
                      let input = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(out, bytes + 1, input, body.count, nil,
                                                 codec == .zlib ? COMPRESSION_ZLIB : COMPRESSION_LZFSE)
            }
        }
        guard written == bytes else { throw ContentIndexError.database("Cannot decompress body") }
        output.count = bytes
        return output
    }
}
