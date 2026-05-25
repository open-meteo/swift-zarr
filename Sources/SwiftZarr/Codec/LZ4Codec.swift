import Foundation
import SWCompression

public struct LZ4Codec: Codec {
    public init() {}

    public func decode(_ data: Data) throws -> Data {
        try LZ4.decompress(data: data)
    }

    public func encode(_ data: Data) throws -> Data {
        LZ4.compress(data: data)
    }
}
