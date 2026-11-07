import Foundation
import SwiftZarr
import Testing

@Test
func testLocalStorageContract() async throws {
    let path = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let storage = LocalFileStorage(basePath: path)
    #expect(try await storage.list(prefix: "").isEmpty)
    #expect(try await storage.listDir(prefix: "").isEmpty)
    #expect(try await !storage.exists(path: "nested/chunk"))
    await #expect(throws: StorageError.self) { try await storage.read(path: "nested/chunk") }
    await #expect(throws: StorageError.self) { try await storage.delete(path: "nested/chunk") }

    try await storage.write(path: ".zattrs", data: Data("{}".utf8))
    try await storage.write(path: "nested/chunk", data: Data([0, 255, 1]))
    try await storage.write(path: "nested/deeper/empty", data: Data())
    #expect(try await storage.exists(path: "nested/deeper/empty"))
    #expect(try await storage.read(path: "nested/deeper/empty").isEmpty)
    #expect(try await storage.read(path: "nested/chunk") == Data([0, 255, 1]))
    #expect(try await storage.list(prefix: "").sorted() == [".zattrs", "nested/chunk", "nested/deeper/empty"])
    #expect(try await storage.list(prefix: "nested").sorted() == ["chunk", "deeper/empty"])
    #expect(try await storage.listDir(prefix: "") == ["nested"])
    #expect(try await storage.listDir(prefix: "nested") == ["deeper"])

    try await storage.write(path: "nested/chunk", data: Data([42]))
    #expect(try await storage.read(path: "nested/chunk") == Data([42]))
    try await storage.delete(path: "nested/chunk")
    #expect(try await !storage.exists(path: "nested/chunk"))
    await #expect(throws: StorageError.self) { try await storage.read(path: "nested/chunk") }
}
