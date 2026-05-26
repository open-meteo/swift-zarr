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

/// The original metadata for a Zarr group, preserved in its native format.
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
    /// The original group metadata in its native Zarr version format.
    public let metadata: ZarrGroupMetadata
    public let version: ZarrVersion

    public init(storage: any Storage, path: String) async throws {
        self.storage = storage
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        self.path = normalizedPath
        if try await storage.exists(path: normalizedPath + "/zarr.json") {
            let metadataData = try await storage.read(path: normalizedPath + "/zarr.json")
            let decoder = JSONDecoder()
            let v3meta = try decoder.decode(V3GroupMetadata.self, from: metadataData)
            version = .v3
            metadata = .v3(v3meta)
        } else {
            version = .v2
            let metadataData = try await storage.read(path: normalizedPath + "/.zgroup")
            let decoder = JSONDecoder()
            let v2meta = try decoder.decode(V2GroupMetadata.self, from: metadataData)
            metadata = .v2(v2meta)
        }
    }

    /// Create a group from in-memory V2 metadata without reading from storage.
    public init(metadata: V2GroupMetadata, storage: any Storage, path: String) {
        self.storage = storage
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        self.path = normalizedPath
        self.metadata = .v2(metadata)
        self.version = .v2
    }

    /// Create a group from in-memory V3 metadata without reading from storage.
    public init(v3Metadata: V3GroupMetadata, storage: any Storage, path: String) {
        self.storage = storage
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        self.path = normalizedPath
        self.metadata = .v3(v3Metadata)
        self.version = .v3
    }

    /// Write the group metadata to storage (`.zgroup` for V2, `zarr.json` for V3).
    public func storeMetadata() async throws {
        let encoder = JSONEncoder()
        switch metadata {
        case .v2(let v2meta):
            let data = try encoder.encode(v2meta)
            try await storage.write(path: path + "/.zgroup", data: data)
        case .v3(let v3meta):
            let fresh = V3GroupMetadata(
                zarrFormat: 3,
                nodeType: "group",
                attributes: v3meta.attributes
            )
            let data = try encoder.encode(fresh)
            try await storage.write(path: path + "/zarr.json", data: data)
        }
    }

    /// Write the group attributes (`.zattrs` for V2, inline in `zarr.json` for V3).
    public func storeAttributes(_ attrs: V2Attrs) async throws {
        switch version {
        case .v2:
            let encoder = JSONEncoder()
            let data = try encoder.encode(attrs)
            try await storage.write(path: path + "/.zattrs", data: data)
        case .v3:
            let v3meta = V3GroupMetadata(
                zarrFormat: 3,
                nodeType: "group",
                attributes: attrs.values
            )
            let data = try JSONEncoder().encode(v3meta)
            try await storage.write(path: path + "/zarr.json", data: data)
        }
    }

    public func listChildren() async throws -> [ZarrGroupChild] {
        let childNames = try await storage.listDir(prefix: path)
        return try await withThrowingTaskGroup(
            of: ZarrGroupChild.self
        ) { group in
            for name in childNames {
                group.addTask { [storage, path] in
                    let childPath = path + "/" + name
                    if try await storage.exists(path: childPath + "/zarr.json") {
                        let data = try await storage.read(path: childPath + "/zarr.json")
                        let node = try JSONDecoder().decode(V3NodeType.self, from: data)
                        return node.nodeType == "group" ? .group(name) : .array(name)
                    }
                    if try await storage.exists(path: childPath + "/.zarray") {
                        return .array(name)
                    }
                    if try await storage.exists(path: childPath + "/.zgroup") {
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
        try await ZarrArray(storage: storage, path: path + "/" + name)
    }

    public func openGroup(name: String) async throws -> ZarrGroup {
        try await ZarrGroup(storage: storage, path: path + "/" + name)
    }

    public func attributes() async throws -> V2Attrs? {
        switch version {
        case .v2:
            let attrsPath = path + "/.zattrs"
            guard try await storage.exists(path: attrsPath) else { return nil }
            let data = try await storage.read(path: attrsPath)
            return try JSONDecoder().decode(V2Attrs.self, from: data)
        case .v3:
            guard case .v3(let v3meta) = metadata, let attrs = v3meta.attributes else { return nil }
            return V2Attrs(values: attrs)
        }
    }
}
