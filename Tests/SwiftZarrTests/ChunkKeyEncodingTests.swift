import Foundation
import Testing

@testable import SwiftZarr

private func keyEncodingMetadata(
    encoding: V3ArrayMetadata.ChunkKeyEncoding
) -> V3ArrayMetadata {
    V3ArrayMetadata(
        zarrFormat: 3,
        nodeType: "array",
        shape: [2, 3],
        dataType: "int32",
        chunkGrid: .init(name: "regular", configuration: .init(chunkShape: [1, 1])),
        chunkKeyEncoding: encoding,
        fillValue: .int(-1),
        codecs: [.init(name: "bytes", configuration: ["endian": .string("little")])],
        storageTransformers: nil,
        dimensionNames: nil,
        attributes: nil
    )
}

@Test(arguments: [
    ("default", nil as String?, "c/1/2", "c"),
    ("default", ".", "c.1.2", "c"),
    ("default", "/", "c/1/2", "c"),
    ("v2", nil, "1.2", "0"),
    ("v2", ".", "1.2", "0"),
    ("v2", "/", "1/2", "0"),
])
func testV3ChunkKeys(name: String, separator: String?, expectedKey: String, scalarKey: String) throws {
    let encoding = try ChunkKeyEncoding(
        v3: .init(
            name: name,
            configuration: separator.map { .init(separator: $0) }
        )
    )
    #expect(encoding.key([1, 2]) == expectedKey)
    #expect(encoding.key([]) == scalarKey)
}

@Test(arguments: [("default", ".", "c.1.2"), ("v2", "/", "1/2")])
func testV3ChunkStorage(name: String, separator: String, key: String) async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(
        metadata: keyEncodingMetadata(encoding: .init(name: name, configuration: .init(separator: separator))),
        storage: storage,
        path: "array"
    )
    // Seed an independent key so matching read/write bugs cannot hide each other.
    let bytes = Data([42, 0, 0, 0])
    try await storage.write(path: "array/" + key, data: bytes)
    let values: [Int32] = try await array.retrieveChunk([1, 2])
    #expect(values == [42])

    try await array.storeMetadata()
    let reopened = try await ZarrArray(storage: storage, path: "array")
    guard case .v3(let metadata) = reopened.metadata else {
        Issue.record("Expected V3 metadata")
        return
    }
    #expect(metadata.chunkKeyEncoding.name == name)
    #expect(metadata.chunkKeyEncoding.configuration?.separator == separator)
    let reread: [Int32]? = try await reopened.retrieveChunkIfExists([1, 2])
    #expect(reread == [42])
    try await reopened.eraseChunk([1, 2])
    #expect(try await !storage.exists(path: "array/" + key))
    try await reopened.storeChunk([1, 2], data: bytes)
    #expect(try await storage.read(path: "array/" + key) == bytes)
}

@Test
func testV3MissingChunkKeyConfiguration() throws {
    for metadata: V3ArrayMetadata.ChunkKeyEncoding in [
        .init(name: "default"), .init(name: "default", configuration: .init(separator: nil)),
    ] {
        #expect(try ChunkKeyEncoding(v3: metadata).key([1, 2]) == "c/1/2")
    }
    let metadata = V3ArrayMetadata.ChunkKeyEncoding(name: "v2", configuration: .init(separator: nil))
    #expect(try ChunkKeyEncoding(v3: metadata).key([1, 2]) == "1.2")
}

@Test(arguments: ["custom", "default", "v2"])
func testV3InvalidChunkKeyEncoding(name: String) async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let storage = LocalFileStorage(basePath: tmp)
    let metadata = keyEncodingMetadata(encoding: .init(name: name, configuration: .init(separator: "-")))
    let expected: ZarrArrayError =
        name == "custom" ? .unsupportedChunkKeyEncoding(name) : .invalidChunkKeySeparator("-")
    #expect(throws: expected) {
        try ZarrArray(metadata: metadata, storage: storage, path: "array")
    }
    try await storage.write(path: "array/zarr.json", data: JSONEncoder().encode(metadata))
    await #expect(throws: expected) {
        try await ZarrArray(storage: storage, path: "array")
    }
}
