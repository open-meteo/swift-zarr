import Foundation

public enum ZarrArrayError: Error, Sendable, Equatable {
    case mismatchedDimensions(expected: Int, got: Int)
    case invalidChunkIndex([Int])
    case unsupportedCompressor(String)
    case invalidSlice(String)
    case invalidDataSize(expected: Int, got: Int)
}

private struct DerivedArrayProperties: Sendable {
    let dataType: ZarrDataType
    let shape: [Int]
    let chunkShape: [Int]
    let separator: String
    let numChunks: [Int]
    let arrayStride: [Int]
    let orderIsF: Bool
}

private enum ResolvedCodec: Sendable {
    case none
    case gzip
    case zlib
    case bz2(level: Int)
    case lz4
    case blosc(cname: String, clevel: CInt, shuffle: CInt, typesize: Int)
}

/// A flat buffer of chunk indices using a single heap allocation.
/// Each chunk's `ndim` coordinates are stored contiguously; chunk `i` occupies
/// `storage[i*ndim ..< (i+1)*ndim]`.
private struct ChunkIndexBuffer: Sendable {
    let ndim: Int
    private let storage: [Int]

    init(ndim: Int, storage: [Int]) {
        self.ndim = ndim
        self.storage = storage
    }

    /// Number of chunks in the buffer.
    var count: Int { ndim == 0 ? 1 : (storage.isEmpty ? 0 : storage.count / ndim) }

    /// Return the chunk indices for chunk `i` as a new `[Int]`.
    subscript(_ i: Int) -> [Int] {
        let start = i * ndim
        return Array(storage[start..<start + ndim])
    }
}

public struct ZarrArray: Sendable {
    public let storage: any Storage
    public let path: String
    public let metadata: V2ArrayMetadata
    public let dataType: ZarrDataType
    public let version: ZarrVersion

    private let _shape: [Int]
    private let _chunkShape: [Int]
    private let _numChunks: [Int]
    private let _separator: String
    private let _arrayStride: [Int]
    private let _orderIsF: Bool
    private let _resolvedCodecs: [ResolvedCodec]
    private let _v3Codecs: [V3Codec]
    private let _concurrentLimit: Int

    private static let v3ChunkPrefix = "data/c/"

    public var ndim: Int { _shape.count }
    public var elementSize: Int { dataType.elementSize }
    public var shape: [Int] { _shape }
    public var chunkShape: [Int] { _chunkShape }

