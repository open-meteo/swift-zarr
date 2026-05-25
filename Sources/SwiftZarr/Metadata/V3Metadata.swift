import Foundation

/// Zarr V3 array metadata (from `zarr.json`).
public struct V3ArrayMetadata: Codable, Sendable {
    public let zarrFormat: String
    public let metadataEncoding: String?
    public let metadataKey: String?
    public let shape: [UInt64]
    public let dataType: String
    public let chunkGrid: ChunkGrid
    public let chunkKeyEncoding: ChunkKeyEncoding?
    public let fillValue: AnyCodable?
    public let codecs: [V3Codec]?
    public let storageTransformers: [AnyCodable]?
    public let dimensionNames: [String]?
    public let attributes: [String: AnyCodable]?

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
        case metadataEncoding = "metadata_encoding"
        case metadataKey = "metadata_key"
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
    public let zarrFormat: String
    public let metadataEncoding: String?
    public let metadataKey: String?
    public let attributes: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case zarrFormat = "zarr_format"
        case metadataEncoding = "metadata_encoding"
        case metadataKey = "metadata_key"
        case attributes
    }
}

/// A single codec entry in a V3 codec pipeline.
public struct V3Codec: Codable, Sendable {
    public let name: String
    public let configuration: [String: AnyCodable]?

    /// Normalize a V3 codec name (URL or short name) to a short name.
    public var shortName: String {
        let lower = name.lowercased()
        if lower.hasSuffix("/gzip/1.0") || lower == "gzip" { return "gzip" }
        if lower.hasSuffix("/blosc/1.0") || lower == "blosc" { return "blosc" }
        if lower.hasSuffix("/zlib/1.0") || lower == "zlib" { return "zlib" }
        if lower.hasSuffix("/bz2/1.0") || lower == "bz2" { return "bz2" }
        if lower.hasSuffix("/bytes/1.0") || lower == "bytes" { return "bytes" }
        let parts = name.split(separator: "/")
        return String(parts.last ?? "unknown")
    }
}

/// Zarr specification version.
public enum ZarrVersion: String, Sendable, Equatable {
    case v2
    case v3
}

/// Convert V3 metadata fields to a V2-compatible compressor dictionary.
func v3CodecsToV2Compressor(_ codecs: [V3Codec]?) -> [String: AnyCodable]? {
    guard let codecs = codecs else { return nil }
    for codec in codecs {
        let shortName = codec.shortName
        switch shortName {
        case "gzip", "blosc", "zlib", "bz2":
            var config: [String: AnyCodable] = ["id": AnyCodable(shortName)]
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
func compressorDictToV3Codecs(_ compressor: [String: AnyCodable]) -> [V3Codec] {
    guard let id = compressor["id"]?.value as? String else { return [] }
    var config: [String: AnyCodable] = [:]
    for (key, value) in compressor where key != "id" {
        config[key] = value
    }
    return [V3Codec(name: id, configuration: config.isEmpty ? nil : config)]
}
