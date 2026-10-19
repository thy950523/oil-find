import Foundation
import Compression

/// Shared by every content search component. Defined here so Task 1 compiles on its own.
enum ContentIndexError: Error, LocalizedError {
    case database(String)
    var errorDescription: String? { if case .database(let message) = self { return message }; return nil }
}

/// ZLIB for stored bodies, LZFSE for verification documents, matching the AI topic index.
/// A leading byte records the codec so the format can change without a migration.
enum Compression {
    private enum Codec: UInt8 { case raw = 0, zlib = 1, lzfse = 2 }

    static func pack(_ data: Data, compact: Bool = false) -> Data {
        guard !data.isEmpty else { return Data([Codec.raw.rawValue]) }
        let capacity = data.count
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil,
                                          compact ? COMPRESSION_ZLIB : COMPRESSION_LZFSE)
            }
        }
        guard written > 0, written < capacity else { return Data([Codec.raw.rawValue]) + data }
        output.count = written
        return Data([(compact ? Codec.zlib : Codec.lzfse).rawValue]) + output
    }

    static func unpack(_ data: Data) throws -> Data {
        guard let codec = data.first.flatMap(Codec.init(rawValue:)) else { throw ContentIndexError.database("Empty compressed body") }
        let body = data.dropFirst()
        guard codec != .raw else { return Data(body) }
        // The stored size is unknown; grow until the decoder stops reporting a short buffer.
        var capacity = max(1024, body.count * 4)
        while capacity <= 256 * 1024 * 1024 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination in
                body.withUnsafeBytes { source in
                    compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              source.bindMemory(to: UInt8.self).baseAddress!, body.count, nil,
                                              codec == .zlib ? COMPRESSION_ZLIB : COMPRESSION_LZFSE)
                }
            }
            if written > 0 && written < capacity { output.count = written; return output }
            capacity *= 4
        }
        throw ContentIndexError.database("Cannot decompress body")
    }
}
