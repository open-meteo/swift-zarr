import Foundation

/// Zarr V3 array metadata (from `zarr.json`).
public struct V3ArrayMetadata: Codable, Sendable {
    public let zarrFormat: Int
    public let nodeType: String
    public let shape: [UInt64]
    public let dataType: String
    public let chunkGrid: ChunkGrid
    public let chunkKeyEncoding: ChunkKeyEncoding?
    public let fillValue: ZarrJSONValue?
    public let codecs: [V3Codec]?
    public let storageTransformers: [ZarrJSONValue]?
    public let dimensionNames: [String?]?
    public let attributes: [String: ZarrJSONValue]?

    /// Metadata is validated when passed to `ZarrArray`.
    public init(
        zarrFormat: Int = 3,
        nodeType: String = "array",
        shape: [UInt64],
        dataType: String,
        chunkGrid: ChunkGrid,
        chunkKeyEncoding: ChunkKeyEncoding? = .init(name: "default", configuration: .init(separator: "/")),
        fillValue: ZarrJSONValue?,
        codecs: [V3Codec]?,
        storageTransformers: [ZarrJSONValue]? = nil,
        dimensionNames: [String?]? = nil,
        attributes: [String: ZarrJSONValue]? = nil
    ) {
        self.zarrFormat = zarrFormat
        self.nodeType = nodeType
        self.shape = shape
        self.dataType = dataType
        self.chunkGrid = chunkGrid
        self.chunkKeyEncoding = chunkKeyEncoding
        self.fillValue = fillValue
        self.codecs = codecs
        self.storageTransformers = storageTransformers
        self.dimensionNames = dimensionNames
        self.attributes = attributes
    }

    public struct ChunkGrid: Codable, Sendable {
        public let name: String
        public let configuration: ChunkGridConfiguration

        public init(name: String = "regular", configuration: ChunkGridConfiguration) {
            self.name = name
            self.configuration = configuration
        }
    }

    public struct ChunkGridConfiguration: Codable, Sendable {
        public let chunkShape: [UInt64]

        public init(chunkShape: [UInt64]) {
            self.chunkShape = chunkShape
        }

        enum CodingKeys: String, CodingKey {
            case chunkShape = "chunk_shape"
        }
    }

    public struct ChunkKeyEncoding: Codable, Sendable {
        public let name: String
        public let configuration: ChunkKeyEncodingConfiguration?

        public init(name: String, configuration: ChunkKeyEncodingConfiguration? = nil) {
            self.name = name
            self.configuration = configuration
        }
    }

    public struct ChunkKeyEncodingConfiguration: Codable, Sendable {
        public let separator: String?

        public init(separator: String? = nil) {
            self.separator = separator
        }
    }

    enum CodingKeys: String, CodingKey {
        case zarrFormat = "zarr_format"
        case nodeType = "node_type"
        case shape
        case dataType = "data_type"
        case chunkGrid = "chunk_grid"
        case chunkKeyEncoding = "chunk_key_encoding"
        case fillValue = "fill_value"
        case codecs
        case storageTransformers = "storage_transformers"
        case dimensionNames = "dimension_names"
        case attributes
    }
}

/// Zarr V3 group metadata (from `zarr.json`).
public struct V3GroupMetadata: Codable, Sendable {
    public let zarrFormat: Int
    public let nodeType: String
    public var attributes: [String: ZarrJSONValue]?

    public init(zarrFormat: Int = 3, nodeType: String = "group", attributes: [String: ZarrJSONValue]? = nil) {
        self.zarrFormat = zarrFormat
        self.nodeType = nodeType
        self.attributes = attributes
    }

    enum CodingKeys: String, CodingKey {
        case zarrFormat = "zarr_format"
        case nodeType = "node_type"
        case attributes
    }
}

/// A single codec entry in a V3 codec pipeline.
public struct V3Codec: Codable, Sendable {
    public let name: String
    public let configuration: [String: ZarrJSONValue]?

    public init(name: String, configuration: [String: ZarrJSONValue]? = nil) {
        self.name = name
        self.configuration = configuration
    }

    /// Return the codec short name (identity — V3 spec uses short names directly).
    public var shortName: String { name }
}

/// Zarr specification version.
public enum ZarrVersion: String, Sendable, Equatable {
    case v2
    case v3
}

/// Convert a V2 compressor dictionary to a V3 codec array.
func compressorDictToV3Codecs(_ compressor: [String: ZarrJSONValue]) -> [V3Codec] {
    guard case .string(let id) = compressor["id"] else { return [] }
    var config: [String: ZarrJSONValue] = [:]
    for (key, value) in compressor where key != "id" {
        config[key] = value
    }
    return [V3Codec(name: id, configuration: config.isEmpty ? nil : config)]
}
