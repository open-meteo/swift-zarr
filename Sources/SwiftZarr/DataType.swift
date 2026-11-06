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
