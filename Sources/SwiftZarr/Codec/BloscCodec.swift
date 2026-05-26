import CBlosc
import Foundation

public struct BloscCodec: Codec {
    private let clevel: CInt
    private let shuffle: CInt
    private let typesize: Int
    private let compressorName: String

    public init(
        clevel: CInt = 5,
        shuffle: CInt = 1,
        typesize: Int = 4,
        compressorName: String = "lz4"
    ) {
        self.clevel = clevel
        self.shuffle = shuffle
        self.typesize = typesize
        self.compressorName = compressorName
    }

    public func decode(_ data: Data) throws -> Data {
        guard data.count >= 16 else {
            throw BloscError.invalidData("data too short for blosc header")
        }
        let destSize = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        }
        var output = Data(count: Int(destSize))
        let result = try data.withUnsafeBytes { src in
            try output.withUnsafeMutableBytes { dst in
                guard let srcPtr = src.baseAddress, let dstPtr = dst.baseAddress else {
                    throw BloscError.invalidData("null pointer")
                }
                return blosc_decompress(srcPtr, dstPtr, dst.count)
            }
        }
        guard result >= 0 else {
            throw BloscError.decompressFailed(Int(result))
        }
        return output
    }

    public func encode(_ data: Data) throws -> Data {
        let nbytes = data.count
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
