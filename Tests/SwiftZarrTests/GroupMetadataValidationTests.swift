import Foundation
import SwiftZarr
import Testing

@Test(arguments: [
    (2, #"{"zarr_format":1}"#),
    (2, #"{"zarr_format":3}"#),
    (3, #"{"zarr_format":2,"node_type":"group"}"#),
    (3, #"{"zarr_format":4,"node_type":"group"}"#),
    (3, #"{"zarr_format":3,"node_type":"array"}"#),
    (3, #"{"zarr_format":3,"node_type":"unknown"}"#),
])
func testRejectInvalidGroupMetadata(version: Int, json: String) async throws {
    let path = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let storage = LocalFileStorage(basePath: path)
    let data = Data(json.utf8)
    let metadata: ZarrGroupMetadata
    if version == 2 {
        metadata = .v2(try JSONDecoder().decode(V2GroupMetadata.self, from: data))
    } else {
        metadata = .v3(try JSONDecoder().decode(V3GroupMetadata.self, from: data))
    }
    #expect(throws: ZarrGroupError.self) {
        try ZarrGroup(metadata: metadata, storage: storage, path: "")
    }
    try await storage.write(path: version == 2 ? ".zgroup" : "zarr.json", data: data)
    await #expect(throws: ZarrGroupError.self) {
        try await ZarrGroup(storage: storage, path: "")
    }
}
