import CBlosc
import Foundation

/// V2 LZ4 representation: a little-endian UInt32 decoded length followed by a raw LZ4 block.
public struct LZ4Codec: Codec {
    private let acceleration: Int

    public init(acceleration: Int = 1) {
        self.acceleration = acceleration
    }

    public func decode(_ data: Data) throws -> Data {
        guard data.count >= 5, data.count - 4 <= Int32.max else {
            throw CodecError.invalidData("invalid LZ4 buffer length")
        }
        let size = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard size <= Int32.max else { throw CodecError.invalidData("decoded length exceeds the LZ4 API limit") }
        if size == 0 {
            guard data.count == 5, data.last == 0 else { throw CodecError.invalidData("invalid empty LZ4 block") }
            return Data()
        }
        var output = Data(count: Int(size))
        let decoded = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                LZ4_decompress_safe(
                    source.baseAddress!.advanced(by: 4).assumingMemoryBound(to: CChar.self),
                    destination.baseAddress!.assumingMemoryBound(to: CChar.self),
                    Int32(source.count - 4),
                    Int32(size)
                )
            }
        }
        guard decoded == Int32(size) else { throw CodecError.invalidData("invalid LZ4 block or decoded length") }
        return output
    }

    public func encode(_ data: Data) throws -> Data {
        guard (1...Int(Int32.max)).contains(acceleration), data.count <= LZ4_MAX_INPUT_SIZE else {
            throw CodecError.encodeFailed("invalid LZ4 acceleration or input size")
        }
        if data.isEmpty { return Data([0, 0, 0, 0, 0]) }
        let capacity = Int(LZ4_compressBound(Int32(data.count)))
        var output = Data(count: capacity + 4)
        let encoded = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                destination.storeBytes(of: UInt32(data.count).littleEndian, as: UInt32.self)
                return LZ4_compress_fast(
                    source.baseAddress!.assumingMemoryBound(to: CChar.self),
                    destination.baseAddress!.advanced(by: 4).assumingMemoryBound(to: CChar.self),
                    Int32(source.count),
                    Int32(capacity),
                    Int32(acceleration)
                )
            }
        }
        guard encoded > 0 else { throw CodecError.encodeFailed("LZ4 compression failed") }
        output.removeLast(capacity - Int(encoded))
        return output
    }
}
