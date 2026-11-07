import Foundation
import SwiftZarr
import Testing

@Test(arguments: [ZarrVersion.v2, .v3])
func testPublicArrayMetadataConstruction(version: ZarrVersion) async throws {
    let path = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let storage = LocalFileStorage(basePath: path)
    let array: ZarrArray
    switch version {
    case .v2:
        array = try ZarrArray(
            metadata: V2ArrayMetadata(shape: [3], chunks: [2], dtype: "<i4", fillValue: .int(9)),
            storage: storage,
            path: ""
        )
    case .v3:
        array = try ZarrArray(
            metadata: V3ArrayMetadata(
                shape: [3],
                dataType: "int32",
                chunkGrid: .init(configuration: .init(chunkShape: [2])),
                chunkKeyEncoding: .init(name: "default", configuration: .init(separator: "/")),
                fillValue: .int(9),
                codecs: [.init(name: "bytes", configuration: ["endian": .string("little")])],
                dimensionNames: [nil],
                attributes: ["description": .string("Created through public constructors")]
            ),
            storage: storage,
            path: ""
        )
    }
    try await array.storeMetadata()
    try await array.storeChunk([0], data: Data([1, 0, 0, 0, 2, 0, 0, 0]))
    let reopened = try await ZarrArray(storage: storage, path: "")
    #expect(reopened.version == version)
    #expect(reopened.shape == [3])
    #expect(reopened.chunkShape == [2])
    let values: [Int32] = try await reopened.retrieveArraySubset([0..<3])
    #expect(values == [1, 2, 9])
}

@Test(arguments: [ZarrVersion.v2, .v3])
func testPublicGroupMetadataConstruction(version: ZarrVersion) async throws {
    let path = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let storage = LocalFileStorage(basePath: path)
    let metadata: ZarrGroupMetadata
    switch version {
    case .v2: metadata = .v2(V2GroupMetadata())
    case .v3: metadata = .v3(V3GroupMetadata(attributes: ["answer": .int(42)]))
    }
    var group = try ZarrGroup(metadata: metadata, storage: storage, path: "")
    group.attributes["answer"] = .int(42)
    try await group.storeMetadata()
    let reopened = try await ZarrGroup(storage: storage, path: "")
    #expect(reopened.version == version)
    #expect(reopened.attributes["answer"] == .int(42))
}
