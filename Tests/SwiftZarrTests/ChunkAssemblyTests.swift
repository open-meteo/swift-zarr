import Foundation
import Testing

@testable import SwiftZarr

@Test(arguments: [[UInt64(1) << 32, UInt64(1) << 32], [UInt64(Int.max / 4 + 1)]])
func testChunkLayoutOverflow(chunks: [UInt64]) throws {
    let metadata = V2ArrayMetadata(
        zarrFormat: 2,
        shape: chunks.map { _ in 1 },
        chunks: chunks,
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    #expect(throws: ZarrArrayError.self) {
        try ZarrArray(metadata: metadata, storage: LocalFileStorage(basePath: "/unused"), path: "")
    }
}

// Deliberately different Swift and wire representations; reads must use the custom decoder.
private struct CustomInt: ZarrElement, Equatable {
    let value: String
    static let zarrDtypeKind: ZarrDataType.Kind = .int
    static let zarrDtypeSize = 4
    static func encode(_ values: [Self], endian: ZarrDataType.Endian) throws -> Data {
        let integers = try values.map { try #require(Int32($0.value)) }
        return Int32.encode(integers, endian: endian)
    }
    static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [Self] {
        try Int32.decode(data, endian: endian).map { Self(value: String($0)) }
    }
}

@Test
func testCustomElementSubsetAndBoolNormalization() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let storage = LocalFileStorage(basePath: tmp)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [3],
        chunks: [2],
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let array = try ZarrArray(metadata: meta, storage: storage, path: "custom")
    try await array.storeChunk([0], elements: [Int32(1), 2])
    try await array.storeChunk([1], elements: [Int32(3), 99])
    let custom: [CustomInt] = try await array.retrieveArraySubset([1..<3])
    #expect(custom.map(\.value) == ["2", "3"])
    let boolMeta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [3],
        chunks: [2],
        dtype: "|b1",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let boolArray = try ZarrArray(metadata: boolMeta, storage: storage, path: "bool")
    try await boolArray.storeChunk([0], data: Data([0, 255]))
    try await boolArray.storeChunk([1], data: Data([2, 0]))
    let bools: [Bool] = try await boolArray.retrieveArraySubset([0..<3])
    #expect(bools == [false, true, true])

}

@Test
func testLiteralEndianValuesAndFloatingPointBits() async throws {
    func check<T: ZarrElement, Bits: Equatable>(
        _ type: T.Type,
        dtype: String,
        littleEndian: [UInt8],
        expected: [Bits],
        bits: (T) -> Bits
    ) async throws {
        let tmp = try createTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let storage = LocalFileStorage(basePath: tmp)
        for endian in [ZarrDataType.Endian.little, .big] {
            let bytes =
                endian == .little
                ? littleEndian
                : stride(from: 0, to: littleEndian.count, by: T.zarrDtypeSize).flatMap {
                    littleEndian[$0..<$0 + T.zarrDtypeSize].reversed()
                }
            let data = Data(bytes)
            let metadata = V2ArrayMetadata(
                zarrFormat: 2,
                shape: [UInt64(expected.count)],
                chunks: [1],
                dtype: (endian == .little ? "<" : ">") + dtype,
                compressor: nil,
                fillValue: nil,
                order: .C,
                filters: nil,
                dimensionSeparator: nil
            )
            let array = try ZarrArray(metadata: metadata, storage: storage, path: "")
            for i in expected.indices {
                try await array.storeChunk([i], data: data.subdata(in: i * T.zarrDtypeSize..<(i + 1) * T.zarrDtypeSize))
            }
            let values: [T] = try await array.retrieveArraySubset([0..<expected.count])
            #expect(values.map(bits) == expected)
            #expect(try T.decode(data, endian: endian).map(bits) == expected)
        }
    }
    try await check(
        Int16.self,
        dtype: "i2",
        littleEndian: [0x34, 0x12, 0xfe, 0xff],
        expected: [0x1234, -2],
        bits: { $0 }
    )
    try await check(
        Int32.self,
        dtype: "i4",
        littleEndian: [0x78, 0x56, 0x34, 0x12, 0xfe, 0xff, 0xff, 0xff],
        expected: [0x1234_5678, -2],
        bits: { $0 }
    )
    try await check(Int8.self, dtype: "i1", littleEndian: [0x7f, 0x80], expected: [127, -128], bits: { $0 })
    try await check(UInt8.self, dtype: "u1", littleEndian: [0, 0xff], expected: [0, 255], bits: { $0 })
    try await check(
        UInt16.self,
        dtype: "u2",
        littleEndian: [0x34, 0x12, 0xff, 0xff],
        expected: [0x1234, 0xffff],
        bits: { $0 }
    )
    try await check(
        UInt32.self,
        dtype: "u4",
        littleEndian: [0x78, 0x56, 0x34, 0x12, 0xff, 0xff, 0xff, 0xff],
        expected: [0x1234_5678, UInt32.max],
        bits: { $0 }
    )
    try await check(
        Int64.self,
        dtype: "i8",
        littleEndian: [8, 7, 6, 5, 4, 3, 2, 1, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
        expected: [0x0102_0304_0506_0708, -2],
        bits: { $0 }
    )
    try await check(
        UInt64.self,
        dtype: "u8",
        littleEndian: [8, 7, 6, 5, 4, 3, 2, 1, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
        expected: [0x0102_0304_0506_0708, UInt64.max],
        bits: { $0 }
    )
    // Negative zero, positive/negative infinity, and a NaN with a nonzero payload.
    try await check(
        Float.self,
        dtype: "f4",
        littleEndian: [
            0, 0, 0, 0x80, 0, 0, 0x80, 0x7f, 0, 0, 0x80, 0xff, 0x34, 0x12, 0xc0, 0x7f,
        ],
        expected: [UInt32(0x8000_0000), 0x7f80_0000, 0xff80_0000, 0x7fc0_1234],
        bits: { $0.bitPattern }
    )
    try await check(
        Double.self,
        dtype: "f8",
        littleEndian: [
            0, 0, 0, 0, 0, 0, 0, 0x80,
            0, 0, 0, 0, 0, 0, 0xf0, 0x7f,
            0, 0, 0, 0, 0, 0, 0xf0, 0xff,
            0x34, 0x12, 0, 0, 0, 0, 0xf8, 0x7f,
        ],
        expected: [UInt64(0x8000_0000_0000_0000), 0x7ff0_0000_0000_0000, 0xfff0_0000_0000_0000, 0x7ff8_0000_0000_1234],
        bits: { $0.bitPattern }
    )
}
