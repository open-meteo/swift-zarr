import Foundation
import Testing
import libzstd

@testable import SwiftZarr

@Test(arguments: [-3, 0, 22])
func testZstdRoundTrip(level: Int) throws {
    let codec = ZstdCodec(level: level)
    let data = Data(repeating: 42, count: 300_000)
    #expect(try codec.decode(codec.encode(data)) == data)
}

@Test(arguments: [false, true])
func testZstdChecksumFlag(checksum: Bool) throws {
    let codec = ZstdCodec(checksum: checksum)
    for data in [Data(), Data("hello zstd".utf8)] {
        let encoded = try codec.encode(data)
        try #require(encoded.count >= 5)
        #expect(Array(encoded.prefix(4)) == [0x28, 0xb5, 0x2f, 0xfd])
        // Bit 2 of the Zstandard frame header descriptor signals the content checksum.
        #expect((encoded[4] & 0x04 != 0) == checksum)
        #expect(try codec.decode(encoded) == data)
    }
}

@Test
func testZstdFramesAndCorruption() throws {
    let codec = ZstdCodec(checksum: true)
    let data = Data(repeating: 42, count: 300_000)
    let encoded = try codec.encode(data)
    #expect(try codec.decode(encoded + encoded) == data + data)
    var corrupt = encoded
    corrupt[corrupt.count - 1] ^= 1
    for invalid in [Data(), Data([1, 2, 3]), Data(encoded.dropLast()), corrupt, encoded + Data([0])] {
        #expect(throws: CodecError.self) { try codec.decode(invalid) }
        var destination = Data(count: data.count)
        #expect(throws: CodecError.self) {
            try destination.withUnsafeMutableBytes { try codec.decode(invalid, into: $0) }
        }
    }
    // Bypass the Swift encoder to exercise a frame without a content-size field.
    let context = try #require(ZSTD_createCCtx())
    defer { ZSTD_freeCCtx(context) }
    try #require(ZSTD_CCtx_setParameter(context, ZSTD_c_contentSizeFlag, 0) == 0)
    var frame = Data(count: ZSTD_compressBound(data.count))
    let count = data.withUnsafeBytes { src in
        frame.withUnsafeMutableBytes { dst in
            ZSTD_compress2(context, dst.baseAddress, dst.count, src.baseAddress, src.count)
        }
    }
    try #require(ZSTD_isError(count) == 0)
    frame.count = count
    #expect(try codec.decode(frame) == data)
    for input in [encoded, frame, encoded + encoded, encoded + (try codec.encode(Data()))] {
        let expected = try codec.decode(input)
        var destination = Data(count: expected.count)
        try destination.withUnsafeMutableBytes { try codec.decode(input, into: $0) }
        #expect(destination == expected)
        for size in [0, expected.count - 1, expected.count + 1] {
            var wrongSize = Data(count: size)
            #expect(throws: ZarrArrayError.invalidDataSize(expected: size, got: expected.count)) {
                try wrongSize.withUnsafeMutableBytes { try codec.decode(input, into: $0) }
            }
        }
    }
}

@Test(arguments: [ZarrVersion.v2, .v3])
func testZstdArrayWriteRead(version: ZarrVersion) async throws {
    let directory = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let storage = LocalFileStorage(basePath: directory)
    let config: [String: ZarrJSONValue] = ["level": .int(-3), "checksum": .bool(true)]
    let array: ZarrArray
    switch version {
    case .v2:
        let metadata = V2ArrayMetadata(
            shape: [8],
            chunks: [8],
            dtype: "|u1",
            compressor: config.merging(["id": .string("zstd")]) { a, _ in a }
        )
        array = try ZarrArray(metadata: metadata, storage: storage, path: "")
    case .v3:
        let metadata = V3ArrayMetadata(
            shape: [8],
            dataType: "uint8",
            chunkGrid: .init(configuration: .init(chunkShape: [8])),
            fillValue: .int(0),
            codecs: [V3Codec(name: "bytes"), V3Codec(name: "zstd", configuration: config)]
        )
        array = try ZarrArray(metadata: metadata, storage: storage, path: "")
    }
    let values: [UInt8] = Array(0..<8)
    try await array.storeMetadata()
    try await array.storeChunk([0], data: Data(values))
    let encoded = try await storage.read(path: array.chunkKey([0]))
    try #require(encoded.count >= 5)
    #expect(encoded[4] & 0x04 != 0)
    let reopened = try await ZarrArray(storage: storage, path: "")
    let decoded: [UInt8] = try await reopened.retrieveChunk([0])
    #expect(decoded == values)
}

@Test
func testBloscZstdWriteRead() throws {
    let data = Data(repeating: 42, count: 4096)
    let codec = BloscCodec(compressorName: "zstd")
    #expect(try codec.decode(codec.encode(data)) == data)
}

@Test(arguments: [Int.min, Int.max, 23])
func testZstdInvalidLevel(level: Int) {
    #expect(throws: CodecError.self) { try ZstdCodec(level: level).encode(Data([1])) }
}

@Test(arguments: [
    ["level": ZarrJSONValue.string("3")],
    ["level": .int(23)],
    ["checksum": .int(1)],
])
func testZstdInvalidConfiguration(config: [String: ZarrJSONValue]) throws {
    let type = try ZarrDataType.parse("|u1")
    #expect(throws: ZarrArrayError.self) {
        try CodecPipeline(
            v3: [V3Codec(name: "bytes"), V3Codec(name: "zstd", configuration: config)],
            dataType: type
        )
    }
}
