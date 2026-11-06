import Foundation

internal enum Serializer: Sendable {
    case bytes(endian: ZarrDataType.Endian)

    var endian: ZarrDataType.Endian {
        switch self {
        case .bytes(let endian): return endian
        }
    }
}

/// A validated serializer followed by zero or more byte compressors.
/// Raw input/output bytes use the serializer's byte order; ZarrElement handles typed decoding.
internal struct CodecPipeline: Sendable {
    let serializer: Serializer
    private let compressors: [any Codec]

    init(v2 metadata: V2ArrayMetadata, dataType: ZarrDataType) throws {
        serializer = .bytes(endian: dataType.endian)
        let codecs = metadata.compressor.map { compressorDictToV3Codecs($0) } ?? []
        if metadata.compressor != nil && codecs.isEmpty {
            throw ZarrArrayError.invalidCodecConfiguration("V2 compressor requires an id")
        }
        compressors = try codecs.filter { $0.name != "none" }.map {
            try Self.resolveCompressor($0, elementSize: dataType.elementSize)
        }
    }

    init(v3 codecs: [V3Codec], dataType: ZarrDataType) throws {
        var serializer: Serializer?
        var compressors: [any Codec] = []
        for codec in codecs {
            if codec.name == "bytes" {
                guard serializer == nil else {
                    throw ZarrArrayError.invalidCodecConfiguration("Only one serializer is allowed")
                }
                let endian: ZarrDataType.Endian
                switch codec.configuration?["endian"] {
                case .string("little"): endian = .little
                case .string("big"): endian = .big
                case nil where dataType.elementSize == 1: endian = .none
                default:
                    throw ZarrArrayError.invalidCodecConfiguration("bytes: endian must be little or big")
                }
                serializer = .bytes(endian: dataType.elementSize == 1 ? .none : endian)
            } else {
                // Resolve first so unsupported transforms/serializers are reported by name.
                let resolved = try Self.resolveCompressor(codec, elementSize: dataType.elementSize)
                guard serializer != nil else {
                    throw ZarrArrayError.invalidCodecConfiguration("Compression must follow the serializer")
                }
                compressors.append(resolved)
            }
        }
        guard let serializer else {
            throw ZarrArrayError.invalidCodecConfiguration("A serializer is required")
        }
        self.serializer = serializer
        self.compressors = compressors
    }

    private static func resolveCompressor(_ codec: V3Codec, elementSize: Int) throws -> any Codec {
        let name = codec.shortName
        switch name {
        case "gzip":
            return GzipCodec()
        case "zlib":
            return ZlibCodec()
        case "bz2":
            let level = codec.configuration?["level"]?.intValue ?? 5
            return BZip2Codec(level: level)
        case "lz4":
            return LZ4Codec()
        case "blosc":
            let cname = codec.configuration?["cname"]?.stringValue ?? "lz4"
            let clevel = CInt(codec.configuration?["clevel"]?.intValue ?? 5)
            let shuffle = CInt(codec.configuration?["shuffle"]?.intValue ?? 1)
            let typesize = codec.configuration?["typesize"]?.intValue ?? elementSize
            return BloscCodec(clevel: clevel, shuffle: shuffle, typesize: typesize, compressorName: cname)
        default:
            throw ZarrArrayError.unsupportedCompressor(name)
        }
    }

    func decode(_ data: Data) throws -> Data {
        var result = data
        for codec in compressors.reversed() {
            result = try codec.decode(result)
        }
        return result
    }

    func encode(_ data: Data) throws -> Data {
        var result = data
        for codec in compressors {
            result = try codec.encode(result)
        }
        return result
    }

}
