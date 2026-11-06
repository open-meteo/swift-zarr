import Foundation
import Testing

@testable import SwiftZarr

@Test(arguments: ["little", "big"])
func testV3MetadataInteroperability(endian: String) async throws {
    // Written independently of our encoder, using the V3 specification's field names.
    let json = Data(
        """
        {
            "zarr_format": 3, "node_type": "array",
            "shape": [1, 2], "data_type": "int32",
            "chunk_grid": {"name": "regular", "configuration": {"chunk_shape": [1, 2]}},
            "chunk_key_encoding": {"name": "default", "configuration": {"separator": "/"}},
            "codecs": [{"name": "bytes", "configuration": {"endian": "\(endian)"}}],
            "fill_value": 0, "dimension_names": ["rows", null]
        }
        """.utf8
    )
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let storage = LocalFileStorage(basePath: tmp)
    try await storage.write(path: "array/zarr.json", data: json)
    let bytes: [UInt8] = endian == "little" ? [1, 0, 0, 0, 0, 1, 0, 0] : [0, 0, 0, 1, 0, 0, 1, 0]
    try await storage.write(path: "array/c/0/0", data: Data(bytes))

    let array = try await ZarrArray(storage: storage, path: "array")
    #expect(array.shape == [1, 2])
    #expect(array.chunkShape == [1, 2])
    let values: [Int32] = try await array.retrieveArraySubset([0..<1, 0..<2])
    #expect(values == [1, 256])

    try await array.storeMetadata()
    let saved = try await storage.read(path: "array/zarr.json")
    let originalJSON = try JSONSerialization.jsonObject(with: json) as! NSDictionary
    let savedJSON = try JSONSerialization.jsonObject(with: saved) as! NSDictionary
    #expect(savedJSON == originalJSON)
    let reopened = try await ZarrArray(storage: storage, path: "array")
    let reread: [Int32] = try await reopened.retrieveChunk([0, 0])
    #expect(reread == values)
}

@Test(arguments: [
    ("bool", "|b1"),
    ("int8", "|i1"), ("int16", "<i2"), ("int32", "<i4"), ("int64", "<i8"),
    ("uint8", "|u1"), ("uint16", "<u2"), ("uint32", "<u4"), ("uint64", "<u8"),
    ("float16", "<f2"), ("float32", "<f4"), ("float64", "<f8"),
    ("complex64", "<c8"), ("complex128", "<c16"),
])
func testV3NumericTypeMapping(name: String, dtype: String) throws {
    #expect(try ZarrDataType.parseV3(name) == ZarrDataType.parse(dtype))
}

@Test(arguments: ["<i4", "unknown"])
func testUnsupportedV3Types(name: String) throws {
    #expect(throws: ZarrDataTypeError.invalidDtype(name)) {
        try ZarrDataType.parseV3(name)
    }
}
