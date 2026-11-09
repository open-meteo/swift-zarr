import Foundation

public struct ZlibCodec: Codec {
    private let level: Int

    public init(level: Int = 6) {
        self.level = level
    }

    public func decode(_ data: Data) throws -> Data {
        try DeflateCodec.decode(data, windowBits: 15)
    }

    public func encode(_ data: Data) throws -> Data {
        try DeflateCodec.encode(data, windowBits: 15, level: level)
    }
}
