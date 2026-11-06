import Foundation
import Testing

@testable import SwiftZarr

@Test(arguments: [false, true])
func testPaddedEdgeChunk(fortran: Bool) async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let storage = LocalFileStorage(basePath: tmp)
    let metadata = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [2, 3],
        chunks: [2, 2],
        dtype: "|u1",
        compressor: nil,
        fillValue: .int(7),
        order: fortran ? .F : .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let array = try ZarrArray(metadata: metadata, storage: storage, path: "")
    let first = Data(fortran ? [0, 3, 1, 4] : [0, 1, 3, 4])
    let edge = Data(fortran ? [2, 5, 99, 99] : [2, 99, 5, 99])
    try await storage.write(path: "0.0", data: first)
    try await storage.write(path: "0.1", data: edge)
    let full: [UInt8] = try await array.retrieveArraySubset([0..<2, 0..<3])
    let last: [UInt8] = try await array.retrieveArraySubset([0..<2, 2..<3])
    let row: [UInt8] = try await array.retrieveArraySubset([1..<2, 2..<3])
    #expect(full == [0, 1, 2, 3, 4, 5])
    #expect(last == [2, 5])
    #expect(row == [5])
    #expect(try await array.readRaw() == Data(full))
    try await array.storeChunk([0, 1], data: edge)
    #expect(try await storage.read(path: "0.1") == edge)
    await #expect(throws: ZarrArrayError.invalidDataSize(expected: 4, got: 2)) {
        try await array.storeChunk([0, 1], data: Data([2, 5]))
    }
    try await array.eraseChunk([0, 1])
    let missing: [UInt8] = try await array.retrieveChunk([0, 1])
    #expect(missing == [7, 7, 7, 7])
}

@Test(arguments: [false, true])
func testInvalidDecodedChunkLengths(compressed: Bool) async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let storage = LocalFileStorage(basePath: tmp)
    let metadata = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4],
        chunks: [2],
        dtype: "<i4",
        compressor: compressed ? ["id": .string("gzip")] : nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let array = try ZarrArray(metadata: metadata, storage: storage, path: "")
    for count in [0, 3, 4, 12] {
        let decoded = Data(repeating: 0, count: count)
        try await storage.write(path: "0", data: compressed ? GzipCodec().encode(decoded) : decoded)
        let error = ZarrArrayError.invalidDataSize(expected: 8, got: count)
        await #expect(throws: error) { let _: [Int32] = try await array.retrieveChunk([0]) }
        await #expect(throws: error) { let _: [Int32]? = try await array.retrieveChunkIfExists([0]) }
        for range in [0..<1, 0..<2, 0..<4] {
            await #expect(throws: error) { let _: [Int32] = try await array.retrieveArraySubset([range]) }
        }
        await #expect(throws: error) { try await array.readRaw() }
    }
}

@Test
func testIncompleteElements() {
    for type in [
        Int16.self, Int32.self, Int64.self, UInt16.self, UInt32.self, UInt64.self,
        Float.self, Double.self,
    ] as [any ZarrElement.Type] {
        #expect(throws: ZarrElementError.self) {
            try type.decode(Data(repeating: 0, count: type.zarrDtypeSize + 1), endian: .little)
        }
    }
}
