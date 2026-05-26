import Foundation
@preconcurrency import SWCompression

public struct BZip2Codec: Codec {
    private let blockSize: BZip2.BlockSize

    public init(level: Int = 5) {
        let clamped = max(1, min(level, 9))
        self.blockSize = BZip2.BlockSize(rawValue: clamped) ?? .five
    }

    public func decode(_ data: Data) throws -> Data {
        let bytes = try BZip2.decompress(data: data)
        return Data(bytes)
    }

    public func encode(_ data: Data) throws -> Data {
        let bytes = BZip2.compress(data: data, blockSize: blockSize)
        return Data(bytes)
    }
}
