import Foundation

public enum ZarrElementError: Error, Sendable {
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
        let count = data.count / MemoryLayout<Float>.size
        var result = [Float](repeating: 0, count: count)
        _ = result.withUnsafeMutableBytes { dest in
            data.copyBytes(to: dest, from: data.startIndex..<data.endIndex)
        }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            result = result.map { Float(bitPattern: $0.bitPattern.byteSwapped) }
        }
        return result
    }
}

extension Double: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .float }
    public static var zarrDtypeSize: Int { 8 }

    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [Double] {
        let count = data.count / MemoryLayout<Double>.size
        var result = [Double](repeating: 0, count: count)
        _ = result.withUnsafeMutableBytes { dest in
            data.copyBytes(to: dest, from: data.startIndex..<data.endIndex)
        }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            result = result.map { Double(bitPattern: $0.bitPattern.byteSwapped) }
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
        let count = data.count / MemoryLayout<Int16>.size
        var result = [Int16](repeating: 0, count: count)
        _ = result.withUnsafeMutableBytes { dest in data.copyBytes(to: dest) }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            result = result.map { $0.byteSwapped }
        }
        return result
    }
}

extension Int32: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .int }
    public static var zarrDtypeSize: Int { 4 }
    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [Int32] {
        let count = data.count / MemoryLayout<Int32>.size
        var result = [Int32](repeating: 0, count: count)
        _ = result.withUnsafeMutableBytes { dest in data.copyBytes(to: dest) }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            result = result.map { $0.byteSwapped }
        }
        return result
    }
}

extension Int64: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .int }
    public static var zarrDtypeSize: Int { 8 }
    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [Int64] {
        let count = data.count / MemoryLayout<Int64>.size
        var result = [Int64](repeating: 0, count: count)
        _ = result.withUnsafeMutableBytes { dest in data.copyBytes(to: dest) }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            result = result.map { $0.byteSwapped }
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
        let count = data.count / MemoryLayout<UInt16>.size
        var result = [UInt16](repeating: 0, count: count)
        _ = result.withUnsafeMutableBytes { dest in data.copyBytes(to: dest) }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            result = result.map { $0.byteSwapped }
        }
        return result
    }
}

extension UInt32: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .uint }
    public static var zarrDtypeSize: Int { 4 }
    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [UInt32] {
        let count = data.count / MemoryLayout<UInt32>.size
        var result = [UInt32](repeating: 0, count: count)
        _ = result.withUnsafeMutableBytes { dest in data.copyBytes(to: dest) }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            result = result.map { $0.byteSwapped }
        }
        return result
    }
}

extension UInt64: ZarrElement {
    public static var zarrDtypeKind: ZarrDataType.Kind { .uint }
    public static var zarrDtypeSize: Int { 8 }
    public static func decode(_ data: Data, endian: ZarrDataType.Endian) throws -> [UInt64] {
        let count = data.count / MemoryLayout<UInt64>.size
        var result = [UInt64](repeating: 0, count: count)
        _ = result.withUnsafeMutableBytes { dest in data.copyBytes(to: dest) }
        if (endian == .big && isLittleEndian) || (endian == .little && !isLittleEndian) {
            result = result.map { $0.byteSwapped }
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
