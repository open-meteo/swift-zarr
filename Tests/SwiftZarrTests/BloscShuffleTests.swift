import Foundation
import Testing

@testable import SwiftZarr

private func bloscShufflePipeline(version: Int, config: [String: ZarrJSONValue]) throws -> CodecPipeline {
    let dtype = try ZarrDataType.parse("<i4")
    if version == 2 {
        let metadata = V2ArrayMetadata(
            zarrFormat: 2,
            shape: [1024],
            chunks: [1024],
            dtype: "<i4",
            compressor: config.merging(["id": .string("blosc")]) { _, new in new },
            fillValue: nil,
            filters: nil,
            dimensionSeparator: nil
        )
        return try CodecPipeline(v2: metadata, dataType: dtype)
    }
    return try CodecPipeline(
        v3: [
            .init(name: "bytes", configuration: ["endian": .string("little")]),
            .init(name: "blosc", configuration: config),
        ],
        dataType: dtype
    )
}

@Test(arguments: [(0, 4, 0), (1, 4, 1), (2, 4, 4), (-1, 1, 4), (-1, 4, 1)])
func testV2BloscShuffleModes(mode: Int, typesize: Int, flags: Int) throws {
    let pipeline = try bloscShufflePipeline(
        version: 2,
        config: ["shuffle": .int(Int64(mode)), "typesize": .int(Int64(typesize))]
    )
    let source = Data(repeating: 7, count: 4096)
    let encoded = try pipeline.encode(source)
    #expect(Int(encoded[2] & 5) == flags)
    #expect(try pipeline.decode(encoded) == source)
    let decoder = try #require(pipeline.destinationDecoder)
    var destination = Data(count: source.count)
    try destination.withUnsafeMutableBytes { try decoder.decode(encoded, into: $0) }
    #expect(destination == source)
}

@Test(arguments: [("noshuffle", 0), ("shuffle", 1), ("bitshuffle", 4)])
func testV3BloscShuffleModes(mode: String, flags: Int) throws {
    let pipeline = try bloscShufflePipeline(version: 3, config: ["shuffle": .string(mode), "typesize": .int(4)])
    let source = Data(repeating: 7, count: 4096)
    let encoded = try pipeline.encode(source)
    #expect(Int(encoded[2] & 5) == flags)
    #expect(try pipeline.decode(encoded) == source)
    let decoder = try #require(pipeline.destinationDecoder)
    var destination = Data(count: source.count)
    try destination.withUnsafeMutableBytes { try decoder.decode(encoded, into: $0) }
    #expect(destination == source)
}

@Test(arguments: [
    #"{"shuffle":1,"typesize":4}"#,
    #"{"shuffle":"unknown","typesize":4}"#,
    #"{"shuffle":"shuffle"}"#,
    #"{"shuffle":"bitshuffle","typesize":0}"#,
    #"{"shuffle":"shuffle","typesize":"4"}"#,
])
func testRejectInvalidV3BloscShuffle(json: String) throws {
    let config = try JSONDecoder().decode([String: ZarrJSONValue].self, from: Data(json.utf8))
    #expect(throws: ZarrArrayError.self) { try bloscShufflePipeline(version: 3, config: config) }
}

@Test(arguments: [
    #"{"shuffle":-2}"#, #"{"shuffle":3}"#, #"{"shuffle":"shuffle"}"#,
    #"{"shuffle":1,"typesize":256}"#,
])
func testRejectInvalidV2BloscShuffle(json: String) throws {
    let config = try JSONDecoder().decode([String: ZarrJSONValue].self, from: Data(json.utf8))
    #expect(throws: ZarrArrayError.self) { try bloscShufflePipeline(version: 2, config: config) }
}
