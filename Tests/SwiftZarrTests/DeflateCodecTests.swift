import CBlosc
import Foundation
import SWCompression
import Testing

@testable import SwiftZarr

@Test(arguments: [false, true])
func testDeflateEncodingAndLevels(gzip: Bool) throws {
    let data = Data(repeating: 42, count: 200_000)
    let raw: any Codec = gzip ? GzipCodec(level: 0) : ZlibCodec(level: 0)
    let compressed: any Codec = gzip ? GzipCodec(level: 9) : ZlibCodec(level: 9)
    let encoded = try compressed.encode(data)
    #expect(try encoded.count < raw.encode(data).count)
    // Decode Swift's output with the previous, independent implementation.
    let decoded = try gzip ? GzipArchive.unarchive(archive: encoded) : ZlibArchive.unarchive(archive: encoded)
    #expect(Data(decoded) == data)
    #expect(try compressed.decode(encoded) == data)
    #expect(try compressed.decode(compressed.encode(Data())).isEmpty)
    for invalid in [Data(), Data([1, 2, 3]), Data(encoded.dropLast()), encoded + Data([0])] {
        #expect(throws: CodecError.self) { try compressed.decode(invalid) }
    }
    var corrupt = encoded
    corrupt[corrupt.count - 1] ^= 1
    #expect(throws: CodecError.self) { try compressed.decode(corrupt) }
    if gzip { #expect(try compressed.decode(encoded + encoded) == data + data) }
}

@Test(arguments: ["gzip", "zlib"])
func testDeflatePipelineLevel(name: String) throws {
    let data = Data(repeating: 42, count: 4096)
    let type = try ZarrDataType.parse("|u1")
    func pipeline(_ level: ZarrJSONValue) throws -> CodecPipeline {
        try CodecPipeline(
            v3: [.init(name: "bytes"), .init(name: name, configuration: ["level": level])],
            dataType: type
        )
    }
    #expect(try pipeline(.int(9)).encode(data).count < pipeline(.int(0)).encode(data).count)
    for value in [ZarrJSONValue.int(-1), .int(10), .string("6"), .bool(true)] {
        #expect(throws: ZarrArrayError.self) { try pipeline(value) }
    }
}

@Test(arguments: [Int.min, -2, 10, Int.max])
func testDeflateRejectsInvalidLevel(level: Int) {
    #expect(throws: CodecError.self) { try GzipCodec(level: level).encode(Data()) }
    #expect(throws: CodecError.self) { try ZlibCodec(level: level).encode(Data()) }
}

@Test
func testBloscCompiledCompressors() throws {
    let compressors = String(cString: blosc_list_compressors()).split(separator: ",")
    for name in ["lz4", "zstd", "zlib"] {
        #expect(compressors.contains(Substring(name)))
        let codec = BloscCodec(compressorName: name)
        let data = Data(repeating: 42, count: 4096)
        let encoded = try codec.encode(data)
        #expect(encoded.count < data.count)
        #expect(try codec.decode(encoded) == data)
    }
}

@Test
func testV2ZlibDefaultCompressionLevel() async throws {
    let directory = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let storage = LocalFileStorage(basePath: directory)
    let metadata = V2ArrayMetadata(
        shape: [8],
        chunks: [8],
        dtype: "|u1",
        compressor: ["id": .string("zlib"), "level": .int(-1)]
    )
    let array = try ZarrArray(metadata: metadata, storage: storage, path: "")
    let values: [UInt8] = Array(0..<8)
    try await array.storeMetadata()
    try await array.storeChunk([0], data: Data(values))
    let encoded = try await storage.read(path: array.chunkKey([0]))
    #expect(try Data(ZlibArchive.unarchive(archive: encoded)) == Data(values))
    #expect(try ZlibCodec(level: -1).encode(Data(values)) == encoded)
    let reopened = try await ZarrArray(storage: storage, path: "")
    let decoded: [UInt8] = try await reopened.retrieveChunk([0])
    #expect(decoded == values)
    #expect(throws: CodecError.self) { try GzipCodec(level: -1).encode(Data()) }
}
