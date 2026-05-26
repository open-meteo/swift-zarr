import Foundation

public enum ZarrArrayError: Error, Sendable, Equatable {
    case mismatchedDimensions(expected: Int, got: Int)
    case invalidChunkIndex([Int])
    case unsupportedCompressor(String)
    case invalidSlice(String)
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
    internal let _orderIsF: Bool
    private let _v3Codecs: [V3Codec]

    public var ndim: Int { _shape.count }
    public var elementSize: Int { dataType.elementSize }
    public var shape: [Int] { _shape }
    public var chunkShape: [Int] { _chunkShape }

    public init(storage: any Storage, path: String) async throws {
        self.storage = storage
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        self.path = normalizedPath
        if try await storage.exists(path: normalizedPath + "/zarr.json") {
            let metadataData = try await storage.read(path: normalizedPath + "/zarr.json")
            let decoder = JSONDecoder()
            let v3meta = try decoder.decode(V3ArrayMetadata.self, from: metadataData)
            version = .v3
            let v2meta = V2ArrayMetadata(
                zarrFormat: 2,
                shape: v3meta.shape,
                chunks: v3meta.chunkGrid.configuration.chunkShape,
                dtype: v3meta.dataType,
                compressor: v3CodecsToV2Compressor(v3meta.codecs),
                fillValue: v3meta.fillValue,
                order: .C,
                filters: nil,
                dimensionSeparator: v3meta.chunkKeyEncoding?.configuration?.separator
            )
            self.metadata = v2meta
            (dataType, _shape, _chunkShape, _separator, _numChunks, _arrayStride, _orderIsF) =
                try Self.computeDerived(from: v2meta)
            _v3Codecs = v3meta.codecs ?? []
        } else {
            let metadataData = try await storage.read(path: normalizedPath + "/.zarray")
            let decoder = JSONDecoder()
            let meta = try decoder.decode(V2ArrayMetadata.self, from: metadataData)
            version = .v2
            self.metadata = meta
            (dataType, _shape, _chunkShape, _separator, _numChunks, _arrayStride, _orderIsF) =
                try Self.computeDerived(from: meta)
            _v3Codecs = meta.compressor.map { compressorDictToV3Codecs($0) } ?? []
        }
    }

    /// Create an array from in-memory V2 metadata without reading from storage.
    public init(metadata: V2ArrayMetadata, storage: any Storage, path: String) throws {
        self.storage = storage
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        self.path = normalizedPath
        version = .v2
        self.metadata = metadata
        (dataType, _shape, _chunkShape, _separator, _numChunks, _arrayStride, _orderIsF) =
            try Self.computeDerived(from: metadata)
        _v3Codecs = metadata.compressor.map { compressorDictToV3Codecs($0) } ?? []
    }

    /// Create an array from in-memory V3 metadata without reading from storage.
    public init(v3Metadata: V3ArrayMetadata, storage: any Storage, path: String) throws {
        self.storage = storage
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        self.path = normalizedPath
        version = .v3
        let v2meta = V2ArrayMetadata(
            zarrFormat: 2,
            shape: v3Metadata.shape,
            chunks: v3Metadata.chunkGrid.configuration.chunkShape,
            dtype: v3Metadata.dataType,
            compressor: v3CodecsToV2Compressor(v3Metadata.codecs),
            fillValue: v3Metadata.fillValue,
            order: .C,
            filters: nil,
            dimensionSeparator: v3Metadata.chunkKeyEncoding?.configuration?.separator
        )
        self.metadata = v2meta
        (dataType, _shape, _chunkShape, _separator, _numChunks, _arrayStride, _orderIsF) =
            try Self.computeDerived(from: v2meta)
        _v3Codecs = v3Metadata.codecs ?? []
    }

