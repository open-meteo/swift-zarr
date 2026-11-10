import Foundation

public protocol Codec: Sendable {
    func decode(_ data: Data) throws -> Data
    func encode(_ data: Data) throws -> Data
}

/// Synchronously fills every destination byte on success; never retains its pointer.
/// Decoding failures propagate before decoded-size validation.
internal protocol DestinationDecodingCodec: Codec {
    func decode(_ data: Data, into destination: UnsafeMutableRawBufferPointer) throws
}

public enum CodecError: Error, Sendable {
    case invalidData(String)
    case encodeFailed(String)
}
