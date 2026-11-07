import Foundation

public enum ZarrDataTypeError: Error, Sendable, Equatable {
    case invalidDtype(String)
}

public struct ZarrDataType: Sendable, Equatable {
    public enum Endian: String, Sendable {
        case little = "<"
        case big = ">"
        case none = "|"
    }

    public enum Kind: String, Sendable, Equatable {
        case bool = "b"
        case int = "i"
        case uint = "u"
        case float = "f"
        case complex = "c"
    }

    public let endian: Endian
    public let kind: Kind
    public let size: Int

    public var elementSize: Int { size }

    public static func parse(_ dtype: String) throws -> ZarrDataType {
        guard dtype.count >= 3 else {
            throw ZarrDataTypeError.invalidDtype(dtype)
        }
        let chars = Array(dtype)
        guard let endian = Endian(rawValue: String(chars[0])),
            let kind = Kind(rawValue: String(chars[1])),
            let size = Int(String(chars[2...]))
        else {
            throw ZarrDataTypeError.invalidDtype(dtype)
        }
        return ZarrDataType(endian: endian, kind: kind, size: size)
    }

    public func matches<T: ZarrElement>(type: T.Type) -> Bool {
        kind == T.zarrDtypeKind && size == T.zarrDtypeSize
    }
}

extension ZarrDataType {
    /// Map V3 numeric names to the fixed-width types used by the reader.
    internal static func parseV3(_ name: String) throws -> ZarrDataType {
        let kind: Kind
        let size: Int
        switch name {
        case "bool": (kind, size) = (.bool, 1)
        case "int8": (kind, size) = (.int, 1)
        case "int16": (kind, size) = (.int, 2)
        case "int32": (kind, size) = (.int, 4)
        case "int64": (kind, size) = (.int, 8)
        case "uint8": (kind, size) = (.uint, 1)
        case "uint16": (kind, size) = (.uint, 2)
        case "uint32": (kind, size) = (.uint, 4)
        case "uint64": (kind, size) = (.uint, 8)
        case "float16": (kind, size) = (.float, 2)
        case "float32": (kind, size) = (.float, 4)
        case "float64": (kind, size) = (.float, 8)
        case "complex64": (kind, size) = (.complex, 8)
        case "complex128": (kind, size) = (.complex, 16)
        default: throw ZarrDataTypeError.invalidDtype(name)
        }
        return ZarrDataType(endian: size == 1 ? .none : .little, kind: kind, size: size)
    }

    public func data<T>(from value: T) -> Data {
        var v = value
        let native = withUnsafeBytes(of: &v) { Data($0) }
        if endian == .big && isLittleEndian {
            return Data(native.reversed())
        }
        if endian == .little && !isLittleEndian {
            return Data(native.reversed())
        }
        return native
    }
}

internal let isLittleEndian: Bool = {
    let number: UInt16 = 1
    return number.littleEndian == 1
}()

// Fill values are validated and encoded once when an array is opened. Every
// successful conversion returns exactly one element in its storage byte order.
extension ZarrDataType {
    internal func encodeFillValue(_ value: ZarrJSONValue?) throws -> Data {
        guard kind != .complex else {
            throw ZarrArrayError.invalidMetadata("complex fill values are unsupported")
        }
        guard let value, value != .null else { return Data(count: size) }
        switch (kind, size) {
        case (.int, 1): return try data(from: integerFill(value, as: Int8.self))
        case (.int, 2): return try data(from: integerFill(value, as: Int16.self))
        case (.int, 4): return try data(from: integerFill(value, as: Int32.self))
        case (.int, 8): return try data(from: integerFill(value, as: Int64.self))
        case (.uint, 1): return try data(from: integerFill(value, as: UInt8.self))
        case (.uint, 2): return try data(from: integerFill(value, as: UInt16.self))
        case (.uint, 4): return try data(from: integerFill(value, as: UInt32.self))
        case (.uint, 8): return try data(from: integerFill(value, as: UInt64.self))
        case (.bool, 1):
            switch value {
            case .bool(let flag): return Data([flag ? 1 : 0])
            case .int(0), .uint(0): return Data([0])
            case .int(1), .uint(1): return Data([1])
            default: throw invalidFill()
            }
        case (.float, _):
            if case .string(let text) = value, text.lowercased().hasPrefix("0x") {
                guard let bits = UInt64(text.dropFirst(2), radix: 16) else { throw invalidFill() }
                switch size {
                case 2:
                    guard let word = UInt16(exactly: bits) else { throw invalidFill() }
                    return data(from: word)
                case 4:
                    guard let word = UInt32(exactly: bits) else { throw invalidFill() }
                    return data(from: word)
                case 8: return data(from: bits)
                default: throw invalidFill()
                }
            }
            switch size {
            case 2:
                #if (os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64)
                throw ZarrArrayError.invalidMetadata("numeric float16 fills are unavailable on Intel macOS")
                #else
                return try data(from: floatingFill(value, as: Float16.self).bitPattern)
                #endif
            case 4: return try data(from: floatingFill(value, as: Float.self))
            case 8: return try data(from: floatingFill(value, as: Double.self))
            default: throw invalidFill()
            }
        default: throw invalidFill()
        }
    }

    private func floatingFill<T: BinaryFloatingPoint>(_ value: ZarrJSONValue, as type: T.Type) throws -> T {
        let result: T
        switch value {
        case .int(let value): result = T(value)
        case .uint(let value): result = T(value)
        case .double(let value):
            result = T(value)
            if !value.isFinite { return result }
        case .string("NaN"): return .nan
        case .string("Infinity"): return .infinity
        case .string("-Infinity"): return -.infinity
        default: throw invalidFill()
        }
        guard result.isFinite else { throw invalidFill() }
        return result
    }

    private func integerFill<T: FixedWidthInteger>(_ value: ZarrJSONValue, as type: T.Type) throws -> T {
        let result: T?
        switch value {
        case .int(let value): result = T(exactly: value)
        case .uint(let value): result = T(exactly: value)
        case .double(let value): result = T(exactly: value)
        case .string(let value): result = T(value)
        default: result = nil
        }
        guard let result else { throw invalidFill() }
        return result
    }

    private func invalidFill() -> ZarrArrayError {
        .invalidMetadata("fill_value is not representable by the array data type")
    }
}
