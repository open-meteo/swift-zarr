import Foundation
import Testing

@testable import SwiftZarr

@Test
func testV2Filters() throws {
    let cases: [[[String: ZarrJSONValue]]?] = [nil, [], [["id": .string("delta")]], [[:]]]
    for filters in cases {
        let metadata = V2ArrayMetadata(
            zarrFormat: 2,
            shape: [2],
            chunks: [2],
            dtype: "<i4",
            compressor: nil,
            fillValue: nil,
            order: .C,
            filters: filters,
            dimensionSeparator: nil
        )
        let storage = LocalFileStorage(basePath: NSTemporaryDirectory())
        if filters?.isEmpty == false {
            #expect(throws: ZarrArrayError.unsupportedFilters) {
                try ZarrArray(metadata: metadata, storage: storage, path: "array")
            }
        } else {
            _ = try ZarrArray(metadata: metadata, storage: storage, path: "array")
        }
    }
}

@Test
func testInvalidV3CodecPipelines() throws {
    let bytes = V3Codec(name: "bytes", configuration: ["endian": .string("little")])
    let gzip = V3Codec(name: "gzip", configuration: nil)
    let cases: [([V3Codec], ZarrArrayError)] = [
        ([], .invalidCodecConfiguration("A serializer is required")),
        ([gzip], .invalidCodecConfiguration("Compression must follow the serializer")),
        ([gzip, bytes], .invalidCodecConfiguration("Compression must follow the serializer")),
        ([bytes, bytes], .invalidCodecConfiguration("Only one serializer is allowed")),
        ([bytes, gzip, bytes], .invalidCodecConfiguration("Only one serializer is allowed")),
        ([.init(name: "transpose", configuration: nil), bytes], .unsupportedCompressor("transpose")),
        ([bytes, .init(name: "unknown", configuration: nil)], .unsupportedCompressor("unknown")),
        (
            [.init(name: "bytes", configuration: nil)],
            .invalidCodecConfiguration("bytes: endian must be little or big")
        ),
        (
            [.init(name: "bytes", configuration: ["endian": .string("native")])],
            .invalidCodecConfiguration("bytes: endian must be little or big")
        ),
    ]
    let dataType = try ZarrDataType.parseV3("int32")
    for (codecs, error) in cases {
        #expect(throws: error) { try CodecPipeline(v3: codecs, dataType: dataType) }
    }
}

@Test
func testCodecPipelineCompressionOrder() throws {
    let pipeline = try CodecPipeline(
        v3: [
            .init(name: "bytes", configuration: ["endian": .string("big")]),
            .init(name: "gzip", configuration: nil),
            .init(name: "zlib", configuration: nil),
        ],
        dataType: ZarrDataType.parseV3("int32")
    )
    #expect(pipeline.serializer.endian == .big)
    let raw = Data([0, 0, 0, 1, 0, 0, 1, 0])
    let encoded = try pipeline.encode(raw)
    #expect(try GzipCodec().decode(ZlibCodec().decode(encoded)) == raw)
    let independent = try ZlibCodec().encode(GzipCodec().encode(raw))
    #expect(try pipeline.decode(independent) == raw)
}

@Test
func testSingleByteSerializerNeedsNoEndian() throws {
    let pipeline = try CodecPipeline(
        v3: [.init(name: "bytes", configuration: nil)],
        dataType: ZarrDataType.parseV3("uint8")
    )
    #expect(pipeline.serializer.endian == .none)
    let raw = Data([1, 2, 3])
    #expect(try pipeline.decode(raw) == raw)
    #expect(try pipeline.encode(raw) == raw)
}

@Test(
    arguments: ["little", "big"],
    [
        [V3Codec(name: "zstd")], [.init(name: "gzip")], [.init(name: "zlib")], [.init(name: "lz4")],
        [.init(name: "blosc", configuration: ["shuffle": .string("shuffle"), "typesize": .int(4)])],
        [.init(name: "blosc", configuration: ["shuffle": .string("bitshuffle"), "typesize": .int(4)])],
        [.init(name: "bz2")], [], [.init(name: "gzip"), .init(name: "zlib")],
    ]
)
func testWholeChunkFloatSubset(endian: String, compressors: [V3Codec]) async throws {
    let directory = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let storage = LocalFileStorage(basePath: directory)
    let codecs = [V3Codec(name: "bytes", configuration: ["endian": .string(endian)])] + compressors
    let pipeline = try CodecPipeline(v3: codecs, dataType: ZarrDataType.parseV3("float32"))
    let array = try ZarrArray(
        metadata: V3ArrayMetadata(
            shape: [2, 3],
            dataType: "float32",
            chunkGrid: .init(configuration: .init(chunkShape: [2, 3])),
            fillValue: .int(7),
            codecs: codecs
        ),
        storage: storage,
        path: ""
    )
    let missing: [Float] = try await array.retrieveArraySubset([0..<2, 0..<3])
    #expect(missing == Array(repeating: 7, count: 6))
    let bits: [UInt32] = [0, 0x8000_0000, 0x3f80_0000, 0x7f80_0000, 0x7fc0_1234, 0xc020_0000]
    let words = bits.map { endian == "little" ? $0.littleEndian : $0.bigEndian }
    let bytes = words.withUnsafeBytes { Data($0) }
    try await array.storeChunk([0, 0], data: bytes)
    let values: [Float] = try await array.retrieveArraySubset([0..<2, 0..<3])
    #expect(values.map(\.bitPattern) == bits)
    let partial: [Float] = try await array.retrieveArraySubset([1..<2, 0..<3])
    #expect(partial.map(\.bitPattern) == Array(bits[3...]))
    for invalid in [Data(bytes.dropLast()), bytes + Data([0])] {
        try await storage.write(path: array.chunkKey([0, 0]), data: pipeline.encode(invalid))
        await #expect(throws: ZarrArrayError.invalidDataSize(expected: bytes.count, got: invalid.count)) {
            let _: [Float] = try await array.retrieveArraySubset([0..<2, 0..<3])
        }
    }
}
