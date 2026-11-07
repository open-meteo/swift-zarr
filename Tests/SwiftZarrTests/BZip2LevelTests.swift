import Foundation
import SwiftZarr
import Testing

@Test(arguments: [1, 5, 9])
func testBZip2HonorsCompressionLevel(level: Int) throws {
    let codec = BZip2Codec(level: level)
    let original = Data("bzip2 compression level regression test".utf8)
    let encoded = try codec.encode(original)
    // Bzip2 stores its block-size level as the digit following "BZh".
    #expect(Array(encoded.prefix(4)) == [0x42, 0x5a, 0x68, UInt8(0x30 + level)])
    #expect(try codec.decode(encoded) == original)
}

@Test(arguments: [Int.min, -1, 0, 10, Int.max])
func testBZip2RejectsInvalidCompressionLevel(level: Int) {
    #expect(throws: CodecError.self) { try BZip2Codec(level: level).encode(Data([1])) }
}

@Test
func testBZip2DefaultCompressionLevel() throws {
    let encoded = try BZip2Codec().encode(Data([1]))
    #expect(Array(encoded.prefix(4)) == Array("BZh5".utf8))
}
