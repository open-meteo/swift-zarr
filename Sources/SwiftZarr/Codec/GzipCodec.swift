import Foundation
import SWCompression

public struct GzipCodec: Codec {
    public init() {}

    public func decode(_ data: Data) throws -> Data {
        let bytes = try GzipArchive.unarchive(archive: data)
        return Data(bytes)
    }

    public func encode(_ data: Data) throws -> Data {
        let bytes = try GzipArchive.archive(data: data)
        return Data(bytes)
    }
}
