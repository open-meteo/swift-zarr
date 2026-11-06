import CBlosc
import Foundation

public struct BloscCodec: Codec {
    private let clevel: CInt
    private let shuffle: CInt
    private let typesize: Int
    private let compressorName: String
    private let maxDecodedSize: Int

    /// `maxDecodedSize` bounds allocation when decoding untrusted buffers (256 MiB by default).
    public init(
        clevel: CInt = 5,
        shuffle: CInt = 1,
        typesize: Int = 4,
        compressorName: String = "lz4",
        maxDecodedSize: Int = 256 * 1024 * 1024
    ) {
        self.clevel = clevel
        self.shuffle = shuffle
        self.typesize = typesize
        self.compressorName = compressorName
        self.maxDecodedSize = maxDecodedSize
    }

    public func decode(_ data: Data) throws -> Data {
        var destSize = 0
        let validation = data.withUnsafeBytes { raw in
            // The C validator handles short buffers, but requires a non-null pointer.
            guard let source = raw.baseAddress else { return CInt(-1) }
            return blosc_cbuffer_validate(source, raw.count, &destSize)
        }
        guard validation == 0 else {
            throw BloscError.invalidData("invalid blosc buffer")
        }
        guard destSize <= maxDecodedSize else {
            throw BloscError.invalidData("decoded size exceeds limit of \(maxDecodedSize) bytes")
        }
        // Blosc represents an empty source with a valid header and a decoded size of zero.
        if destSize == 0 { return Data() }
        var output = Data(count: destSize)
        let result = try data.withUnsafeBytes { src in
            try output.withUnsafeMutableBytes { dst in
                guard let srcPtr = src.baseAddress, let dstPtr = dst.baseAddress else {
                    throw BloscError.invalidData("null pointer")
                }
                return blosc_decompress(srcPtr, dstPtr, dst.count)
            }
        }
        guard result > 0, Int(result) == destSize else {
            throw BloscError.decompressFailed(Int(result))
        }
        return output
    }

    public func encode(_ data: Data) throws -> Data {
        let nbytes = data.count
        // BLOSC_MAX_OVERHEAD is 16 bytes; worst-case compressed output is nbytes + 16.
        let destSize = nbytes + 16
        var output = Data(count: destSize)
        let result = try data.withUnsafeBytes { src in
            try output.withUnsafeMutableBytes { dst in
                guard let srcPtr = src.baseAddress, let dstPtr = dst.baseAddress else {
                    throw BloscError.invalidData("null pointer")
                }
                return blosc_compress_ctx(
                    clevel,
                    shuffle,
                    typesize,
                    nbytes,
                    srcPtr,
                    dstPtr,
                    destSize,
                    compressorName,
                    0,
                    1
                )
            }
        }
        guard result > 0 else {
            if result == 0 {
                throw BloscError.compressFailed("output buffer too small")
            }
            throw BloscError.compressFailed("internal error: \(result)")
        }
        output.removeLast(destSize - Int(result))
        return output
    }
}

public enum BloscError: Error, Sendable {
    case invalidData(String)
    case decompressFailed(Int)
    case compressFailed(String)
}
