import Foundation
import SwiftZarr
import Testing

@Test(arguments: [
    #"{"shape":[-1]}"#, #"{"chunks":[-1]}"#, #"{"shape":[2.5]}"#,
    #"{"chunks":[0]}"#, #"{"chunks":[]}"#, #"{"shape":[]}"#,
    #"{"shape":[18446744073709551615]}"#,
    #"{"shape":[9223372036854775807,2],"chunks":[1,1]}"#,
    #"{"chunks":[9223372036854775807]}"#,
    #"{"zarr_format":3}"#, #"{"dimension_separator":"-"}"#,
])
func testRejectInvalidV2Metadata(patch: String) throws {
    var json: [String: Any] = [
        "zarr_format": 2, "shape": [2], "chunks": [2], "dtype": "<i4", "order": "C",
        "compressor": NSNull(), "fill_value": NSNull(), "filters": NSNull(),
    ]
    json.merge(try JSONSerialization.jsonObject(with: Data(patch.utf8)) as! [String: Any]) { _, new in new }
    let data = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: (any Error).self) {
        let metadata = try JSONDecoder().decode(V2ArrayMetadata.self, from: data)
        return try ZarrArray(metadata: metadata, storage: LocalFileStorage(basePath: "/unused"), path: "")
    }
}

@Test(arguments: [
    #"{"node_type":"group"}"#, #"{"zarr_format":2}"#,
    #"{"chunk_grid":{"name":"unknown","configuration":{"chunk_shape":[2]}}}"#,
    #"{"dimension_names":[]}"#,
    #"{"storage_transformers":[{"name":"unknown"}]}"#,
    #"{"shape":[18446744073709551615]}"#,
    #"{"chunk_grid":{"name":"regular","configuration":{"chunk_shape":[0]}}}"#,
    #"{"chunk_grid":{"name":"regular","configuration":{"chunk_shape":[]}}}"#,
    #"{"chunk_key_encoding":{"name":"unknown"}}"#,
])
func testRejectInvalidV3Metadata(patch: String) throws {
    var json: [String: Any] = [
        "zarr_format": 3, "node_type": "array", "shape": [2], "data_type": "int32", "fill_value": 0,
        "chunk_grid": ["name": "regular", "configuration": ["chunk_shape": [2]]],
        "chunk_key_encoding": ["name": "default", "configuration": ["separator": "/"]],
        "codecs": [["name": "bytes", "configuration": ["endian": "little"]]],
    ]
    json.merge(try JSONSerialization.jsonObject(with: Data(patch.utf8)) as! [String: Any]) { _, new in new }
    let metadata = try JSONDecoder().decode(V3ArrayMetadata.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(throws: ZarrArrayError.self) {
        try ZarrArray(metadata: metadata, storage: LocalFileStorage(basePath: "/unused"), path: "")
    }
}

@Test
func testV2RequiredNullableFields() throws {
    let metadata = V2ArrayMetadata(shape: [1], chunks: [1], dtype: "<i4")
    let encoded = try JSONEncoder().encode(metadata)
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let decoded = try JSONDecoder().decode(V2ArrayMetadata.self, from: encoded)
    #expect(decoded.compressor == nil)
    #expect(decoded.fillValue == nil)
    #expect(decoded.filters == nil)
    for key in ["compressor", "fill_value", "filters"] {
        #expect(json[key] is NSNull)
        var missing = json
        missing.removeValue(forKey: key)
        let data = try JSONSerialization.data(withJSONObject: missing)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(V2ArrayMetadata.self, from: data)
        }
    }
}

@Test
func testV3RequiredMetadataFields() throws {
    let metadata = V3ArrayMetadata(
        shape: [2],
        dataType: "int32",
        chunkGrid: .init(configuration: .init(chunkShape: [2])),
        fillValue: .int(0),
        codecs: [.init(name: "bytes", configuration: ["endian": .string("little")])]
    )
    let encoded = try JSONEncoder().encode(metadata)
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    for key in ["chunk_key_encoding", "fill_value", "codecs"] {
        #expect(json[key] != nil)
        var missing = json
        missing.removeValue(forKey: key)
        let data = try JSONSerialization.data(withJSONObject: missing)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(V3ArrayMetadata.self, from: data)
        }
    }
    for key in ["chunk_key_encoding", "codecs"] {
        var null = json
        null[key] = NSNull()
        let data = try JSONSerialization.data(withJSONObject: null)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(V3ArrayMetadata.self, from: data)
        }
    }
}

@Test
func testEmptyAndLargeRepresentableShapes() throws {
    let shapes: [[UInt64]] = [[UInt64(Int.max), UInt64(Int.max), 0], [UInt64(Int.max)], []]
    for shape in shapes {
        let metadata = V2ArrayMetadata(
            zarrFormat: 2,
            shape: shape,
            chunks: shape.map { _ in 1 },
            dtype: "<i4",
            compressor: nil,
            fillValue: nil,
            order: .C,
            filters: nil,
            dimensionSeparator: nil
        )
        let array = try ZarrArray(metadata: metadata, storage: LocalFileStorage(basePath: "/unused"), path: "")
        #expect(array.totalElements == (shape.isEmpty ? 1 : shape.contains(0) ? 0 : Int.max))
    }
}

@Test
func testLargeChunkGridCeilingDivision() throws {
    let metadata = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [UInt64(Int.max)],
        chunks: [2],
        dtype: "|u1",
        compressor: nil,
        fillValue: nil,
        filters: nil,
        dimensionSeparator: nil
    )
    let array = try ZarrArray(metadata: metadata, storage: LocalFileStorage(basePath: "/unused"), path: "")
    #expect(array.chunkGridShape() == [Int.max / 2 + 1])
}

@Test
func testLargeArraySupportsSmallSubset() async throws {
    let path = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let array = try ZarrArray(
        metadata: V2ArrayMetadata(shape: [UInt64(Int.max)], chunks: [1], dtype: "<i4"),
        storage: LocalFileStorage(basePath: path),
        path: ""
    )
    let last: [Int32] = try await array.retrieveArraySubset([Int.max - 1..<Int.max])
    #expect(last == [0])
    await #expect(throws: ZarrArrayError.self) {
        let _: [Int32] = try await array.retrieveArraySubset([0..<Int.max])
    }
}
