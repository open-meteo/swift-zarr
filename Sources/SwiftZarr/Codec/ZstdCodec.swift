import Foundation
import libzstd

/// Zstandard frames used by both V2 and V3 arrays.
public struct ZstdCodec: Codec {
    private let level: Int
    private let checksum: Bool

    public init(level: Int = 0, checksum: Bool = false) {
        self.level = level
        self.checksum = checksum
    }

    internal static func validLevel(_ level: Int) -> Bool {
        (Int(ZSTD_minCLevel())...Int(ZSTD_maxCLevel())).contains(level)
    }

    public func encode(_ data: Data) throws -> Data {
        guard Self.validLevel(level), let context = ZSTD_createCCtx() else {
            throw CodecError.encodeFailed("invalid zstd level or context allocation failed")
        }
        defer { ZSTD_freeCCtx(context) }
        func check(_ result: Int) throws -> Int {
            guard ZSTD_isError(result) == 0 else {
                throw CodecError.encodeFailed(String(cString: ZSTD_getErrorName(result)))
            }
            return result
        }
        _ = try check(ZSTD_CCtx_setParameter(context, ZSTD_c_compressionLevel, CInt(level)))
        _ = try check(ZSTD_CCtx_setParameter(context, ZSTD_c_checksumFlag, checksum ? 1 : 0))
        var output = Data(count: try check(ZSTD_compressBound(data.count)))
        let size = try data.withUnsafeBytes { source in
            try output.withUnsafeMutableBytes { destination in
                try check(
                    ZSTD_compress2(
                        context,
                        destination.baseAddress,
                        destination.count,
                        source.baseAddress,
                        source.count
                    )
                )
            }
        }
        output.count = size
        return output
    }

    /// Decode into caller-owned storage. Oversized output uses the general decoder
    /// to preserve frame validation and the exact decoded-size error.
    internal func decode(_ data: Data, into destination: UnsafeMutableRawBufferPointer) throws {
        guard !data.isEmpty, let context = ZSTD_createDCtx() else {
            throw CodecError.invalidData("empty zstd input or context allocation failed")
        }
        defer { ZSTD_freeDCtx(context) }
        let size = try data.withUnsafeBytes { source in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
            var output = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
            var remaining = 1
            repeat {
                if output.pos == output.size {
                    return try decode(data).count
                }
                let previousInput = input.pos
                let previousOutput = output.pos
                remaining = ZSTD_decompressStream(context, &output, &input)
                guard ZSTD_isError(remaining) == 0 else {
                    throw CodecError.invalidData(String(cString: ZSTD_getErrorName(remaining)))
                }
                guard input.pos != previousInput || output.pos != previousOutput else {
                    throw CodecError.invalidData("truncated zstd frame")
                }
            } while input.pos < input.size || remaining != 0
            return output.pos
        }
        guard size == destination.count else {
            throw ZarrArrayError.invalidDataSize(expected: destination.count, got: size)
        }
    }

    public func decode(_ data: Data) throws -> Data {
        guard !data.isEmpty, let context = ZSTD_createDCtx() else {
            throw CodecError.invalidData("empty zstd input or context allocation failed")
        }
        defer { ZSTD_freeDCtx(context) }
        // Streaming supports unknown content sizes and concatenated frames without trusting header allocations.
        var output = Data()
        var buffer = Data(count: ZSTD_DStreamOutSize())
        try data.withUnsafeBytes { source in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
            var remaining = 1
            repeat {
                let previous = input.pos
                try buffer.withUnsafeMutableBytes { destination in
                    var chunk = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                    remaining = ZSTD_decompressStream(context, &chunk, &input)
                    guard ZSTD_isError(remaining) == 0 else {
                        throw CodecError.invalidData(String(cString: ZSTD_getErrorName(remaining)))
                    }
                    guard input.pos != previous || chunk.pos != 0 else {
                        throw CodecError.invalidData("truncated zstd frame")
                    }
                    output.append(destination.bindMemory(to: UInt8.self).baseAddress!, count: chunk.pos)
                }
            } while input.pos < input.size || remaining != 0
        }
        return output
    }
}

extension ZstdCodec: DestinationDecodingCodec {}
