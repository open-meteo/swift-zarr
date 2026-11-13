import Foundation
import SwiftZarr
import Testing

private struct PythonFixture: Decodable, Sendable, CustomTestStringConvertible {
    struct Buffer: Decodable, Sendable {
        let indices: [Int]
        let values: [Int32]
    }
    let name: String
    var testDescription: String { name }
    let shape: [Int]
    let chunks: [Int]
    let values: [Int32]
    let bigEndian: Bool
    let buffers: [Buffer]
}

private struct PythonFillFixture: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    var testDescription: String { name }
    let type: String
    let bits: UInt64
}

private func pythonFillFixtures() throws -> [PythonFillFixture] {
    try JSONDecoder().decode(
        [PythonFillFixture].self,
        from: Data(contentsOf: fixturesURL.appendingPathComponent("limits.json"))
    )
}

private var fixturesURL: URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
}

private func pythonFixtures() throws -> [PythonFixture] {
    try JSONDecoder().decode(
        [PythonFixture].self,
        from: Data(contentsOf: fixturesURL.appendingPathComponent("manifest.json"))
    )
}

@Test(arguments: try pythonFixtures())
private func testReadPythonStores(fixture: PythonFixture) async throws {
    let storage = LocalFileStorage(basePath: fixturesURL.path)
    let array = try await ZarrArray(storage: storage, path: fixture.name)
    #expect(array.shape == fixture.shape)
    #expect(array.chunkShape == fixture.chunks)
    let full: [Int32] = try await array.retrieveArraySubset(fixture.shape.map { 0..<$0 })
    #expect(full == fixture.values, "\(fixture.name)")
    if fixture.shape == [3, 5] {
        // The first request covers exactly one full stored chunk. In F order
        // it must still return C-order subset values, not the chunk's raw order.
        for ranges in [[0..<2, 0..<3], [1..<3, 1..<5], [2..<3, 3..<5]] {
            let expected = ranges[0].flatMap { row in ranges[1].map { fixture.values[row * 5 + $0] } }
            let actual: [Int32] = try await array.retrieveArraySubset(ranges)
            #expect(actual == expected, "\(fixture.name), \(ranges)")
        }
    }
}

@Test(arguments: try pythonFixtures().filter { !$0.buffers.isEmpty })
private func testWriteUncompressedPythonFixtures(fixture: PythonFixture) async throws {
    let outputPath = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: outputPath) }
    let storage = LocalFileStorage(basePath: outputPath)
    let source = fixturesURL.appendingPathComponent(fixture.name)
    let array: ZarrArray
    if fixture.name.hasPrefix("v2") {
        let metadata = try JSONDecoder().decode(
            V2ArrayMetadata.self,
            from: Data(contentsOf: source.appendingPathComponent(".zarray"))
        )
        array = try ZarrArray(metadata: metadata, storage: storage, path: fixture.name)
    } else {
        let metadata = try JSONDecoder().decode(
            V3ArrayMetadata.self,
            from: Data(contentsOf: source.appendingPathComponent("zarr.json"))
        )
        array = try ZarrArray(metadata: metadata, storage: storage, path: fixture.name)
    }
    try await array.storeMetadata()
    let metadataKey = fixture.name.hasPrefix("v2") ? ".zarray" : "zarr.json"
    let expectedMetadata = try JSONDecoder().decode(
        ZarrJSONValue.self,
        from: Data(contentsOf: source.appendingPathComponent(metadataKey))
    )
    let writtenMetadata = try await storage.read(path: "\(fixture.name)/\(metadataKey)")
    #expect(try JSONDecoder().decode(ZarrJSONValue.self, from: writtenMetadata) == expectedMetadata)
    for buffer in fixture.buffers {
        try await array.storeChunk(buffer.indices, elements: buffer.values)
        let key = array.chunkKey(buffer.indices)
        let expected = try Data(contentsOf: source.appendingPathComponent(key))
        #expect(
            try await storage.read(path: "\(fixture.name)/\(key)") == expected,
            "\(fixture.name), \(buffer.indices)"
        )
    }
    let reopened = try await ZarrArray(storage: storage, path: fixture.name)
    for buffer in fixture.buffers {
        let values: [Int32] = try await reopened.retrieveChunk(buffer.indices)
        #expect(values == buffer.values)
    }
}

@Test(arguments: [20, 28])
func testMalformedPythonChunkLengths(decodedSize: Int) async throws {
    let path = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let storage = LocalFileStorage(basePath: path)
    let metadata = try Data(contentsOf: fixturesURL.appendingPathComponent("v3-dot-big-gzip/zarr.json"))
    let chunk = try Data(contentsOf: fixturesURL.appendingPathComponent("malformed/\(decodedSize).gzip"))
    try await storage.write(path: "zarr.json", data: metadata)
    try await storage.write(path: "c.0.0", data: chunk)
    let array = try await ZarrArray(storage: storage, path: "")
    let error = ZarrArrayError.invalidDataSize(expected: 24, got: decodedSize)
    await #expect(throws: error) { let _: [Int32] = try await array.retrieveChunk([0, 0]) }
    await #expect(throws: error) { let _: [Int32]? = try await array.retrieveChunkIfExists([0, 0]) }
    await #expect(throws: error) { let _: [Int32] = try await array.retrieveArraySubset([0..<2, 0..<3]) }
}

@Test(arguments: try pythonFillFixtures())
private func testPythonFillValues(fixture: PythonFillFixture) async throws {
    let storage = LocalFileStorage(basePath: fixturesURL.path)
    let array = try await ZarrArray(storage: storage, path: fixture.name)
    func check<T: ZarrElement>(_ type: T.Type, bits: (T) -> UInt64) async throws {
        let values: [T] = try await array.retrieveArraySubset([0..<3])
        let chunk: [T] = try await array.retrieveChunk([1])
        #expect(values.map(bits) == Array(repeating: fixture.bits, count: 3), "\(fixture.name)")
        #expect(chunk.map(bits) == Array(repeating: fixture.bits, count: 2), "\(fixture.name)")
    }
    switch fixture.type {
    case "bool": try await check(Bool.self, bits: { $0 ? 1 : 0 })
    case "uint8": try await check(UInt8.self, bits: { UInt64($0) })
    case "int8": try await check(Int8.self, bits: { UInt64(UInt8(bitPattern: $0)) })
    case "uint64": try await check(UInt64.self, bits: { $0 })
    case "int64": try await check(Int64.self, bits: { UInt64(bitPattern: $0) })
    case "float32": try await check(Float.self, bits: { UInt64($0.bitPattern) })
    case "float64": try await check(Double.self, bits: { $0.bitPattern })
    default: Issue.record("Unknown fixture type: \(fixture.type)")
    }
}
