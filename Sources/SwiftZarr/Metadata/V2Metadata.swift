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
    public let compressor: [String: AnyCodable]?
    public let fillValue: AnyCodable?
    public let order: Order?
    public let filters: [[String: AnyCodable]]?
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

    public var compressorID: String? {
        compressor?["id"]?.value as? String
    }
}

public struct V2Attrs: Codable, Sendable {
    public let values: [String: AnyCodable]

    public init(values: [String: AnyCodable]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var result: [String: AnyCodable] = [:]
        for key in container.allKeys {
            result[key.stringValue] = try container.decode(AnyCodable.self, forKey: key)
        }
        values = result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in values {
            try container.encode(value, forKey: AnyKey(stringValue: key))
        }
    }

    public func string(for key: String) -> String? {
        values[key]?.value as? String
    }

    public func int(for key: String) -> Int? {
        values[key]?.value as? Int
    }

    public func double(for key: String) -> Double? {
        values[key]?.value as? Double
    }

    public func bool(for key: String) -> Bool? {
        values[key]?.value as? Bool
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }
}

public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            value = doubleVal
        } else if let stringVal = try? container.decode(String.self) {
            value = stringVal
        } else if let boolVal = try? container.decode(Bool.self) {
            value = boolVal
        } else {
            value = try container.decode([String: AnyCodable].self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let intVal as Int: try container.encode(intVal)
        case let doubleVal as Double: try container.encode(doubleVal)
        case let stringVal as String: try container.encode(stringVal)
        case let boolVal as Bool: try container.encode(boolVal)
        case let dictVal as [String: AnyCodable]: try container.encode(dictVal)
        default: break
        }
    }
}
