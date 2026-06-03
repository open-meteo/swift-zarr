import Foundation

public enum StorageError: Error, Sendable {
    case invalidURL(String)
    case noSuchFile(String)
    case httpError(statusCode: Int, path: String)
    case connectionFailed(path: String, underlying: any Error & Sendable)
    case timeout(path: String)
    case listFailed(String)
    case readFailed(path: String, underlying: any Error & Sendable)
    case writeFailed(path: String, underlying: any Error & Sendable)
    case deleteFailed(path: String, underlying: any Error & Sendable)
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
