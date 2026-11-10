import CBlosc
import Foundation

/// V2 LZ4 representation: a little-endian UInt32 decoded length followed by a raw LZ4 block.
public struct LZ4Codec: Codec {
    private let acceleration: Int

    public init(acceleration: Int = 1) {
        self.acceleration = acceleration
    }

    public func decode(_ data: Data) throws -> Data {
        try decode(data, destination: nil)
    }

    internal func decode(_ data: Data, into destination: UnsafeMutableRawBufferPointer) throws {
        _ = try decode(data, destination: destination)
    }

    private func decode(_ data: Data, destination: UnsafeMutableRawBufferPointer?) throws -> Data {
        try decodeBuffer(size: decodedSize(data), into: destination) {
            try decompress(data, into: $0)
        }
    }

    private func decodedSize(_ data: Data) throws -> Int {
        guard data.count >= 5, data.count - 4 <= Int32.max else {
            throw CodecError.invalidData("invalid LZ4 buffer length")
        }
        let size = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard size <= Int32.max else { throw CodecError.invalidData("decoded length exceeds the LZ4 API limit") }
        if size == 0 {
            guard data.count == 5, data.last == 0 else { throw CodecError.invalidData("invalid empty LZ4 block") }
        }
        return Int(size)
    }

    private func decompress(_ data: Data, into destination: UnsafeMutableRawBufferPointer) throws {
        guard !destination.isEmpty else { return }
        let decoded = data.withUnsafeBytes { source in
            LZ4_decompress_safe(
                source.baseAddress!.advanced(by: 4).assumingMemoryBound(to: CChar.self),
                destination.baseAddress!.assumingMemoryBound(to: CChar.self),
                Int32(source.count - 4),
                Int32(destination.count)
            )
        }
        guard decoded == Int32(destination.count) else {
            throw CodecError.invalidData("invalid LZ4 block or decoded length")
        }
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

extension LZ4Codec: DestinationDecodingCodec {}
