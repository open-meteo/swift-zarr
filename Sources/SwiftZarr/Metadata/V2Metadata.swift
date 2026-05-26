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

    internal var compressorID: String? {
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

public struct AnyCodable: Codable, Sendable {
    internal enum Storage: Sendable {
        case int(Int)
        case double(Double)
        case string(String)
        case bool(Bool)
        case dict([String: AnyCodable])
    }

    internal let storage: Storage

    public var value: Any {
        switch storage {
        case .int(let v): v
        case .double(let v): v
        case .string(let v): v
        case .bool(let v): v
        case .dict(let v): v
        }
    }

    public init(_ value: Any) {
        switch value {
        case let v as Int: storage = .int(v)
        case let v as Double: storage = .double(v)
        case let v as String: storage = .string(v)
        case let v as Bool: storage = .bool(v)
        case let v as [String: AnyCodable]: storage = .dict(v)
        default: storage = .string("\(value)")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            storage = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            storage = .double(doubleVal)
        } else if let stringVal = try? container.decode(String.self) {
            storage = .string(stringVal)
        } else if let boolVal = try? container.decode(Bool.self) {
            storage = .bool(boolVal)
        } else {
            storage = .dict(try container.decode([String: AnyCodable].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch storage {
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .dict(let v): try container.encode(v)
        }
    }
}
