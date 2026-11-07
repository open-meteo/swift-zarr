import Foundation
import SwiftZarr
import Testing

#if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
@Test(arguments: [false, true])
func testFloat16Decode(bigEndian: Bool) throws {
    // One, negative zero, positive infinity, and a NaN with a payload.
    let bits: [UInt16] = [0x3c00, 0x8000, 0x7c00, 0x7e12]
    let words = bits.map { bigEndian ? $0.bigEndian : $0.littleEndian }
    let data = words.withUnsafeBytes { Data($0) }
    let values = try Float16.decode(data, endian: bigEndian ? .big : .little)
    #expect(values.map(\.bitPattern) == bits)
    #expect(try Float16.decode(Data(), endian: .little).isEmpty)
    #expect(throws: ZarrElementError.self) { try Float16.decode(Data([0]), endian: .little) }
}

@Test(arguments: [2, 3], [false, true])
func testFloat16ArrayReads(version: Int, bigEndian: Bool) async throws {
    let path = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let storage = LocalFileStorage(basePath: path)
    let array: ZarrArray
    if version == 2 {
        let json =
            #"{"zarr_format":2,"compressor":null,"filters":null,"shape":[3],"chunks":[2],"order":"C","dtype":"\#(bigEndian ? ">" : "<")f2","fill_value":-3}"#
        let metadata = try JSONDecoder().decode(V2ArrayMetadata.self, from: Data(json.utf8))
        array = try ZarrArray(metadata: metadata, storage: storage, path: "")
    } else {
        let json =
            #"{"zarr_format":3,"node_type":"array","shape":[3],"data_type":"float16","fill_value":-3,"chunk_grid":{"name":"regular","configuration":{"chunk_shape":[2]}},"chunk_key_encoding":{"name":"default","configuration":{"separator":"/"}},"codecs":[{"name":"bytes","configuration":{"endian":"\#(bigEndian ? "big" : "little")"}}]}"#
        let metadata = try JSONDecoder().decode(V3ArrayMetadata.self, from: Data(json.utf8))
        array = try ZarrArray(metadata: metadata, storage: storage, path: "")
    }
    try await array.storeMetadata()
    let bits: [UInt16] = [0x3c00, 0x4000]
    let words = bits.map { bigEndian ? $0.bigEndian : $0.littleEndian }
    try await array.storeChunk([0], data: words.withUnsafeBytes { Data($0) })
    let reopened = try await ZarrArray(storage: storage, path: "")
    let chunk: [Float16] = try await reopened.retrieveChunk([0])
    let fullChunk: [Float16] = try await reopened.retrieveArraySubset([0..<2])
    let subset: [Float16] = try await reopened.retrieveArraySubset([1..<3])
    let full: [Float16] = try await reopened.retrieveArraySubset([0..<3])
    let edge: [Float16] = try await reopened.retrieveChunk([1])
    #expect(chunk == [1, 2])
    #expect(fullChunk == [1, 2])
    #expect(subset == [2, -3])
    #expect(full == [1, 2, -3])
    #expect(edge == [-3, -3])
}
#endif
