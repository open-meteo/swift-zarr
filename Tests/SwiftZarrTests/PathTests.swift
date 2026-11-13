import Foundation
import Testing

@testable import SwiftZarr

@Test(arguments: [
    ("", ""), ("/", ""), ("///\\\\", ""),
    ("a", "a"), ("///a//b///", "a/b"), ("\\a\\\\b\\", "a/b"),
    ("/a\\/b//", "a/b"), ("a.b/.../.hidden", "a.b/.../.hidden"),
    (" a / b ", " a / b "),
])
func testNormalizeZarrPath(input: String, expected: String) throws {
    let normalized = try normalizeZarrPath(input)
    #expect(normalized == expected)
    #expect(try normalizeZarrPath(normalized) == normalized)
}

private func pathArrayMetadata(_ version: ZarrVersion) -> ZarrArrayMetadata {
    switch version {
    case .v2:
        return .v2(
            .init(
                zarrFormat: 2,
                shape: [1],
                chunks: [1],
                dtype: "<i4",
                compressor: nil,
                fillValue: .int(0),
                order: .C,
                filters: nil,
                dimensionSeparator: nil
            )
        )
    case .v3:
        return .v3(
            .init(
                zarrFormat: 3,
                nodeType: "array",
                shape: [1],
                dataType: "int32",
                chunkGrid: .init(name: "regular", configuration: .init(chunkShape: [1])),
                fillValue: .int(0),
                codecs: [.init(name: "bytes", configuration: ["endian": .string("little")])],
                storageTransformers: nil,
                dimensionNames: nil,
                attributes: nil
            )
        )
    }
}

private func pathGroupMetadata(_ version: ZarrVersion) -> ZarrGroupMetadata {
    switch version {
    case .v2: return .v2(.init(zarrFormat: 2))
    case .v3: return .v3(.init(zarrFormat: 3, nodeType: "group", attributes: nil))
    }
}

// Exact-key storage ensures a filesystem cannot hide accidental leading slashes.
private actor PathTestStorage: Storage {
    private var objects: [String: Data] = [:]
    private(set) var readAttempts = 0

    func read(path: String) throws -> Data {
        readAttempts += 1
        guard let data = objects[path] else { throw StorageError.noSuchFile(path) }
        return data
    }
    func write(path: String, data: Data) { objects[path] = data }
    func exists(path: String) -> Bool {
        readAttempts += 1
        return objects[path] != nil
    }
    func delete(path: String) { objects.removeValue(forKey: path) }
    func list(prefix: String) -> [String] { objects.keys.filter { $0.hasPrefix(prefix) }.sorted() }
    func listDir(prefix: String) -> [String] {
        let start = prefix.isEmpty ? "" : prefix + "/"
        return Set(
            objects.keys.compactMap { key -> String? in
                guard key.hasPrefix(start) else { return nil }
                let parts = key.dropFirst(start.count).split(separator: "/")
                return parts.count > 1 ? String(parts[0]) : nil
            }
        ).sorted()
    }
}

@Test(arguments: [".", "..", "a/./b", "/a//../b/", "a\\..\\b", "./a", "a/.."])
func testInvalidZarrPaths(path: String) {
    #expect(throws: ZarrPathError.invalidPath(path)) { try normalizeZarrPath(path) }
}

@Test
func testConstructorsRejectInvalidPathsBeforeStorageAccess() async throws {
    let storage = PathTestStorage()
    let path = "a/../b"
    let expected = ZarrPathError.invalidPath(path)
    for version in [ZarrVersion.v2, .v3] {
        #expect(throws: expected) {
            try ZarrArray(metadata: pathArrayMetadata(version), storage: storage, path: path)
        }
        #expect(throws: expected) {
            try ZarrGroup(metadata: pathGroupMetadata(version), storage: storage, path: path)
        }
    }
    // Validation must happen before metadata I/O, even when no objects exist.
    await #expect(throws: expected) { try await ZarrArray(storage: storage, path: path) }
    await #expect(throws: expected) { try await ZarrGroup(storage: storage, path: path) }
    let group = try ZarrGroup(metadata: pathGroupMetadata(.v2), storage: storage, path: "")
    await #expect(throws: ZarrPathError.invalidPath("../escape")) {
        try await group.openArray(name: "../escape")
    }
    await #expect(throws: ZarrPathError.invalidPath("./group")) {
        try await group.openGroup(name: "./group")
    }
    #expect(await storage.readAttempts == 0)
}

@Test(arguments: [ZarrVersion.v2, .v3])
func testRootArrayPaths(version: ZarrVersion) async throws {
    let path = "///"
    let storage = PathTestStorage()
    let array = try ZarrArray(metadata: pathArrayMetadata(version), storage: storage, path: path)
    #expect(array.path.isEmpty)
    try await array.storeMetadata()
    let metadataKey = version == .v2 ? ".zarray" : "zarr.json"
    #expect(await storage.exists(path: metadataKey))
    let reopened = try await ZarrArray(storage: storage, path: path)
    #expect(reopened.path.isEmpty)
    let chunkKey = version == .v2 ? "0" : "c/0"
    let bytes = Data([42, 0, 0, 0])
    try await reopened.storeChunk([0], elements: [Int32(42)])
    #expect(try await storage.read(path: chunkKey) == bytes)
    let values: [Int32] = try await reopened.retrieveChunk([0])
    let existing: [Int32]? = try await reopened.retrieveChunkIfExists([0])
    #expect(values == [42])
    #expect(existing == [42])
    try await reopened.eraseChunk([0])
    #expect(await !storage.exists(path: chunkKey))
}

@Test(arguments: [ZarrVersion.v2, .v3])
func testRootGroupPaths(version: ZarrVersion) async throws {
    let storage = PathTestStorage()
    var root = try ZarrGroup(metadata: pathGroupMetadata(version), storage: storage, path: "///\\")
    #expect(root.path.isEmpty)
    try await root.storeMetadata()
    let attrs = V2Attrs(values: ["answer": .int(42)])
    root.attributes = attrs.values
    try await root.storeMetadata()
    let reopened = try await ZarrGroup(storage: storage, path: "/")
    #expect(reopened.attributes["answer"]?.intValue == 42)
    #expect(await storage.exists(path: version == .v2 ? ".zgroup" : "zarr.json"))

    let child = try ZarrArray(metadata: pathArrayMetadata(version), storage: storage, path: "//array//")
    try await child.storeMetadata()
    let subgroup = try ZarrGroup(metadata: pathGroupMetadata(version), storage: storage, path: "\\group\\")
    try await subgroup.storeMetadata()
    #expect(try await reopened.openArray(name: "/array/").path == "array")
    #expect(try await reopened.openGroup(name: "\\group\\").path == "group")
    #expect(try await reopened.listChildren() == [.array("array"), .group("group")])
}

@Test
func testNestedArrayPath() async throws {
    let storage = PathTestStorage()
    let array = try ZarrArray(metadata: pathArrayMetadata(.v2), storage: storage, path: "/nested//array\\")
    #expect(array.path == "nested/array")
    try await array.storeMetadata()
    #expect(await storage.exists(path: "nested/array/.zarray"))
    let reopened = try await ZarrArray(storage: storage, path: "nested\\array")
    #expect(reopened.path == "nested/array")
}
