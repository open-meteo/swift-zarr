import Foundation

extension FileManager {
    static func createIntermediateDirectories(for url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

public final class LocalFileStorage: Storage {
    private let baseURL: URL
    private let fileManager: FileManager

    public init(basePath: String) {
        self.baseURL = URL(fileURLWithPath: basePath).standardized
        self.fileManager = FileManager.default
    }

    public func read(path: String) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let data = try Data(contentsOf: url)
                    continuation.resume(returning: data)
                } catch {
                    let nsError = error as NSError
                    if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                        continuation.resume(throwing: StorageError.noSuchFile(path))
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    public func write(path: String, data: Data) async throws {
        let url = baseURL.appendingPathComponent(path)
        do {
            try FileManager.createIntermediateDirectories(for: url)
            try data.write(to: url)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
                throw StorageError.noSuchFile(path)
            }
            throw StorageError.writeFailed(path: path, underlying: error)
        }
    }

    public func list(prefix: String) async throws -> [String] {
        let url = baseURL.appendingPathComponent(prefix)
        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: nil
            )
        else {
            return []
        }
        let basePath = baseURL.path
        return enumerator.compactMap { ($0 as? URL)?.path }
            .map { String($0.dropFirst(basePath.count + 1)) }
    }

    public func listDir(prefix: String) async throws -> [String] {
        let url = baseURL.appendingPathComponent(prefix)
        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsSubdirectoryDescendants]
            )
        else {
            return []
        }
        let dirPrefix = baseURL.path + "/" + prefix + "/"
        return enumerator.compactMap { (entry: Any) -> String? in
            guard let fileURL = entry as? URL,
                (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            let fullPath = fileURL.path
            guard fullPath.hasPrefix(dirPrefix) else { return nil }
            return String(fullPath.dropFirst(dirPrefix.count))
        }
    }

    public func exists(path: String) async throws -> Bool {
        let url = baseURL.appendingPathComponent(path)
        return fileManager.fileExists(atPath: url.path)
    }

    public func delete(path: String) async throws {
        let url = baseURL.appendingPathComponent(path)
        do {
            try fileManager.removeItem(at: url)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
                nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
            {
                throw StorageError.noSuchFile(path)
            }
            throw StorageError.deleteFailed(path: path, underlying: error)
        }
    }
}
