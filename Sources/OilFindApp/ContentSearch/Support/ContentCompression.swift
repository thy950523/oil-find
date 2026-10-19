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
/// decoding is a single exact-size pass and needs no growth guessing.
enum ContentCompression {
    private enum Codec: UInt8 { case raw = 0, lzfse = 1, zlib = 2 }

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
        guard bytes > 0 else { throw ContentIndexError.database("Missing body length") }
        var output = Data(count: bytes)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            body.withUnsafeBytes { source -> Int in
                guard let out = destination.bindMemory(to: UInt8.self).baseAddress,
                      let input = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(out, bytes, input, body.count, nil,
                                                 codec == .zlib ? COMPRESSION_ZLIB : COMPRESSION_LZFSE)
            }
        }
        guard written == bytes else { throw ContentIndexError.database("Cannot decompress body") }
        return output
    }
}
