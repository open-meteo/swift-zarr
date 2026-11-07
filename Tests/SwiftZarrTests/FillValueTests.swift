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
    let json = #"{"zarr_format":2,"shape":[1],"chunks":[1],"order":"C","dtype":"\#(dtype)","fill_value":\#(fill)}"#
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
    let json = #"{"zarr_format":2,"shape":[3],"chunks":[2],"order":"C","dtype":"\#(dtype)","fill_value":\#(fill)}"#
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

@Test(arguments: [
    ZarrJSONValue.double(-0.0),
    .object(["nested": .array([.double(-0.0)])]),
])
func testRejectNegativeZeroJSONEncoding(value: ZarrJSONValue) throws {
    #expect(throws: EncodingError.self) { try JSONEncoder().encode(value) }
    #expect(try JSONEncoder().encode(ZarrJSONValue.double(0.0)) == Data("0".utf8))
}

@Test
func testNegativeZeroSaveLeavesMetadataUntouched() async throws {
    let path = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let storage = LocalFileStorage(basePath: path)
    let source = Data(
        #"{"zarr_format":2,"shape":[1],"chunks":[1],"order":"C","dtype":"<f4","fill_value":-0.0}"#.utf8
    )
    try await storage.write(path: ".zarray", data: source)
    let array = try await ZarrArray(storage: storage, path: "")
    let values: [Float] = try await array.retrieveChunk([0])
    #expect(values.map(\.bitPattern) == [0x8000_0000])
    await #expect(throws: EncodingError.self) { try await array.storeMetadata() }
    #expect(try await storage.read(path: ".zarray") == source)

    let metadata = try JSONDecoder().decode(V2GroupMetadata.self, from: Data(#"{"zarr_format":2}"#.utf8))
    var group = try ZarrGroup(metadata: metadata, storage: storage, path: "group")
    group.attributes["nested"] = .array([.double(-0.0)])
    await #expect(throws: EncodingError.self) { try await group.storeMetadata() }
    #expect(try await !storage.exists(path: "group/.zgroup"))
    #expect(try await !storage.exists(path: "group/.zattrs"))
    #expect(group.attributes["nested"] == .array([.double(-0.0)]))
}
