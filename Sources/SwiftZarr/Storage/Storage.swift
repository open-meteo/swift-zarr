import Foundation

public enum ZarrPathError: Error, Sendable, Equatable {
    case invalidPath(String)
}

/// Normalize logical paths: accept either slash, collapse separators, and reject traversal.
/// The root path is represented by an empty string.
internal func normalizeZarrPath(_ path: String) throws -> String {
    let components = path.split { $0 == "/" || $0 == "\\" }
    guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
        throw ZarrPathError.invalidPath(path)
    }
    return components.joined(separator: "/")
}

/// Append a key to a normalized logical path without adding a slash at the root.
internal func zarrKey(_ path: String, _ key: String) -> String {
    path.isEmpty ? key : path + "/" + key
}

public enum StorageError: Error {
    case invalidURL(String)
    case noSuchFile(String)
    case httpError(statusCode: Int, path: String, reason: String? = nil)
    case connectionFailed(path: String, underlying: any Error)
    case timeout(path: String)
    case listFailed(String)
    case readFailed(path: String, underlying: any Error)
    case writeFailed(path: String, underlying: any Error)
    case deleteFailed(path: String, underlying: any Error)
}

public protocol Storage: Sendable {
    /// Read the full contents of a blob at the given path.
    func read(path: String) async throws -> Data

    /// Write data to a blob at the given path, creating intermediate directories as needed.
    func write(path: String, data: Data) async throws

    /// List all blobs under a prefix path.
    func list(prefix: String) async throws -> [String]

    /// List immediate sub-prefixes (directories) under a prefix path.
    /// Returns paths relative to the prefix, without trailing slashes.
    func listDir(prefix: String) async throws -> [String]

    /// Check whether a blob exists at the given path.
    func exists(path: String) async throws -> Bool

    /// Delete a blob at the given path.
    func delete(path: String) async throws
}
