import Foundation

public struct V2GroupMetadata: Codable, Sendable {
    public let zarrFormat: Int

    enum CodingKeys: String, CodingKey {
        case zarrFormat = "zarr_format"
    }
}

public struct V2ArrayMetadata: Codable, Sendable {
    public let zarrFormat: Int
    public let shape: [UInt64]
    public let chunks: [UInt64]
    public let dtype: String
    public let compressor: [String: ZarrJSONValue]?
    public let fillValue: ZarrJSONValue?
    public let order: Order?
    public let filters: [[String: ZarrJSONValue]]?
    public let dimensionSeparator: String?

    public enum Order: String, Codable, Sendable {
        case C
        case F
    }

    enum CodingKeys: String, CodingKey {
        case zarrFormat = "zarr_format"
        case shape, chunks, dtype, compressor
        case fillValue = "fill_value"
        case order, filters
        case dimensionSeparator = "dimension_separator"
    }

    // MARK: - Convenience accessors

    internal var compressorID: String? {
        compressor?["id"]?.stringValue
    }
}

public struct V2Attrs: Codable, Sendable {
    public let values: [String: ZarrJSONValue]

    public init(values: [String: ZarrJSONValue]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var result: [String: ZarrJSONValue] = [:]
        for key in container.allKeys {
            result[key.stringValue] = try container.decode(ZarrJSONValue.self, forKey: key)
        }
        values = result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in values {
            try container.encode(value, forKey: AnyKey(stringValue: key))
        }
    }

    public func string(for key: String) -> String? { values[key]?.stringValue }
    public func int(for key: String) -> Int? { values[key]?.intValue }
    public func double(for key: String) -> Double? { values[key]?.doubleValue }
    public func bool(for key: String) -> Bool? { values[key]?.boolValue }

    private struct AnyKey: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }
}

public enum ZarrJSONValue: Codable, Sendable, Equatable {
    case null
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    case array([ZarrJSONValue])
    case object([String: ZarrJSONValue])

    public var intValue: Int? {
        if case .int(let v) = self { v } else { nil }
    }

    public var doubleValue: Double? {
        if case .double(let v) = self { v } else { nil }
    }

    public var stringValue: String? {
        if case .string(let v) = self { v } else { nil }
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { v } else { nil }
    }

    public var arrayValue: [ZarrJSONValue]? {
        if case .array(let v) = self { v } else { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
        } else if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
        } else if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let arrayVal = try? container.decode([ZarrJSONValue].self) {
            self = .array(arrayVal)
        } else {
            self = .object(try container.decode([String: ZarrJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}
