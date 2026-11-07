import Foundation
import Testing

@testable import SwiftZarr

private func encodedBlockSize(_ data: Data) -> Int {
    data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))) }
}

@Test(arguments: [(256, 256), (512, 4096)])
func testBloscExplicitBlockSize(blockSize: Int, expectedBlockSize: Int) throws {
    // With typesize 4, the vendored c-blosc starts splitting at 512 bytes.
    // It enlarges that request, then caps the block at the 4096-byte input size.
    let codec = BloscCodec(typesize: 4, blockSize: blockSize)
    let original = Data(repeating: 7, count: 4096)
    let encoded = try codec.encode(original)
    #expect(encodedBlockSize(encoded) == expectedBlockSize)
    #expect(try codec.decode(encoded) == original)
}

@Test(arguments: [2, 3])
func testBloscMetadataBlockSize(version: Int) throws {
    let config: [String: ZarrJSONValue] = ["blocksize": .int(256), "typesize": .int(4)]
    let pipeline: CodecPipeline
    let dtype = try ZarrDataType.parse("<i4")
    if version == 2 {
        let metadata = V2ArrayMetadata(
            zarrFormat: 2,
            shape: [1024],
            chunks: [1024],
            dtype: "<i4",
            compressor: config.merging(["id": .string("blosc")]) { _, new in new },
            fillValue: nil,
            filters: nil,
            dimensionSeparator: nil
        )
        pipeline = try CodecPipeline(v2: metadata, dataType: dtype)
    } else {
        pipeline = try CodecPipeline(
            v3: [
                .init(name: "bytes", configuration: ["endian": .string("little")]),
                .init(name: "blosc", configuration: config),
            ],
            dataType: dtype
        )
    }
    let original = Data(repeating: 7, count: 4096)
    let encoded = try pipeline.encode(original)
    #expect(encodedBlockSize(encoded) == 256)
    #expect(try pipeline.decode(encoded) == original)
}

@Test(arguments: [-1, Int(Int32.max) + 1])
func testBloscRejectsInvalidBlockSize(blockSize: Int) throws {
    #expect(throws: BloscError.self) {
        try BloscCodec(blockSize: blockSize).encode(Data(repeating: 7, count: 4096))
    }
    #expect(throws: BloscError.self) {
        try CodecPipeline(
            v3: [
                .init(name: "bytes", configuration: ["endian": .string("little")]),
                .init(name: "blosc", configuration: ["blocksize": .int(Int64(blockSize)), "typesize": .int(4)]),
            ],
            dataType: ZarrDataType.parse("<i4")
        )
    }
}
