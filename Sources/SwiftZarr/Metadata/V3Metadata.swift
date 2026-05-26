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
    public let dimensionNames: [String]?
    public let attributes: [String: ZarrJSONValue]?

    public struct ChunkGrid: Codable, Sendable {
        public let name: String
        public let configuration: ChunkGridConfiguration
    }

    public struct ChunkGridConfiguration: Codable, Sendable {
        public let chunkShape: [UInt64]
    }

    public struct ChunkKeyEncoding: Codable, Sendable {
        public let name: String
        public let configuration: ChunkKeyEncodingConfiguration?
    }

    public struct ChunkKeyEncodingConfiguration: Codable, Sendable {
        public let separator: String?
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
    public let attributes: [String: ZarrJSONValue]?

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

    /// Return the codec short name (identity — V3 spec uses short names directly).
    public var shortName: String { name }
}

/// Zarr specification version.
public enum ZarrVersion: String, Sendable, Equatable {
    case v2
    case v3
}

/// Convert V3 metadata fields to a V2-compatible compressor dictionary.
func v3CodecsToV2Compressor(_ codecs: [V3Codec]?) -> [String: ZarrJSONValue]? {
    guard let codecs = codecs else { return nil }
    for codec in codecs {
        let shortName = codec.shortName
        switch shortName {
        case "gzip", "blosc", "zlib", "bz2":
            var config: [String: ZarrJSONValue] = ["id": .string(shortName)]
            if let cfg = codec.configuration {
                for (key, value) in cfg {
                    config[key] = value
                }
            }
            return config
        default:
            continue
        }
    }
    return nil
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
