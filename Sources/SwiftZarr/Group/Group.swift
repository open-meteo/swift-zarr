import Foundation

public enum ZarrGroupError: Error, Sendable {
    case unrecognisedChild(String)
}

public enum ZarrGroupChild: Sendable, Equatable {
    case array(String)
    case group(String)

    public var name: String {
        switch self {
        case .array(let n), .group(let n): return n
        }
    }
}

/// Group metadata in its native format.
public enum ZarrGroupMetadata: Sendable {
    case v2(V2GroupMetadata)
    case v3(V3GroupMetadata)
}

/// Minimal decodable used to inspect `node_type` in a `zarr.json` without
/// fully decoding either `V3ArrayMetadata` or `V3GroupMetadata`.
private struct V3NodeType: Decodable {
    let nodeType: String
    enum CodingKeys: String, CodingKey {
        case nodeType = "node_type"
    }
}

public struct ZarrGroup: Sendable {
    public let storage: any Storage
    public let path: String
    /// The local metadata snapshot, including current V3 attributes.
    public var metadata: ZarrGroupMetadata {
        switch metadataTemplate {
        case .v2: return metadataTemplate
        case .v3(var meta):
            meta.attributes = attributes
            return .v3(meta)
        }
    }
    public let version: ZarrVersion
    private let metadataTemplate: ZarrGroupMetadata

    /// Local attributes. Call `storeMetadata()` to persist edits.
    /// Copies and separately opened groups keep independent snapshots.
    public var attributes: [String: ZarrJSONValue]

    public init(storage: any Storage, path: String) async throws {
        let normalizedPath = try normalizeZarrPath(path)
        let decoder = JSONDecoder()
        let metadata: ZarrGroupMetadata
        if try await storage.exists(path: zarrKey(normalizedPath, "zarr.json")) {
            let data = try await storage.read(path: zarrKey(normalizedPath, "zarr.json"))
            metadata = .v3(try decoder.decode(V3GroupMetadata.self, from: data))
        } else {
            let data = try await storage.read(path: zarrKey(normalizedPath, ".zgroup"))
            metadata = .v2(try decoder.decode(V2GroupMetadata.self, from: data))
        }
        try self.init(metadata: metadata, storage: storage, path: path)
        if case .v2 = metadata {
            let attrsPath = zarrKey(normalizedPath, ".zattrs")
            if try await storage.exists(path: attrsPath) {
                let data = try await storage.read(path: attrsPath)
                attributes = try decoder.decode(V2Attrs.self, from: data).values
            }
        }
    }

    /// Create a group from native metadata without reading from storage.
    public init(metadata: ZarrGroupMetadata, storage: any Storage, path: String) throws {
        self.storage = storage
        self.path = try normalizeZarrPath(path)
        switch metadata {
        case .v2:
            version = .v2
            attributes = [:]
            metadataTemplate = metadata
        case .v3(var meta):
            version = .v3
            attributes = meta.attributes ?? [:]
            // Keep one editable attribute dictionary, without a retained duplicate.
            meta.attributes = nil
            metadataTemplate = .v3(meta)
        }
    }

    /// Create a group from in-memory V2 metadata without reading from storage.
    public init(metadata: V2GroupMetadata, storage: any Storage, path: String) throws {
        try self.init(metadata: .v2(metadata), storage: storage, path: path)
    }

    /// Create a group from in-memory V3 metadata without reading from storage.
    public init(metadata: V3GroupMetadata, storage: any Storage, path: String) throws {
        try self.init(metadata: .v3(metadata), storage: storage, path: path)
    }

    @available(*, deprecated, renamed: "init(metadata:storage:path:)")
    public init(v3Metadata: V3GroupMetadata, storage: any Storage, path: String) throws {
        try self.init(metadata: v3Metadata, storage: storage, path: path)
    }

    /// Persist the local metadata and attributes snapshot.
    /// V2 writes `.zgroup` and `.zattrs` separately; V3 writes `zarr.json`.
    /// Failed saves retain local edits for retry. Reopen to load external changes.
    public func storeMetadata() async throws {
        let encoder = JSONEncoder()
        switch metadata {
        case .v2(let v2meta):
            let data = try encoder.encode(v2meta)
            let attrs = try encoder.encode(V2Attrs(values: attributes))
            try await storage.write(path: zarrKey(path, ".zgroup"), data: data)
            try await storage.write(path: zarrKey(path, ".zattrs"), data: attrs)
        case .v3(let v3meta):
            let data = try encoder.encode(v3meta)
            try await storage.write(path: zarrKey(path, "zarr.json"), data: data)
        }
    }

    public func listChildren() async throws -> [ZarrGroupChild] {
        let childNames = try await storage.listDir(prefix: path)
        return try await withThrowingTaskGroup(
            of: ZarrGroupChild.self
        ) { group in
            for name in childNames {
                group.addTask { [storage, path] in
                    let childPath = try normalizeZarrPath(zarrKey(path, name))
                    if try await storage.exists(path: zarrKey(childPath, "zarr.json")) {
                        let data = try await storage.read(path: zarrKey(childPath, "zarr.json"))
                        let node = try JSONDecoder().decode(V3NodeType.self, from: data)
                        return node.nodeType == "group" ? .group(name) : .array(name)
                    }
                    if try await storage.exists(path: zarrKey(childPath, ".zarray")) {
                        return .array(name)
                    }
                    if try await storage.exists(path: zarrKey(childPath, ".zgroup")) {
                        return .group(name)
                    }
                    throw ZarrGroupError.unrecognisedChild(name)
                }
            }

            var children: [ZarrGroupChild] = []
            for try await child in group {
                children.append(child)
            }
            return children.sorted { $0.name < $1.name }
        }
    }

    public func childArrays() async throws -> [String] {
        try await listChildren().compactMap {
            if case .array(let name) = $0 { name } else { nil }
        }
    }

    public func childGroups() async throws -> [String] {
        try await listChildren().compactMap {
            if case .group(let name) = $0 { name } else { nil }
        }
    }

    public func openArray(name: String) async throws -> ZarrArray {
        try await ZarrArray(storage: storage, path: zarrKey(path, name))
    }

    public func openGroup(name: String) async throws -> ZarrGroup {
        try await ZarrGroup(storage: storage, path: zarrKey(path, name))
    }

}