    private static func normalizePath(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    public init(storage: any Storage, path: String) async throws {
        self.storage = storage
        let normalizedPath = Self.normalizePath(path)
        self.path = normalizedPath
        if try await storage.exists(path: normalizedPath + "/zarr.json") {
            let metadataData = try await storage.read(path: normalizedPath + "/zarr.json")
            let decoder = JSONDecoder()
            let v3meta = try decoder.decode(V3ArrayMetadata.self, from: metadataData)
            version = .v3
            let v2meta = Self.makeV2Meta(from: v3meta)
            self.metadata = v2meta
            let derived = try Self.computeDerived(from: v2meta)
            dataType = derived.dataType
            _shape = derived.shape
            _chunkShape = derived.chunkShape
            _separator = derived.separator
            _numChunks = derived.numChunks
            _arrayStride = derived.arrayStride
            _orderIsF = derived.orderIsF
            _resolvedCodecs = try Self.resolveCodecs(v3meta.codecs ?? [], elementSize: derived.dataType.elementSize)
            _v3Codecs = v3meta.codecs ?? []
            _concurrentLimit = max(4, ProcessInfo.processInfo.activeProcessorCount)
        } else {
            let metadataData = try await storage.read(path: normalizedPath + "/.zarray")
            let decoder = JSONDecoder()
            let meta = try decoder.decode(V2ArrayMetadata.self, from: metadataData)
            version = .v2
            self.metadata = meta
            let derived = try Self.computeDerived(from: meta)
            dataType = derived.dataType
            _shape = derived.shape
            _chunkShape = derived.chunkShape
            _separator = derived.separator
            _numChunks = derived.numChunks
            _arrayStride = derived.arrayStride
            _orderIsF = derived.orderIsF
            let v2Codecs = meta.compressor.map { compressorDictToV3Codecs($0) } ?? []
            _resolvedCodecs = try Self.resolveCodecs(v2Codecs, elementSize: derived.dataType.elementSize)
            _v3Codecs = v2Codecs
            _concurrentLimit = max(4, ProcessInfo.processInfo.activeProcessorCount)
        }
    }

    /// Create an array from in-memory V2 metadata without reading from storage.
    public init(metadata: V2ArrayMetadata, storage: any Storage, path: String) throws {
        self.storage = storage
        let normalizedPath = Self.normalizePath(path)
        self.path = normalizedPath
        version = .v2
        self.metadata = metadata
        let derived = try Self.computeDerived(from: metadata)
        dataType = derived.dataType
        _shape = derived.shape
        _chunkShape = derived.chunkShape
        _separator = derived.separator
        _numChunks = derived.numChunks
        _arrayStride = derived.arrayStride
        _orderIsF = derived.orderIsF
        let v2Codecs = metadata.compressor.map { compressorDictToV3Codecs($0) } ?? []
        _resolvedCodecs = try Self.resolveCodecs(v2Codecs, elementSize: derived.dataType.elementSize)
        _v3Codecs = v2Codecs
        _concurrentLimit = max(4, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Create an array from in-memory V3 metadata without reading from storage.
    public init(v3Metadata: V3ArrayMetadata, storage: any Storage, path: String) throws {
        self.storage = storage
        let normalizedPath = Self.normalizePath(path)
        self.path = normalizedPath
        version = .v3
        let v2meta = Self.makeV2Meta(from: v3Metadata)
        self.metadata = v2meta
        let derived = try Self.computeDerived(from: v2meta)
        dataType = derived.dataType
        _shape = derived.shape
        _chunkShape = derived.chunkShape
        _separator = derived.separator
        _numChunks = derived.numChunks
        _arrayStride = derived.arrayStride
        _orderIsF = derived.orderIsF
        _resolvedCodecs = try Self.resolveCodecs(v3Metadata.codecs ?? [], elementSize: derived.dataType.elementSize)
        _v3Codecs = v3Metadata.codecs ?? []
        _concurrentLimit = max(4, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Build a V2ArrayMetadata view of a V3ArrayMetadata, used internally during init.
    private static func makeV2Meta(from v3: V3ArrayMetadata) -> V2ArrayMetadata {
        V2ArrayMetadata(
            zarrFormat: 2,
            shape: v3.shape,
            chunks: v3.chunkGrid.configuration.chunkShape,
            dtype: v3.dataType,
            compressor: v3CodecsToV2Compressor(v3.codecs),
            fillValue: v3.fillValue,
            order: .C,
            filters: nil,
            dimensionSeparator: v3.chunkKeyEncoding?.configuration?.separator ?? "/"
        )
    }

    private static func resolveCodecs(_ codecs: [V3Codec], elementSize: Int) throws -> [ResolvedCodec] {
        try codecs.map { codec in
            let name = codec.shortName
            switch name {
            case "none", "bytes", "endian":
                return .none
            case "gzip":
                return .gzip
            case "zlib":
                return .zlib
            case "bz2":
                let level = codec.configuration?["level"]?.intValue ?? 5
                return .bz2(level: level)
            case "lz4":
                return .lz4
            case "blosc":
                let cname = codec.configuration?["cname"]?.stringValue ?? "lz4"
                let clevel = CInt(codec.configuration?["clevel"]?.intValue ?? 5)
                let shuffle = CInt(codec.configuration?["shuffle"]?.intValue ?? 1)
                let typesize = codec.configuration?["typesize"]?.intValue ?? elementSize
                return .blosc(cname: cname, clevel: clevel, shuffle: shuffle, typesize: typesize)
            default:
                throw ZarrArrayError.unsupportedCompressor(name)
            }
        }
    }

    private static func computeDerived(
        from meta: V2ArrayMetadata
    ) throws -> DerivedArrayProperties {
        let parsed = try ZarrDataType.parse(meta.dtype)
        let s = meta.shape.map(Int.init)
        let c = meta.chunks.map(Int.init)
        let ndim = s.count
        let separator = meta.dimensionSeparator ?? "."
        let numChunks = (0..<ndim).map { d in (s[d] + c[d] - 1) / c[d] }
        var stride = [Int](repeating: 1, count: ndim)
        if ndim >= 2 {
            for d in (0..<ndim - 1).reversed() {
                stride[d] = stride[d + 1] * s[d + 1]
            }
        }
        let orderIsF = meta.order == .F
        return DerivedArrayProperties(
            dataType: parsed,
            shape: s,
            chunkShape: c,
            separator: separator,
            numChunks: numChunks,
            arrayStride: stride,
            orderIsF: orderIsF
        )
    }

    /// Number of chunks per dimension (the chunk grid shape).
    public func chunkGridShape() -> [Int] { _numChunks }

    public var totalElements: Int {
        _shape.reduce(1, *)
    }

    /// Actual size of a specific chunk (edge chunks may be smaller than the nominal chunk shape).
    public func chunkSize(_ indices: [Int]) throws -> [Int] {
        guard indices.count == ndim else {
            throw ZarrArrayError.mismatchedDimensions(expected: ndim, got: indices.count)
        }
        let c = _chunkShape
        let s = _shape
        return (0..<ndim).map { d in
            let start = indices[d] * c[d]
            return min(c[d], s[d] - start)
        }
    }

    /// Build the storage key for a chunk.
    /// V2: `{i}.{j}.{k}` (separator-joined indices); scalar (0-D) uses `"0"`.
    /// V3: `data/c/{i}/{j}/{k}` (with prefix per Zarr V3 spec); scalar uses `"data/c/0"`.
    public func chunkKey(_ indices: [Int]) -> String {
        let key = indices.isEmpty ? "0" : indices.map(String.init).joined(separator: _separator)
        if version == .v3 {
            return Self.v3ChunkPrefix + key
        }
        return key
    }

    // MARK: - Typed reads

    /// Retrieve and decode a single chunk.
    /// If the chunk file does not exist, returns the fill value.
    public func retrieveChunk<T: ZarrElement>(_ indices: [Int]) async throws -> [T] {
        let data = try await readChunkRaw(indices)
        return try T.decode(data, endian: dataType.endian)
    }

    /// Retrieve and decode a single chunk, returning `nil` if the chunk file does not exist.
    public func retrieveChunkIfExists<T: ZarrElement>(_ indices: [Int]) async throws -> [T]? {
        try validateIndices(indices)
        let key = path + "/" + chunkKey(indices)
        guard try await storage.exists(path: key) else { return nil }
        let raw = try await storage.read(path: key)
        let data = try decompress(raw)
        return try T.decode(data, endian: dataType.endian)
    }

    /// Retrieve a sub-region of the array (slice read), crossing chunk boundaries as needed.
    public func retrieveArraySubset<T: ZarrElement>(_ ranges: [Range<Int>]) async throws -> [T] {
        guard dataType.matches(type: T.self) else {
            throw ZarrElementError.typeMismatch(
                expectedKind: T.zarrDtypeKind,
                expectedSize: T.zarrDtypeSize,
                actualDtype: metadata.dtype
            )
        }
        guard ranges.count == ndim else {
            throw ZarrArrayError.mismatchedDimensions(expected: ndim, got: ranges.count)
        }
        for d in 0..<ndim {
            guard ranges[d].lowerBound >= 0 && ranges[d].upperBound <= _shape[d] else {
                throw ZarrArrayError.invalidSlice(
                    "range \(ranges[d]) out of bounds for dimension \(d) (size \(_shape[d]))"
                )
            }
        }

        let outputShape = ranges.map { $0.count }
        let outputElements = outputShape.reduce(1, *)

        if outputElements == 0 {
            return []
        }

        // 0-D scalar array: single chunk, single element.
        if ndim == 0 {
            let data = try await readChunkRaw([])
            return try T.decode(data, endian: dataType.endian)
        }

        let elementSize = dataType.elementSize

        var outputStride = [Int](repeating: 1, count: ndim)
        for d in (0..<ndim - 1).reversed() {
            outputStride[d] = outputStride[d + 1] * outputShape[d + 1]
        }

        var firstChunk = [Int](repeating: 0, count: ndim)
        var lastChunk = [Int](repeating: 0, count: ndim)
        for d in 0..<ndim {
            firstChunk[d] = ranges[d].lowerBound / _chunkShape[d]
            lastChunk[d] = (ranges[d].upperBound - 1) / _chunkShape[d]
        }

        let chunkRanges = (0..<ndim).map { d in firstChunk[d]...lastChunk[d] }
        let intersectingChunks = collectChunkIndices(ranges: chunkRanges.map(Range.init))

        // Single-chunk fast path: avoids task group allocation.
        if intersectingChunks.count == 1 {
            let idx = intersectingChunks[0]
            let chunkData = try await readChunkRaw(idx)
            let chunkOrigin = (0..<ndim).map { idx[$0] * _chunkShape[$0] }
            let actualChunkSize = try chunkSize(idx)

            // If the request covers the entire chunk exactly, decode directly.
            let fullCoverage = (0..<ndim).allSatisfy {
                ranges[$0].lowerBound == chunkOrigin[$0]
                    && ranges[$0].upperBound == chunkOrigin[$0] + actualChunkSize[$0]
            }
            if fullCoverage {
                return try T.decode(chunkData, endian: dataType.endian)
            }

            // Partial coverage: assemble the slice into an output buffer.
            var output = Data(count: outputElements * elementSize)
            var localStart = [Int](repeating: 0, count: ndim)
            var localEnd = [Int](repeating: 0, count: ndim)
            var outputStart = [Int](repeating: 0, count: ndim)
            var localCount = [Int](repeating: 0, count: ndim)
            for d in 0..<ndim {
                localStart[d] = max(ranges[d].lowerBound - chunkOrigin[d], 0)
                localEnd[d] = min(ranges[d].upperBound - chunkOrigin[d], actualChunkSize[d])
                localCount[d] = localEnd[d] - localStart[d]
                outputStart[d] = chunkOrigin[d] + localStart[d] - ranges[d].lowerBound
            }
            var chunkLocalStride = [Int](repeating: 1, count: ndim)
            if _orderIsF {
                for d in 1..<ndim {
                    chunkLocalStride[d] = chunkLocalStride[d - 1] * actualChunkSize[d - 1]
                }
            } else {
                for d in (0..<ndim - 1).reversed() {
                    chunkLocalStride[d] = chunkLocalStride[d + 1] * actualChunkSize[d + 1]
                }
            }
            copyChunkSlice(
                chunkData: chunkData,
                into: &output,
                ndim: ndim,
                elementSize: elementSize,
                localCount: localCount,
                localStart: localStart,
                outputStart: outputStart,
                outputStride: outputStride,
                chunkLocalStride: chunkLocalStride
            )
            return try T.decode(output, endian: dataType.endian)
        }

        var output = Data(count: outputElements * elementSize)

        for batchStart in stride(from: 0, to: intersectingChunks.count, by: _concurrentLimit) {
            let batchEnd = min(batchStart + _concurrentLimit, intersectingChunks.count)

            try await withThrowingTaskGroup(
                of: (indices: [Int], data: Data).self
            ) { group in
                for i in batchStart..<batchEnd {
                    let indices = intersectingChunks[i]
                    group.addTask {
                        let data = try await self.readChunkRaw(indices)
                        return (indices, data)
                    }
                }

                for try await (indices, chunkData) in group {
                    let chunkOrigin = (0..<ndim).map { indices[$0] * _chunkShape[$0] }
                    let actualChunkSize = try chunkSize(indices)

                    var localStart = [Int](repeating: 0, count: ndim)
                    var localEnd = [Int](repeating: 0, count: ndim)
                    var outputStart = [Int](repeating: 0, count: ndim)
                    var localCount = [Int](repeating: 0, count: ndim)
                    for d in 0..<ndim {
                        localStart[d] = max(ranges[d].lowerBound - chunkOrigin[d], 0)
                        localEnd[d] = min(ranges[d].upperBound - chunkOrigin[d], actualChunkSize[d])
                        localCount[d] = localEnd[d] - localStart[d]
                        outputStart[d] = chunkOrigin[d] + localStart[d] - ranges[d].lowerBound
                    }

                    var chunkLocalStride = [Int](repeating: 1, count: ndim)
                    if _orderIsF {
                        for d in 1..<ndim {
                            chunkLocalStride[d] = chunkLocalStride[d - 1] * actualChunkSize[d - 1]
                        }
                    } else {
                        for d in (0..<ndim - 1).reversed() {
                            chunkLocalStride[d] = chunkLocalStride[d + 1] * actualChunkSize[d + 1]
                        }
                    }

                    copyChunkSlice(
                        chunkData: chunkData,
                        into: &output,
                        ndim: ndim,
                        elementSize: elementSize,
                        localCount: localCount,
                        localStart: localStart,
                        outputStart: outputStart,
                        outputStride: outputStride,
                        chunkLocalStride: chunkLocalStride
                    )
                }
            }
        }

        return try T.decode(output, endian: dataType.endian)
    }

    /// Retrieve the raw encoded bytes of a chunk (before codec decompression).
    /// Returns `nil` if the chunk file does not exist.
    func retrieveEncodedChunk(_ indices: [Int]) async throws -> Data? {
        try validateIndices(indices)
        let key = path + "/" + chunkKey(indices)
        guard try await storage.exists(path: key) else { return nil }
        return try await storage.read(path: key)
    }

    // MARK: - Internal

    /// Read and decompress a single chunk, returning decoded bytes in array byte order.
    /// Falls back to fill value if the chunk file does not exist.
    internal func readChunkRaw(_ indices: [Int]) async throws -> Data {
        try validateIndices(indices)
        let key = path + "/" + chunkKey(indices)
        if try await storage.exists(path: key) {
            let raw = try await storage.read(path: key)
            return try decompress(raw)
        } else {
            return try fillValueData(for: indices)
        }
    }

    /// Read the full array (all chunks) returning raw decoded bytes in row-major order.
    internal func readRaw() async throws -> Data {
        let totalBytes = totalElements * dataType.elementSize
        let allChunks = collectAllChunkIndices()
        let ndim = self.ndim
        let arrayShape = _shape
        let nominalChunkShape = _chunkShape
        let arrayStride = _arrayStride
        let elementSize = dataType.elementSize

        // Allocate without zero-initialization: every byte is written during chunk assembly.
        let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: totalBytes, alignment: MemoryLayout<UInt64>.alignment)

        do {
            for batchStart in stride(from: 0, to: allChunks.count, by: _concurrentLimit) {
                let batchEnd = min(batchStart + _concurrentLimit, allChunks.count)

                try await withThrowingTaskGroup(
                    of: (indices: [Int], data: Data).self
                ) { group in
                    for i in batchStart..<batchEnd {
                        let indices = allChunks[i]
                        group.addTask {
                            let data = try await self.readChunkRaw(indices)
                            return (indices, data)
                        }
                    }

                    for try await (indices, chunkData) in group {
                        let chunkStart = (0..<ndim).map { indices[$0] * nominalChunkShape[$0] }
                        let actualChunkSize = try self.chunkSize(indices)
                        let innerSize = ndim > 0 ? actualChunkSize[ndim - 1] : 1

                        chunkData.withUnsafeBytes { srcRaw in
                            guard let srcPtr = srcRaw.baseAddress else { return }

                            if ndim > 1 && actualChunkSize[ndim - 1] == arrayShape[ndim - 1] && !self._orderIsF {
                                let outerElements = actualChunkSize[0..<ndim - 1].reduce(1, *)
                                let innerByteCount = actualChunkSize[ndim - 1] * elementSize

                                var outerStride = [Int](repeating: 1, count: ndim - 1)
                                for d in (0..<ndim - 2).reversed() {
                                    outerStride[d] = outerStride[d + 1] * actualChunkSize[d + 1]
                                }

                                var srcOffset = 0
                                for outerFlat in 0..<outerElements {
                                    var globalBase = 0
                                    var tmp = outerFlat
                                    for d in 0..<ndim - 1 {
                                        let localCoord = tmp / outerStride[d]
                                        tmp %= outerStride[d]
                                        globalBase += (chunkStart[d] + localCoord) * arrayStride[d]
                                    }
                                    globalBase += chunkStart[ndim - 1] * arrayStride[ndim - 1]

                                    rawPtr.advanced(by: globalBase * elementSize)
                                        .copyMemory(from: srcPtr.advanced(by: srcOffset), byteCount: innerByteCount)
                                    srcOffset += innerSize * elementSize
                                }
                            } else {
                                let chunkElements = actualChunkSize.reduce(1, *)

                                var cStride = [Int](repeating: 1, count: ndim)
                                for d in (0..<ndim - 1).reversed() {
                                    cStride[d] = cStride[d + 1] * actualChunkSize[d + 1]
                                }

                                for localFlat in 0..<chunkElements {
                                    var globalFlat = 0
                                    if self._orderIsF {
                                        var remaining = localFlat
                                        for d in 0..<ndim {
                                            let localCoord = remaining % actualChunkSize[d]
                                            remaining /= actualChunkSize[d]
                                            globalFlat += (chunkStart[d] + localCoord) * arrayStride[d]
                                        }
                                    } else {
                                        var pos = localFlat
                                        for d in 0..<ndim {
                                            let localCoord = pos / cStride[d]
                                            pos %= cStride[d]
                                            globalFlat += (chunkStart[d] + localCoord) * arrayStride[d]
                                        }
                                    }
                                    rawPtr.advanced(by: globalFlat * elementSize)
                                        .copyMemory(
                                            from: srcPtr.advanced(by: localFlat * elementSize),
                                            byteCount: elementSize
                                        )
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            rawPtr.deallocate()
            throw error
        }

        return Data(bytesNoCopy: rawPtr, count: totalBytes, deallocator: .custom { ptr, _ in ptr.deallocate() })
    }

    internal func validateIndices(_ indices: [Int]) throws {
        guard indices.count == ndim else {
            throw ZarrArrayError.mismatchedDimensions(expected: ndim, got: indices.count)
        }
        for d in 0..<ndim {
            guard indices[d] >= 0 && indices[d] < _numChunks[d] else {
                throw ZarrArrayError.invalidChunkIndex(indices)
            }
        }
    }

    // MARK: - Write

    /// Write the array metadata to storage (`.zarray` for V2, `zarr.json` for V3).
    public func storeMetadata() async throws {
        let encoder = JSONEncoder()
        switch version {
        case .v2:
            let data = try encoder.encode(metadata)
            try await storage.write(path: path + "/.zarray", data: data)
        case .v3:
            let v3meta = V3ArrayMetadata(
                zarrFormat: 3,
                nodeType: "array",
                shape: metadata.shape,
                dataType: metadata.dtype,
                chunkGrid: .init(
                    name: "regular",
                    configuration: .init(chunkShape: metadata.chunks)
                ),
                chunkKeyEncoding: .init(
                    name: "default",
                    configuration: .init(separator: _separator)
                ),
                fillValue: metadata.fillValue,
                codecs: _v3Codecs.isEmpty ? nil : _v3Codecs,
                storageTransformers: nil,
                dimensionNames: nil,
                attributes: nil
            )
            let data = try encoder.encode(v3meta)
            try await storage.write(path: path + "/zarr.json", data: data)
        }
    }

    /// Encode and store a single chunk. `data` must contain exactly
    /// `chunkSize * elementSize` bytes in row-major C order.
    public func storeChunk(_ indices: [Int], data: Data) async throws {
        try validateIndices(indices)
        let expectedSize = try chunkSize(indices).reduce(1, *) * dataType.elementSize
        guard data.count == expectedSize else {
            throw ZarrArrayError.invalidDataSize(expected: expectedSize, got: data.count)
        }
        let encoded = try encode(data)
        let key = path + "/" + chunkKey(indices)
        try await storage.write(path: key, data: encoded)
    }

    /// Delete a single chunk from storage.
    public func eraseChunk(_ indices: [Int]) async throws {
        try validateIndices(indices)
        let key = path + "/" + chunkKey(indices)
        try await storage.delete(path: key)
    }

    // MARK: - Private helpers

    private func decompress(_ data: Data) throws -> Data {
        var result = data
        for codec in _resolvedCodecs.reversed() {
            result = try applyResolvedCodec(codec, data: result, direction: .decode)
        }
        return result
    }

    private func encode(_ data: Data) throws -> Data {
        var result = data
        for codec in _resolvedCodecs {
            result = try applyResolvedCodec(codec, data: result, direction: .encode)
        }
        return result
    }

    private enum CodecDirection {
        case encode, decode
    }

    private func applyResolvedCodec(_ codec: ResolvedCodec, data: Data, direction: CodecDirection) throws -> Data {
        switch codec {
        case .none:
            return data
        case .gzip:
            let c = GzipCodec()
            return direction == .encode ? try c.encode(data) : try c.decode(data)
        case .zlib:
            let c = ZlibCodec()
            return direction == .encode ? try c.encode(data) : try c.decode(data)
        case .bz2(let level):
            let c = BZip2Codec(level: level)
            return direction == .encode ? try c.encode(data) : try c.decode(data)
        case .lz4:
            let c = LZ4Codec()
            return direction == .encode ? try c.encode(data) : try c.decode(data)
        case .blosc(let cname, let clevel, let shuffle, let typesize):
            let c = BloscCodec(clevel: clevel, shuffle: shuffle, typesize: typesize, compressorName: cname)
            return direction == .encode ? try c.encode(data) : try c.decode(data)
        }
    }

    private func fillValueData(for indices: [Int]) throws -> Data {
        let chunkSize = try chunkSize(indices)
        let numElements = chunkSize.reduce(1, *)
        let es = dataType.elementSize
        let byteCount = numElements * es
        if let singleValue = fillValueAsData() {
            var result = Data(count: byteCount)
            result.withUnsafeMutableBytes { dst in
                guard let dstPtr = dst.baseAddress else { return }
                singleValue.withUnsafeBytes { src in
                    guard let srcPtr = src.baseAddress else { return }
                    // Seed the first element.
                    dstPtr.copyMemory(from: srcPtr, byteCount: es)
                    // Doubling copy: filled region doubles each iteration.
                    var filled = es
                    while filled < byteCount {
                        let toCopy = min(filled, byteCount - filled)
                        dstPtr.advanced(by: filled).copyMemory(from: dstPtr, byteCount: toCopy)
                        filled += toCopy
                    }
                }
            }
            return result
        }
        return Data(repeating: 0, count: byteCount)
    }

    private func fillValueAsData() -> Data? {
        guard let fillValue = metadata.fillValue else { return nil }
        let size = dataType.elementSize

        switch fillValue {
        case .null:
            return nil
        case .string(let string):
            return fillValueFromString(string, size: size)
        case .bool(let b):
            return Data([b ? 1 : 0])
        case .int(let v):
            switch dataType.kind {
            case .int:
                switch size {
                case 1: return dataType.data(from: Int8(truncatingIfNeeded: v))
                case 2: return dataType.data(from: Int16(truncatingIfNeeded: v))
                case 4: return dataType.data(from: Int32(truncatingIfNeeded: v))
                case 8: return dataType.data(from: Int64(v))
                default: return nil
                }
            case .uint:
                switch size {
                case 1: return dataType.data(from: UInt8(truncatingIfNeeded: v))
                case 2: return dataType.data(from: UInt16(truncatingIfNeeded: v))
                case 4: return dataType.data(from: UInt32(truncatingIfNeeded: v))
                case 8: return dataType.data(from: UInt64(v))
                default: return nil
                }
            case .float:
                if size == 4 { return dataType.data(from: Float(v)) }
                return dataType.data(from: Double(v))
            case .bool:
                return Data([v == 0 ? 0 : 1])
            case .complex:
                return Data(repeating: 0, count: size)
            }
        case .double(let v):
            switch dataType.kind {
            case .float where size == 4: return dataType.data(from: Float(v))
            case .float: return dataType.data(from: v)
            case .int:
                let iv = Int64(v)
                switch size {
                case 1: return dataType.data(from: Int8(truncatingIfNeeded: iv))
                case 2: return dataType.data(from: Int16(truncatingIfNeeded: iv))
                case 4: return dataType.data(from: Int32(truncatingIfNeeded: iv))
                default: return dataType.data(from: iv)
                }
            default: return nil
            }
        case .array, .object:
            return nil
        }
    }

    private func fillValueFromString(_ string: String, size: Int) -> Data? {
        switch (dataType.kind, size) {
        case (.float, 4):
            let v: Float
            switch string {
            case "NaN": v = Float(bitPattern: 0x7fc0_0000)
            case "Infinity": v = Float.infinity
            case "-Infinity": v = -Float.infinity
            default:
                if string.hasPrefix("0x") || string.hasPrefix("0X"),
                    let raw = UInt32(string.dropFirst(2), radix: 16)
                {
                    v = Float(bitPattern: raw)
                } else {
                    return nil
                }
            }
            return dataType.data(from: v)
        case (.float, 8):
            let v: Double
            switch string {
            case "NaN": v = Double(bitPattern: 0x7ff8_0000_0000_0000)
            case "Infinity": v = Double.infinity
            case "-Infinity": v = -Double.infinity
            default:
                if string.hasPrefix("0x") || string.hasPrefix("0X"),
                    let raw = UInt64(string.dropFirst(2), radix: 16)
                {
                    v = Double(bitPattern: raw)
                } else {
                    return nil
                }
            }
            return dataType.data(from: v)
        case (.int, let s) where s <= 8:
            guard let raw = Int64(string) else { return nil }
            switch s {
            case 1: return dataType.data(from: Int8(truncatingIfNeeded: raw))
            case 2: return dataType.data(from: Int16(truncatingIfNeeded: raw))
            case 4: return dataType.data(from: Int32(truncatingIfNeeded: raw))
            default: return dataType.data(from: raw)
            }
        case (.uint, let s) where s <= 8:
            guard let raw = UInt64(string) else { return nil }
            switch s {
            case 1: return dataType.data(from: UInt8(truncatingIfNeeded: raw))
            case 2: return dataType.data(from: UInt16(truncatingIfNeeded: raw))
            case 4: return dataType.data(from: UInt32(truncatingIfNeeded: raw))
            default: return dataType.data(from: raw)
            }
        default:
            return string.data(using: .utf8)
        }
    }

    private func collectAllChunkIndices() -> ChunkIndexBuffer {
        collectChunkIndices(ranges: _numChunks.map { 0..<$0 })
    }

    /// Copy a slice of `chunkData` into `output`, handling both C-order and F-order layouts.
    private func copyChunkSlice(
        chunkData: Data,
        into output: inout Data,
        ndim: Int,
        elementSize: Int,
        localCount: [Int],
        localStart: [Int],
        outputStart: [Int],
        outputStride: [Int],
        chunkLocalStride: [Int]
    ) {
        output.withUnsafeMutableBytes { dstRaw in
            chunkData.withUnsafeBytes { srcRaw in
                guard let dstPtr = dstRaw.baseAddress, let srcPtr = srcRaw.baseAddress else { return }
                if _orderIsF {
                    let localElements = localCount.reduce(1, *)
                    for flat in 0..<localElements {
                        var pos = flat
                        var outputFlat = 0
                        var chunkFlat = 0
                        for d in 0..<ndim {
                            let localOffset = pos % localCount[d]
                            pos /= localCount[d]
                            outputFlat += (outputStart[d] + localOffset) * outputStride[d]
                            chunkFlat += (localStart[d] + localOffset) * chunkLocalStride[d]
                        }
                        dstPtr.advanced(by: outputFlat * elementSize)
                            .copyMemory(from: srcPtr.advanced(by: chunkFlat * elementSize), byteCount: elementSize)
                    }
                } else if ndim > 1 {
                    let innerCount = localCount[ndim - 1]
                    let innerByteCount = innerCount * elementSize
                    let outerElements = localCount[0..<ndim - 1].reduce(1, *)

                    var localStride = [Int](repeating: 1, count: ndim)
                    for d in (0..<ndim - 2).reversed() {
                        localStride[d] = localStride[d + 1] * localCount[d + 1]
                    }

                    for outerFlat in 0..<outerElements {
                        var pos = outerFlat
                        var outputRowStart = 0
                        var chunkRowStart = 0
                        for d in 0..<ndim - 1 {
                            let localOffset = pos / localStride[d]
                            pos %= localStride[d]
                            outputRowStart += (outputStart[d] + localOffset) * outputStride[d]
                            chunkRowStart += (localStart[d] + localOffset) * chunkLocalStride[d]
                        }
                        outputRowStart += outputStart[ndim - 1] * outputStride[ndim - 1]
                        chunkRowStart += localStart[ndim - 1] * chunkLocalStride[ndim - 1]
                        dstPtr.advanced(by: outputRowStart * elementSize)
                            .copyMemory(
                                from: srcPtr.advanced(by: chunkRowStart * elementSize),
                                byteCount: innerByteCount
                            )
                    }
                } else {
                    let byteCount = localCount[0] * elementSize
                    dstPtr.advanced(by: outputStart[0] * elementSize)
                        .copyMemory(from: srcPtr.advanced(by: localStart[0] * elementSize), byteCount: byteCount)
                }
            }
        }
    }

    /// Collect all chunk indices within the given ranges (one range per dimension).
    private func collectChunkIndices(ranges: [Range<Int>]) -> ChunkIndexBuffer {
        let ndim = ranges.count
        let chunkCount = ranges.isEmpty ? 1 : ranges.map({ $0.count }).reduce(1, *)
        var flat = [Int]()
        flat.reserveCapacity(chunkCount * ndim)
        var current = [Int](repeating: 0, count: ndim)

        func collect(dim: Int) {
            if dim == ndim {
                flat.append(contentsOf: current)
                return
            }
            for i in ranges[dim] {
                current[dim] = i
                collect(dim: dim + 1)
            }
        }
        collect(dim: 0)
        return ChunkIndexBuffer(ndim: ndim, storage: flat)
    }
}
