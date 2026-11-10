import Foundation
import Testing

@testable import SwiftZarr

@Test
func testLZ4BlockRepresentation() throws {
    // Three decoded bytes, followed by a raw block containing three literals.
    let encoded = Data([3, 0, 0, 0, 0x30, 97, 98, 99])
    let decoded = Data("abc".utf8)
    let codec = LZ4Codec(acceleration: 3)
    #expect(try codec.decode(encoded) == decoded)
    #expect(try codec.encode(decoded) == encoded)
    #expect(try codec.encode(Data()) == Data([0, 0, 0, 0, 0]))
    #expect(try codec.decode(Data([0, 0, 0, 0, 0])).isEmpty)
}

@Test(arguments: [
    Data(), Data([1, 0, 0, 0]), Data([255, 255, 255, 255, 0]),
    Data([0, 0, 0, 0, 1]), Data([0, 0, 0, 0, 0, 0]),
    Data([3, 0, 0, 0, 0x30, 97, 98]),
    Data([2, 0, 0, 0, 0x30, 97, 98, 99]),
    Data([4, 0, 0, 0, 0x30, 97, 98, 99]),
])
func testRejectMalformedLZ4Blocks(encoded: Data) {
    #expect(throws: CodecError.self) { try LZ4Codec().decode(encoded) }
    var destination = Data(count: 3)
    #expect(throws: CodecError.self) {
        try destination.withUnsafeMutableBytes { try LZ4Codec().decode(encoded, into: $0) }
    }
}

@Test(arguments: [-1, 0, Int(Int32.max) + 1])
func testRejectInvalidLZ4Acceleration(acceleration: Int) {
    #expect(throws: CodecError.self) {
        try LZ4Codec(acceleration: acceleration).encode(Data([1]))
    }
}

@Test(arguments: [
    ZarrJSONValue.int(0), .int(-1), .int(Int64(Int32.max) + 1), .string("3"), .double(1.5),
])
func testRejectInvalidLZ4Metadata(acceleration: ZarrJSONValue) {
    let metadata = V2ArrayMetadata(
        shape: [1],
        chunks: [1],
        dtype: "|u1",
        compressor: ["id": .string("lz4"), "acceleration": acceleration]
    )
    #expect(throws: ZarrArrayError.self) {
        try ZarrArray(metadata: metadata, storage: LocalFileStorage(basePath: "/unused"), path: "")
    }
}