    private static func computeDerived(
        from meta: V2ArrayMetadata
    ) throws -> (
        ZarrDataType, [Int], [Int], String, [Int], [Int], Bool
    ) {
        let parsed = try ZarrDataType.parse(meta.dtype)
        let s = meta.shape.map(Int.init)
        let c = meta.chunks.map(Int.init)
        let ndim = s.count
        let separator = meta.dimensionSeparator ?? "."
        let numChunks = (0..<ndim).map { d in (s[d] + c[d] - 1) / c[d] }
        var stride = [Int](repeating: 1, count: ndim)
        for d in (0..<ndim - 1).reversed() {
            stride[d] = stride[d + 1] * s[d + 1]
        }
        let orderIsF = meta.order == .F
        return (parsed, s, c, separator, numChunks, stride, orderIsF)
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
    /// V2: `{i}.{j}.{k}` (separator-joined indices)
    /// V3: `data/c/{i}/{j}/{k}` (with prefix)
    public func chunkKey(_ indices: [Int]) -> String {
        let key = indices.map(String.init).joined(separator: _separator)
        if version == .v3 {
            return "data/c/" + key
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

        var intersectingChunks: [[Int]] = []
        var current = [Int](repeating: 0, count: ndim)
        func collect(dim: Int) {
            if dim == ndim {
                intersectingChunks.append(current)
                return
            }
            for i in firstChunk[dim]...lastChunk[dim] {
                current[dim] = i
                collect(dim: dim + 1)
            }
        }
        collect(dim: 0)

        var output = Data(count: outputElements * elementSize)
        let concurrentLimit = max(4, ProcessInfo.processInfo.activeProcessorCount)

        for batchStart in stride(from: 0, to: intersectingChunks.count, by: concurrentLimit) {
            let batchEnd = min(batchStart + concurrentLimit, intersectingChunks.count)

            try await withThrowingTaskGroup(
                of: (indices: [Int], data: Data).self
            ) { group in
                for i in batchStart..<batchEnd {
                    let indices = intersectingChunks[i]
                    group.addTask {
                        let key = self.path + "/" + self.chunkKey(indices)
                        if try await self.storage.exists(path: key) {
                            let raw = try await self.storage.read(path: key)
                            let data = try self.decompress(raw)
                            return (indices, data)
                        } else {
                            let data = try self.fillValueData(for: indices)
                            return (indices, data)
                        }
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

                    let innerCount = localCount[ndim - 1]
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
                            let dstOff = outputFlat * elementSize
                            let srcOff = chunkFlat * elementSize
                            output[dstOff..<dstOff + elementSize] =
                                chunkData[srcOff..<srcOff + elementSize]
                        }
                    } else if ndim > 1 {
                        let innerByteCount = innerCount * elementSize
                        let outerElements = localCount[0..<ndim - 1].reduce(1, *)

                        for outerFlat in 0..<outerElements {
                            var pos = outerFlat
                            var outputRowStart = 0
                            var chunkRowStart = 0
                            for d in 0..<ndim - 1 {
                                let stride = (d + 1..<ndim - 1).reduce(1) { $0 * localCount[$1] }
                                let localOffset = pos / stride
                                pos %= stride
                                outputRowStart += (outputStart[d] + localOffset) * outputStride[d]
                                chunkRowStart += (localStart[d] + localOffset) * chunkLocalStride[d]
                            }
                            outputRowStart += outputStart[ndim - 1] * outputStride[ndim - 1]
                            chunkRowStart += localStart[ndim - 1] * chunkLocalStride[ndim - 1]

                            let dstOff = outputRowStart * elementSize
                            let srcOff = chunkRowStart * elementSize
                            output[dstOff..<dstOff + innerByteCount] =
                                chunkData[srcOff..<srcOff + innerByteCount]
                        }
                    } else {
                        let dstOff = outputStart[0] * elementSize
                        let srcOff = localStart[0] * elementSize
                        let byteCount = innerCount * elementSize
                        output[dstOff..<dstOff + byteCount] =
                            chunkData[srcOff..<srcOff + byteCount]
                    }
                }
            }
        }

        return try T.decode(output, endian: dataType.endian)
    }

    /// Retrieve the raw encoded bytes of a chunk (before codec decompression).
    /// Returns `nil` if the chunk file does not exist.
    public func retrieveEncodedChunk(_ indices: [Int]) async throws -> Data? {
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
        var output = Data(count: totalBytes)
        let allChunks = collectAllChunkIndices()
        let concurrentLimit = max(4, ProcessInfo.processInfo.activeProcessorCount)
        let ndim = self.ndim
        let shape = _shape
        let chunkShape = _chunkShape
        let arrayStride = _arrayStride
        let elementSize = dataType.elementSize

        for batchStart in stride(from: 0, to: allChunks.count, by: concurrentLimit) {
            let batchEnd = min(batchStart + concurrentLimit, allChunks.count)

            try await withThrowingTaskGroup(
                of: (indices: [Int], data: Data).self
            ) { group in
                for i in batchStart..<batchEnd {
                    let indices = allChunks[i]
                    group.addTask {
                        let key = self.path + "/" + self.chunkKey(indices)
                        if try await self.storage.exists(path: key) {
                            let raw = try await self.storage.read(path: key)
                            let data = try self.decompress(raw)
                            return (indices, data)
                        } else {
                            let data = try self.fillValueData(for: indices)
                            return (indices, data)
                        }
                    }
                }

                for try await (indices, chunkData) in group {
                    let chunkStart = (0..<ndim).map { indices[$0] * chunkShape[$0] }
                    let chunkSize = try self.chunkSize(indices)
                    let innerSize = ndim > 0 ? chunkSize[ndim - 1] : 1

                    if ndim > 1 && chunkSize[ndim - 1] == shape[ndim - 1] && !self._orderIsF {
                        let outerElements = chunkSize[0..<ndim - 1].reduce(1, *)
                        let innerByteCount = chunkSize[ndim - 1] * elementSize

                        var remaining = 0
                        for outerFlat in 0..<outerElements {
                            var globalBase = 0
                            var tmp = outerFlat
                            for d in 0..<ndim - 1 {
                                let stride = (d + 1..<ndim - 1).reduce(1) { $0 * chunkSize[$1] }
                                let localCoord = tmp / stride
                                tmp %= stride
                                globalBase += (chunkStart[d] + localCoord) * arrayStride[d]
                            }
                            globalBase += chunkStart[ndim - 1] * arrayStride[ndim - 1]

                            let globalRowStart = globalBase * elementSize
                            let subRowStart = remaining * elementSize
                            output[globalRowStart..<globalRowStart + innerByteCount] =
                                chunkData[subRowStart..<subRowStart + innerByteCount]
                            remaining += innerSize
                        }
                    } else {
                        let chunkElements = chunkSize.reduce(1, *)

                        for localFlat in 0..<chunkElements {
                            var globalFlat = 0
                            if self._orderIsF {
                                var remaining = localFlat
                                for d in 0..<ndim {
                                    let localCoord = remaining % chunkSize[d]
                                    remaining /= chunkSize[d]
                                    let globalCoord = chunkStart[d] + localCoord
                                    globalFlat += globalCoord * arrayStride[d]
                                }
                            } else {
                                var pos = localFlat
                                for d in 0..<ndim {
                                    let cStride = (d + 1..<ndim).reduce(1) { $0 * chunkSize[$1] }
                                    let localCoord = pos / cStride
                                    pos %= cStride
                                    let globalCoord = chunkStart[d] + localCoord
                                    globalFlat += globalCoord * arrayStride[d]
                                }
                            }
                            let srcOff = localFlat * elementSize
                            let dstOff = globalFlat * elementSize
                            output[dstOff..<dstOff + elementSize] = chunkData[srcOff..<srcOff + elementSize]
                        }
                    }
                }
            }
        }

        return output
    }

    internal func validateIndices(_ indices: [Int]) throws {
        guard indices.count == ndim else {
            throw ZarrArrayError.mismatchedDimensions(expected: ndim, got: indices.count)
        }
        for d in 0..<ndim {
            guard indices[d] < _numChunks[d] else {
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
                zarrFormat: "https://purl.org/zarr/spec/protocol/core/3.0",
                metadataEncoding: "https://purl.org/zarr/spec/protocol/core/3.0",
                metadataKey: "/",
                shape: metadata.shape,
                dataType: metadata.dtype,
                chunkGrid: .init(
                    name: "regular",
                    configuration: .init(chunkShape: metadata.chunks)
                ),
                chunkKeyEncoding: .init(
                    name: "default",
                    configuration: .init(separator: "/")
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
        for codec in _v3Codecs.reversed() {
            result = try applyCodec(codec, data: result, direction: .decode)
        }
        return result
    }

    private func encode(_ data: Data) throws -> Data {
        var result = data
        for codec in _v3Codecs {
            result = try applyCodec(codec, data: result, direction: .encode)
        }
        return result
    }

    private enum CodecDirection {
        case encode, decode
    }

    private func applyCodec(_ codec: V3Codec, data: Data, direction: CodecDirection) throws -> Data {
        let name = codec.shortName
        switch name {
        case "none", "bytes":
            return data
        case "gzip":
            let c = GzipCodec()
            return direction == .encode ? try c.encode(data) : try c.decode(data)
        case "zlib":
            let c = ZlibCodec()
            return direction == .encode ? try c.encode(data) : try c.decode(data)
        case "bz2":
            let level = codec.configuration?["level"]?.value as? Int ?? 5
            let c = BZip2Codec(level: level)
            return direction == .encode ? try c.encode(data) : try c.decode(data)
        case "lz4":
            let c = LZ4Codec()
            return direction == .encode ? try c.encode(data) : try c.decode(data)
        case "blosc":
            let cname = codec.configuration?["cname"]?.value as? String ?? "lz4"
            let clevel = CInt(codec.configuration?["clevel"]?.value as? Int ?? 5)
            let shuffle = CInt(codec.configuration?["shuffle"]?.value as? Int ?? 1)
            let typesize = codec.configuration?["typesize"]?.value as? Int ?? dataType.elementSize
            let c = BloscCodec(clevel: clevel, shuffle: shuffle, typesize: typesize, compressorName: cname)
            return direction == .encode ? try c.encode(data) : try c.decode(data)
        default:
            throw ZarrArrayError.unsupportedCompressor(name)
        }
    }

    private func fillValueData(for indices: [Int]) throws -> Data {
        let chunkSize = try chunkSize(indices)
        let numElements = chunkSize.reduce(1, *)
        let elementSize = dataType.elementSize
        let byteCount = numElements * elementSize
        if let singleValue = fillValueAsData() {
            var result = Data(count: byteCount)
            result.withUnsafeMutableBytes { dst in
                guard let dstPtr = dst.baseAddress else { return }
                singleValue.withUnsafeBytes { src in
                    guard let srcPtr = src.baseAddress else { return }
                    for i in 0..<numElements {
                        dstPtr.advanced(by: i * elementSize)
                            .copyMemory(from: srcPtr, byteCount: elementSize)
                    }
                }
            }
            return result
        }
        return Data(repeating: 0, count: byteCount)
    }

    private func fillValueAsData() -> Data? {
        guard let fillValue = metadata.fillValue?.value else { return nil }
        let size = dataType.elementSize

        if let string = fillValue as? String {
            return fillValueFromString(string, size: size)
        }
        if let bool = fillValue as? Bool {
            return Data([bool ? 1 : 0])
        }

        switch dataType.kind {
        case .int:
            let v: Int64
            if let x = fillValue as? Int {
                v = Int64(x)
            } else if let x = fillValue as? Int32 {
                v = Int64(x)
            } else if let x = fillValue as? Int64 {
                v = x
            } else if let x = fillValue as? Int16 {
                v = Int64(x)
            } else if let x = fillValue as? Int8 {
                v = Int64(x)
            } else {
                return nil
            }
            switch size {
            case 1: return dataType.data(from: Int8(truncatingIfNeeded: v))
            case 2: return dataType.data(from: Int16(truncatingIfNeeded: v))
            case 4: return dataType.data(from: Int32(truncatingIfNeeded: v))
            case 8: return dataType.data(from: v)
            default: return nil
            }
        case .uint:
            let v: UInt64
            if let x = fillValue as? UInt {
                v = UInt64(x)
            } else if let x = fillValue as? UInt32 {
                v = UInt64(x)
            } else if let x = fillValue as? UInt64 {
                v = x
            } else if let x = fillValue as? UInt16 {
                v = UInt64(x)
            } else if let x = fillValue as? UInt8 {
                v = UInt64(x)
            } else {
                return nil
            }
            switch size {
            case 1: return dataType.data(from: UInt8(truncatingIfNeeded: v))
            case 2: return dataType.data(from: UInt16(truncatingIfNeeded: v))
            case 4: return dataType.data(from: UInt32(truncatingIfNeeded: v))
            case 8: return dataType.data(from: v)
            default: return nil
            }
        case .float:
            switch size {
            case 4:
                let v: Float
                if let x = fillValue as? Float {
                    v = x
                } else if let x = fillValue as? Double {
                    v = Float(x)
                } else if let x = fillValue as? Int {
                    v = Float(x)
                } else {
                    return nil
                }
                return dataType.data(from: v)
            case 8:
                let v: Double
                if let x = fillValue as? Double {
                    v = x
                } else if let x = fillValue as? Float {
                    v = Double(x)
                } else if let x = fillValue as? Int {
                    v = Double(x)
                } else {
                    return nil
                }
                return dataType.data(from: v)
            default: return nil
            }
        case .bool:
            if let b = fillValue as? Bool { return Data([b ? 1 : 0]) }
            return nil
        case .complex:
            return Data(repeating: 0, count: size)
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

    private func collectAllChunkIndices() -> [[Int]] {
        let nchunks = _numChunks
        let ndim = self.ndim
        var result: [[Int]] = []
        var current = [Int](repeating: 0, count: ndim)

        func collect(dim: Int) {
            if dim == ndim {
                result.append(current)
                return
            }
            for i in 0..<nchunks[dim] {
                current[dim] = i
                collect(dim: dim + 1)
            }
        }
        collect(dim: 0)
        return result
    }
}
