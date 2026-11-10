import CBlosc
import Foundation

public struct BloscCodec: Codec {
    private let clevel: CInt
    private let shuffle: CInt
    private let typesize: Int
    private let compressorName: String
    private let blockSize: Int

    public init(
        clevel: CInt = 5,
        shuffle: CInt = 1,
        typesize: Int = 4,
        compressorName: String = "lz4",
        blockSize: Int = 0
    ) {
        self.clevel = clevel
        self.shuffle = shuffle
        self.typesize = typesize
        self.compressorName = compressorName
        self.blockSize = blockSize
    }

    public func decode(_ data: Data) throws -> Data {
        var output = Data(count: try decodedSize(data))
        try output.withUnsafeMutableBytes { try decompress(data, into: $0) }
        return output
    }

    internal func decode(_ data: Data, into destination: UnsafeMutableRawBufferPointer) throws {
        guard try decodedSize(data) == destination.count else {
            // Validate the compressed payload before reporting a size mismatch.
            let size = try decode(data).count
            throw ZarrArrayError.invalidDataSize(expected: destination.count, got: size)
        }
        try decompress(data, into: destination)
    }

    private func decodedSize(_ data: Data) throws -> Int {
        var size = 0
        let validation = data.withUnsafeBytes { raw in
            guard let source = raw.baseAddress else { return CInt(-1) }
            return blosc_cbuffer_validate(source, raw.count, &size)
        }
        guard validation == 0 else { throw BloscError.invalidData("invalid blosc buffer") }
        return size
    }

    private func decompress(_ data: Data, into destination: UnsafeMutableRawBufferPointer) throws {
        // A valid Blosc header with zero decoded bytes represents an empty source.
        guard !destination.isEmpty else { return }
        let result = try data.withUnsafeBytes { source in
            guard let src = source.baseAddress, let dst = destination.baseAddress else {
                throw BloscError.invalidData("null pointer")
            }
            return blosc_decompress(src, dst, destination.count)
        }
        guard result > 0, Int(result) == destination.count else {
            throw BloscError.decompressFailed(Int(result))
        }
    }

    public func encode(_ data: Data) throws -> Data {
        try Self.validateBlockSize(blockSize)
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
                    blockSize,
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

    internal static func validateBlockSize(_ blockSize: Int) throws {
        // c-blosc narrows the size_t argument to a signed 32-bit integer.
        guard blockSize >= 0, Int32(exactly: blockSize) != nil else {
            throw BloscError.compressFailed("block size must be in 0...Int32.max")
        }
    }
}

public enum BloscError: Error, Sendable {
    case invalidData(String)
    case decompressFailed(Int)
    case compressFailed(String)
}

extension BloscCodec: DestinationDecodingCodec {}
