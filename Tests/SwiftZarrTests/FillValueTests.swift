import Foundation
import Testing

@testable import SwiftZarr

@Test(arguments: [
    ("|u1", "-1"), ("|u1", "256"), ("|i1", "128"), ("<i8", "18446744073709551615"),
    ("<u8", "18446744073709551616"), ("<i4", "1.5"), ("<i4", "true"),
    ("<f4", "1e300"), ("<f8", "{}"), ("<f8", "\"unknown\""), ("|b1", "2"),
    (">c8", "[1,-2]"), (">c8", "null"),
])
func testRejectInvalidFills(dtype: String, fill: String) throws {
    let json =
        #"{"zarr_format":2,"compressor":null,"filters":null,"shape":[1],"chunks":[1],"order":"C","dtype":"\#(dtype)","fill_value":\#(fill)}"#
    let metadata = try JSONDecoder().decode(V2ArrayMetadata.self, from: Data(json.utf8))
    #expect(throws: ZarrArrayError.self) {
        try ZarrArray(metadata: metadata, storage: LocalFileStorage(basePath: "/unused"), path: "")
    }
}

@Test
func testHalfPrecisionFillEncoding() throws {
    let half = try ZarrDataType.parse(">f2")
    #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
    #expect(try half.encodeFillValue(.double(-0.0)) == Data([0x80, 0]))
    #endif
    #expect(try half.encodeFillValue(.string("0x7e12")) == Data([0x7e, 0x12]))
    #expect(throws: ZarrArrayError.self) { try half.encodeFillValue(.double(1e100)) }
}

@Test(arguments: [
    ("bool", ZarrJSONValue.null), ("bool", .int(0)), ("bool", .uint(1)),
    ("int32", .null), ("int32", .string("1")), ("int32", .double(1)), ("int32", .bool(true)),
    ("uint32", .null), ("uint32", .string("1")), ("uint32", .int(-1)),
    ("float32", .null), ("float32", .bool(false)), ("float32", .string("1.5")),
    ("float64", .double(.infinity)), ("float64", .double(.nan)),
])
func testRejectInvalidV3FillRepresentations(dtype: String, fill: ZarrJSONValue) throws {
    let metadata = V3ArrayMetadata(
        shape: [1],
        dataType: dtype,
        chunkGrid: .init(configuration: .init(chunkShape: [1])),
        fillValue: fill,
        codecs: [.init(name: "bytes", configuration: ["endian": .string("little")])]
    )
    #expect(throws: ZarrArrayError.self) {
        try ZarrArray(metadata: metadata, storage: LocalFileStorage(basePath: "/unused"), path: "")
    }
}

@Test(arguments: [
    ("bool", ZarrJSONValue.bool(true), [UInt8(1)]),
    ("bool", .bool(false), [0]),
    ("int32", .int(-1), [255, 255, 255, 255]),
    ("uint32", .uint(1), [1, 0, 0, 0]),
    ("float32", .double(1.5), [0, 0, 192, 63]),
    ("float32", .string("Infinity"), [0, 0, 128, 127]),
    ("float32", .string("0x7fc00001"), [1, 0, 192, 127]),
])
func testV3FillRepresentations(dtype: String, fill: ZarrJSONValue, expected: [UInt8]) async throws {
    let path = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let metadata = V3ArrayMetadata(
        shape: [1],
        dataType: dtype,
        chunkGrid: .init(configuration: .init(chunkShape: [1])),
        fillValue: fill,
        codecs: [.init(name: "bytes", configuration: ["endian": .string("little")])]
    )
    let array = try ZarrArray(metadata: metadata, storage: LocalFileStorage(basePath: path), path: "")
    try await array.storeMetadata()
    let reopened = try await ZarrArray(storage: array.storage, path: "")
    #expect(try await reopened.readChunkRaw([0]) == Data(expected))
}

@Test
func testIntegerFloatFillAvoidsDoubleRounding() throws {
    let dtype = try ZarrDataType.parse(">f4")
    #expect(try dtype.encodeFillValue(.int(4_611_686_293_305_294_849)) == Data([0x5e, 0x80, 0, 1]))
    #expect(try dtype.encodeFillValue(.uint(4_611_686_293_305_294_849)) == Data([0x5e, 0x80, 0, 1]))
}

@Test(arguments: [
    ("<u8", "18446744073709551615", [UInt8](repeating: 255, count: 8)),
    ("<u8", "9223372036854775809", [1, 0, 0, 0, 0, 0, 0, 128]),
    (">i8", "-9223372036854775808", [128, 0, 0, 0, 0, 0, 0, 0]),
    (">f4", "-0.0", [128, 0, 0, 0]),
    ("<f4", #""Infinity""#, [0, 0, 128, 127]),
    (">f8", #""-Infinity""#, [255, 240, 0, 0, 0, 0, 0, 0]),
    ("|b1", "true", [1]),
    ("<i4", "null", [0, 0, 0, 0]),
])
func testMissingChunkFillBytes(dtype: String, fill: String, expected: [UInt8]) async throws {
    let path = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let json =
        #"{"zarr_format":2,"compressor":null,"filters":null,"shape":[3],"chunks":[2],"order":"C","dtype":"\#(dtype)","fill_value":\#(fill)}"#
    let metadata = try JSONDecoder().decode(V2ArrayMetadata.self, from: Data(json.utf8))
    let array = try ZarrArray(metadata: metadata, storage: LocalFileStorage(basePath: path), path: "")
    // Missing edge chunks still have the nominal stored size.
    #expect(try await array.readChunkRaw([1]) == Data(expected + expected))
}

@Test
func testUnsignedJSONIntegersRemainExact() throws {
    let source = Data("18446744073709551615".utf8)
    let value = try JSONDecoder().decode(ZarrJSONValue.self, from: source)
    #expect(value.uintValue == UInt64.max)
    #expect(value.intValue == nil)
    #expect(try JSONEncoder().encode(value) == source)
}

@Test(arguments: [Int64.min, Int64.max])
func testSignedJSONIntegersRemainExact(number: Int64) throws {
    let source = Data(String(number).utf8)
    let value = try JSONDecoder().decode(ZarrJSONValue.self, from: source)
    #expect(value == .int(number))
    #expect(value.intValue == Int(exactly: number))
    #expect(try JSONEncoder().encode(value) == source)
}
