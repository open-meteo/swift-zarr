import Foundation
import SWCompression

public struct ZlibCodec: Codec {
    private let level: Int

    public init(level: Int = 5) {
        self.level = level
    }

    public func decode(_ data: Data) throws -> Data {
        let bytes = try ZlibArchive.unarchive(archive: data)
        return Data(bytes)
    }

    public func encode(_ data: Data) throws -> Data {
        let bytes = ZlibArchive.archive(data: data)
        return Data(bytes)
    }
}
