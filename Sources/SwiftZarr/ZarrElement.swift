import Foundation

public enum ZarrElementError: Error, Sendable {
    case invalidByteCount(Int, elementSize: Int)
    case typeMismatch(expected: ZarrDataType.Kind, expectedSize: Int, actual: ZarrDataType)
}

public protocol ZarrElement: Sendable {
    static var zarrDtypeKind: ZarrDataType.Kind { get }
    static var zarrDtypeSize: Int { get }
    static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [Self]
}

// MARK: - Floating point

extension Float: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .float }
    public static var zarrDtypeSize: Int { 4 }

    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0 else {
            throw ZarrElementError.invalidByteCount(data.count, elementSize: MemoryLayout<Float>.size)
        }
        let count = data.count / MemoryLayout<Float>.size
        var result = [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
            initialized = count
        }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            swapByteOrder(&result)
        }
        return result
    }
}

extension Double: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .float }
    public static var zarrDtypeSize: Int { 8 }

    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [Double] {
        guard data.count % MemoryLayout<Double>.size == 0 else {
            throw ZarrElementError.invalidByteCount(data.count, elementSize: MemoryLayout<Double>.size)
        }
        let count = data.count / MemoryLayout<Double>.size
        var result = [Double](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
            initialized = count
        }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            swapByteOrder(&result)
        }
        return result
    }
}

// MARK: - Signed integers

extension Int8: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .int }
    public static var zarrDtypeSize: Int { 1 }
    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [Int8] {
        data.map { Int8(bitPattern: $0) }
    }
}

extension Int16: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .int }
    public static var zarrDtypeSize: Int { 2 }
    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [Int16] {
        guard data.count % MemoryLayout<Int16>.size == 0 else {
            throw ZarrElementError.invalidByteCount(data.count, elementSize: MemoryLayout<Int16>.size)
        }
        let count = data.count / MemoryLayout<Int16>.size
        var result = [Int16](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
            initialized = count
        }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            swapByteOrder(&result)
        }
        return result
    }
}

extension Int32: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .int }
    public static var zarrDtypeSize: Int { 4 }
    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [Int32] {
        guard data.count % MemoryLayout<Int32>.size == 0 else {
            throw ZarrElementError.invalidByteCount(data.count, elementSize: MemoryLayout<Int32>.size)
        }
        let count = data.count / MemoryLayout<Int32>.size
        var result = [Int32](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
            initialized = count
        }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            swapByteOrder(&result)
        }
        return result
    }
}

extension Int64: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .int }
    public static var zarrDtypeSize: Int { 8 }
    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [Int64] {
        guard data.count % MemoryLayout<Int64>.size == 0 else {
            throw ZarrElementError.invalidByteCount(data.count, elementSize: MemoryLayout<Int64>.size)
        }
        let count = data.count / MemoryLayout<Int64>.size
        var result = [Int64](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
            initialized = count
        }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            swapByteOrder(&result)
        }
        return result
    }
}

// MARK: - Unsigned integers

extension UInt8: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .uint }
    public static var zarrDtypeSize: Int { 1 }
    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [UInt8] {
        [UInt8](data)
    }
}

extension UInt16: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .uint }
    public static var zarrDtypeSize: Int { 2 }
    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [UInt16] {
        guard data.count % MemoryLayout<UInt16>.size == 0 else {
            throw ZarrElementError.invalidByteCount(data.count, elementSize: MemoryLayout<UInt16>.size)
        }
        let count = data.count / MemoryLayout<UInt16>.size
        var result = [UInt16](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
            initialized = count
        }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            swapByteOrder(&result)
        }
        return result
    }
}

extension UInt32: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .uint }
    public static var zarrDtypeSize: Int { 4 }
    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [UInt32] {
        guard data.count % MemoryLayout<UInt32>.size == 0 else {
            throw ZarrElementError.invalidByteCount(data.count, elementSize: MemoryLayout<UInt32>.size)
        }
        let count = data.count / MemoryLayout<UInt32>.size
        var result = [UInt32](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
            initialized = count
        }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            swapByteOrder(&result)
        }
        return result
    }
}

extension UInt64: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .uint }
    public static var zarrDtypeSize: Int { 8 }
    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [UInt64] {
        guard data.count % MemoryLayout<UInt64>.size == 0 else {
            throw ZarrElementError.invalidByteCount(data.count, elementSize: MemoryLayout<UInt64>.size)
        }
        let count = data.count / MemoryLayout<UInt64>.size
        var result = [UInt64](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
            initialized = count
        }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            swapByteOrder(&result)
        }
        return result
    }
}

// MARK: - Bool

extension Bool: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .bool }
    public static var zarrDtypeSize: Int { 1 }
    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [Bool] {
        data.map { $0 != 0 }
    }
}

// Only built-in numeric types conform: every bit pattern is valid, and their
// contiguous Swift representation matches the Zarr fixed-width representation.
// BitwiseCopyable alone does not guarantee either property (notably for Bool).
internal protocol NativeZarrElement: ZarrElement, BitwiseCopyable, AdditiveArithmetic {
    // A concrete witness lets the compiler optimize zero initialization.
    static func makeArray(count: Int) -> [Self]
    static func swapByteOrder(_ values: inout [Self])
}

extension NativeZarrElement {
    static func makeArray(count: Int) -> [Self] { [Self](repeating: .zero, count: count) }
}

extension NativeZarrElement where Self: FixedWidthInteger {
    static func swapByteOrder(_ values: inout [Self]) {
        var span = values.mutableSpan
        for i in span.indices { span[i] = span[i].byteSwapped }
    }
}

extension Int8: NativeZarrElement {}
extension Int16: NativeZarrElement {}
extension Int32: NativeZarrElement {}
extension Int64: NativeZarrElement {}
extension UInt8: NativeZarrElement {}
extension UInt16: NativeZarrElement {}
extension UInt32: NativeZarrElement {}
extension UInt64: NativeZarrElement {}

extension Float: NativeZarrElement {
    static func swapByteOrder(_ values: inout [Float]) {
        var span = values.mutableSpan
        for i in span.indices { span[i] = Float(bitPattern: span[i].bitPattern.byteSwapped) }
    }
}

extension Double: NativeZarrElement {
    static func swapByteOrder(_ values: inout [Double]) {
        var span = values.mutableSpan
        for i in span.indices { span[i] = Double(bitPattern: span[i].bitPattern.byteSwapped) }
    }
}
