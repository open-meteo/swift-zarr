import SwiftZarr
import Testing

@Test(arguments: [
    "|b1",
    "|i1", "<i2", ">i4", "<i8",
    "|u1", "<u2", ">u4", "<u8",
    "<f2", ">f4", "<f8",
    ">c8", "<c16",
])
func testSupportedDtypeWidths(dtype: String) throws {
    let parsed = try ZarrDataType.parse(dtype)
    #expect(parsed.elementSize == Int(dtype.dropFirst(2)))
}

@Test(arguments: [
    "|b0", "|b2", "|b-1",
    "<i0", "<i-4", "<i3", ">i16",
    "<u0", "<u-1", ">u3", "<u16",
    "<f0", ">f1", "<f3", "<f16",
    "<c0", ">c4", "<c12", "<c32",
])
func testRejectUnsupportedDtypeWidths(dtype: String) {
    #expect(throws: ZarrDataTypeError.invalidDtype(dtype)) {
        try ZarrDataType.parse(dtype)
    }
}
