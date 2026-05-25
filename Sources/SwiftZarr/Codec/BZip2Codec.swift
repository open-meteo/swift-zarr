import Foundation
import SWCompression

public struct BZip2Codec: Codec {
    private let level: Int

    public init(level: Int = 5) {
        self.level = level
    }

    public func decode(_ data: Data) throws -> Data {
        let bytes = try BZip2.decompress(data: data)
        return Data(bytes)
    }

    public func encode(_ data: Data) throws -> Data {
        let bytes = BZip2.compress(data: data)
        return Data(bytes)
    }
}
