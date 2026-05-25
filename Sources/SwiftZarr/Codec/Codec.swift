import Foundation

public protocol Codec: Sendable {
    func decode(_ data: Data) throws -> Data
    func encode(_ data: Data) throws -> Data
}
