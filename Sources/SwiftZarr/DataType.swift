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
