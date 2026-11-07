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
        guard metadata.filters?.isEmpty != false else {
            throw ZarrArrayError.unsupportedFilters
        }
        serializer = .bytes(endian: dataType.endian)
        let codecs = metadata.compressor.map { compressorDictToV3Codecs($0) } ?? []
        if metadata.compressor != nil && codecs.isEmpty {
            throw ZarrArrayError.invalidCodecConfiguration("V2 compressor requires an id")
        }
        compressors = try codecs.filter { $0.name != "none" }.map {
            try Self.resolveCompressor($0, elementSize: dataType.elementSize, version: .v2)
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
                let resolved = try Self.resolveCompressor(codec, elementSize: dataType.elementSize, version: .v3)
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

    private static func resolveCompressor(
        _ codec: V3Codec,
        elementSize: Int,
        version: ZarrVersion
    ) throws
        -> any Codec
    {
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
            let config = codec.configuration ?? [:]
            let typesize: Int
            if let value = config["typesize"] {
                guard let integer = value.intValue, (1...255).contains(integer) else {
                    throw ZarrArrayError.invalidCodecConfiguration("blosc: typesize must be in 1...255")
                }
                typesize = integer
            } else {
                typesize = elementSize
            }
            let shuffle: CInt
            switch version {
            case .v3:
                switch config["shuffle"] ?? .string("shuffle") {
                case .string("noshuffle"): shuffle = 0
                case .string("shuffle"): shuffle = 1
                case .string("bitshuffle"): shuffle = 2
                default: throw ZarrArrayError.invalidCodecConfiguration("blosc: invalid shuffle mode")
                }
                guard shuffle == 0 || config["typesize"] != nil else {
                    throw ZarrArrayError.invalidCodecConfiguration("blosc: typesize is required when shuffling")
                }
            case .v2:
                guard let mode = (config["shuffle"] ?? .int(1)).intValue, (-1...2).contains(mode) else {
                    throw ZarrArrayError.invalidCodecConfiguration("blosc: shuffle must be in -1...2")
                }
                // Numcodecs auto uses bitshuffle for byte strides, byte shuffle otherwise.
                shuffle = mode == -1 ? (typesize == 1 ? 2 : 1) : CInt(mode)
            }
            let blockSize: Int
            if let value = codec.configuration?["blocksize"] {
                guard let integer = value.intValue else {
                    throw ZarrArrayError.invalidCodecConfiguration("blosc: blocksize must be an integer")
                }
                blockSize = integer
            } else {
                blockSize = 0
            }
            try BloscCodec.validateBlockSize(blockSize)
            return BloscCodec(
                clevel: clevel,
                shuffle: shuffle,
                typesize: typesize,
                compressorName: cname,
                blockSize: blockSize
            )
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
