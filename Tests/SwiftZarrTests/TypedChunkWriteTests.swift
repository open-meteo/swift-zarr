import Foundation
import SwiftZarr
import Testing

@Test(arguments: [false, true], [ZarrVersion.v2, .v3])
func testTypedChunkWrites(bigEndian: Bool, version: ZarrVersion) async throws {
    func check<T: ZarrElement & Equatable>(
        _ values: [T],
        dtype: String,
        v3Type: String,
        littleBytes: [UInt8]
    ) async throws {
        let path = try createTempDir()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let storage = LocalFileStorage(basePath: path)
        let array: ZarrArray
        switch version {
        case .v2:
            array = try ZarrArray(
                metadata: V2ArrayMetadata(shape: [1], chunks: [2], dtype: (bigEndian ? ">" : "<") + dtype),
                storage: storage,
                path: ""
            )
        case .v3:
            array = try ZarrArray(
                metadata: V3ArrayMetadata(
                    shape: [1],
                    dataType: v3Type,
                    chunkGrid: .init(configuration: .init(chunkShape: [2])),
                    fillValue: v3Type == "bool" ? .bool(false) : .int(0),
                    codecs: [.init(name: "bytes", configuration: ["endian": .string(bigEndian ? "big" : "little")])]
                ),
                storage: storage,
                path: ""
            )
        }
        try await array.storeMetadata()
        try await array.storeChunk([0], elements: values)
        let size = T.zarrDtypeSize
        let expected = stride(from: 0, to: littleBytes.count, by: size).flatMap { offset in
            let word = Array(littleBytes[offset..<offset + size])
            return bigEndian ? Array(word.reversed()) : word
        }
        #expect(try await storage.read(path: array.chunkKey([0])) == Data(expected))
        let reopened = try await ZarrArray(storage: storage, path: "")
        let actual: [T] = try await reopened.retrieveChunk([0])
        #expect(actual == values)
    }

    try await check([Int8(-1), 1], dtype: "i1", v3Type: "int8", littleBytes: [255, 1])
    try await check([UInt8(0), 255], dtype: "u1", v3Type: "uint8", littleBytes: [0, 255])
    try await check([Int16(-1), 1], dtype: "i2", v3Type: "int16", littleBytes: [255, 255, 1, 0])
    try await check([UInt16(0), 258], dtype: "u2", v3Type: "uint16", littleBytes: [0, 0, 2, 1])
    try await check([Int32(-1), 1], dtype: "i4", v3Type: "int32", littleBytes: [255, 255, 255, 255, 1, 0, 0, 0])
    try await check([UInt32(0), 258], dtype: "u4", v3Type: "uint32", littleBytes: [0, 0, 0, 0, 2, 1, 0, 0])
    try await check(
        [Int64(-1), 1],
        dtype: "i8",
        v3Type: "int64",
        littleBytes: Array(repeating: 255, count: 8) + [1, 0, 0, 0, 0, 0, 0, 0]
    )
    try await check(
        [UInt64(0), 258],
        dtype: "u8",
        v3Type: "uint64",
        littleBytes: Array(repeating: 0, count: 8) + [2, 1, 0, 0, 0, 0, 0, 0]
    )
    try await check([Float(0), 1], dtype: "f4", v3Type: "float32", littleBytes: [0, 0, 0, 0, 0, 0, 128, 63])
    try await check(
        [Double(0), 1],
        dtype: "f8",
        v3Type: "float64",
        littleBytes: Array(repeating: 0, count: 8) + [0, 0, 0, 0, 0, 0, 240, 63]
    )
    #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
    try await check([Float16(0), 1], dtype: "f2", v3Type: "float16", littleBytes: [0, 0, 0, 60])
    #endif
    try await check([false, true], dtype: "b1", v3Type: "bool", littleBytes: [0, 1])
}

@Test
func testTypedChunkWriteValidation() async throws {
    let path = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let storage = LocalFileStorage(basePath: path)
    let array = try ZarrArray(
        metadata: V2ArrayMetadata(shape: [2], chunks: [2], dtype: "<i4"),
        storage: storage,
        path: ""
    )
    try await array.storeChunk([0], elements: [Int32(1), 2])
    for count in [0, 1, 3] {
        do {
            try await array.storeChunk([0], elements: [Int32](repeating: 0, count: count))
            Issue.record("Expected element count error")
        } catch ZarrElementError.invalidElementCount(let expected, let got) {
            #expect(expected == 2)
            #expect(got == count)
        }
    }
    await #expect(throws: ZarrElementError.self) {
        try await array.storeChunk([0], elements: [UInt32(1), 2])
    }
    await #expect(throws: ZarrElementError.self) {
        try await array.storeChunk([0], elements: [Float(1), 2])
    }
    await #expect(throws: ZarrElementError.self) {
        try await array.storeChunk([0], elements: [Int16(1), 2])
    }
    await #expect(throws: ZarrArrayError.self) {
        try await array.storeChunk([1], elements: [Int32(1), 2])
    }
    #expect(try await storage.read(path: "0") == Data([1, 0, 0, 0, 2, 0, 0, 0]))
}

@Test
func testTypedEncodingPreservesFloatBits() throws {
    let values = [Float(bitPattern: 0x8000_0000), Float(bitPattern: 0x7FC0_1234)]
    #expect(try Float.encode(values, endian: .big) == Data([128, 0, 0, 0, 127, 192, 18, 52]))
    #expect(try Float.encode(values, endian: .little) == Data([0, 0, 0, 128, 52, 18, 192, 127]))
}
