/// Resolved chunk addressing, shared by V2 arrays and V3 key encodings.
internal enum ChunkKeyEncoding: Sendable {
    case `default`(separator: String)
    case v2(separator: String)

    init(v3 metadata: V3ArrayMetadata.ChunkKeyEncoding?) throws {
        let name = metadata?.name ?? "default"
        let separator = metadata?.configuration?.separator
        switch name {
        case "default": self = .default(separator: separator ?? "/")
        case "v2": self = .v2(separator: separator ?? ".")
        default: throw ZarrArrayError.unsupportedChunkKeyEncoding(name)
        }
        if let separator, separator != "/" && separator != "." {
            throw ZarrArrayError.invalidChunkKeySeparator(separator)
        }
    }

    func key(_ indices: [Int]) -> String {
        switch self {
        case .default(let separator):
            return (["c"] + indices.map(String.init)).joined(separator: separator)
        case .v2(let separator):
            return indices.isEmpty ? "0" : indices.map(String.init).joined(separator: separator)
        }
    }

    var v3Metadata: V3ArrayMetadata.ChunkKeyEncoding {
        switch self {
        case .default(let separator):
            return .init(name: "default", configuration: .init(separator: separator))
        case .v2(let separator):
            return .init(name: "v2", configuration: .init(separator: separator))
        }
    }
}
