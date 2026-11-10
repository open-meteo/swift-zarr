import Foundation

public struct GzipCodec: Codec {
    private let level: Int

    public init(level: Int = 6) {
        self.level = level
    }

    public func decode(_ data: Data) throws -> Data {
        try DeflateCodec.decode(data, windowBits: 31)
    }

    internal func decode(_ data: Data, into destination: UnsafeMutableRawBufferPointer) throws {
        try DeflateCodec.decode(data, windowBits: 31, into: destination)
    }

    public func encode(_ data: Data) throws -> Data {
        try DeflateCodec.encode(data, windowBits: 31, level: level)
    }
}

extension GzipCodec: DestinationDecodingCodec {}
