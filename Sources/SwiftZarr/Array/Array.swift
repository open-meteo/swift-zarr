import Foundation

public enum ZarrArrayError: Error, Sendable, Equatable {
    case mismatchedDimensions(expected: Int, got: Int)
    case invalidChunkIndex([Int])
    case invalidCodecConfiguration(String)
    case unsupportedCompressor(String)
    case unsupportedFilters
    case unsupportedChunkKeyEncoding(String)
    case invalidChunkKeySeparator(String)
    case invalidMetadata(String)
    case invalidSlice(String)
    case invalidDataSize(expected: Int, got: Int)
}

/// The original metadata for a Zarr array, preserved in its native format.
public enum ZarrArrayMetadata: Sendable {
    case v2(V2ArrayMetadata)
    case v3(V3ArrayMetadata)
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
    /// The original array metadata in its native Zarr version format.
    public let metadata: ZarrArrayMetadata
    public let dataType: ZarrDataType
    public let version: ZarrVersion
    public let shape: [Int]
    public let chunkShape: [Int]
    public let totalElements: Int

    private let encodedFillValue: Data
    private let numChunks: [Int]
    private let chunkKeyEncoding: ChunkKeyEncoding
    private let chunkStride: [Int]
    private let chunkByteCount: Int
    private let orderIsF: Bool
    private let codecPipeline: CodecPipeline
    private let concurrentLimit: Int

    public var ndim: Int { shape.count }
    public var elementSize: Int { dataType.elementSize }

    public init(storage: any Storage, path: String) async throws {
        let normalizedPath = try normalizeZarrPath(path)
        let decoder = JSONDecoder()
        let metadata: ZarrArrayMetadata
        if let data = try await storage.readIfExists(path: zarrKey(normalizedPath, "zarr.json")) {
            metadata = .v3(try decoder.decode(V3ArrayMetadata.self, from: data))
        } else {
            let data = try await storage.read(path: zarrKey(normalizedPath, ".zarray"))
            metadata = .v2(try decoder.decode(V2ArrayMetadata.self, from: data))
        }
        try self.init(metadata: metadata, storage: storage, path: path)
    }

    /// Create an array from native metadata without reading from storage.
    public init(metadata: ZarrArrayMetadata, storage: any Storage, path: String) throws {
        self.storage = storage
        self.path = try normalizeZarrPath(path)
        self.metadata = metadata

        let fillValue: ZarrJSONValue?
        let pipeline: CodecPipeline
        let dataType: ZarrDataType
        switch metadata {
        case .v2(let meta):
            guard meta.zarrFormat == 2 else { throw ZarrArrayError.invalidMetadata("expected zarr_format 2") }
            if let separator = meta.dimensionSeparator, separator != "." && separator != "/" {
                throw ZarrArrayError.invalidChunkKeySeparator(separator)
            }
            version = .v2
            dataType = try ZarrDataType.parse(meta.dtype)
            pipeline = try CodecPipeline(v2: meta, dataType: dataType)
            chunkKeyEncoding = .v2(separator: meta.dimensionSeparator ?? ".")
            shape = try Self.checkedDimensions(meta.shape)
            chunkShape = try Self.checkedDimensions(meta.chunks)
            orderIsF = meta.order == .F
            fillValue = meta.fillValue
        case .v3(let meta):
            guard meta.zarrFormat == 3, meta.nodeType == "array" else {
                throw ZarrArrayError.invalidMetadata("expected a V3 array")
            }
            guard meta.chunkGrid.name == "regular" else {
                throw ZarrArrayError.invalidMetadata("unsupported chunk grid: \(meta.chunkGrid.name)")
            }
            guard meta.storageTransformers?.isEmpty != false else {
                throw ZarrArrayError.invalidMetadata("storage transformers are unsupported")
            }
            if let names = meta.dimensionNames, names.count != meta.shape.count {
                throw ZarrArrayError.invalidMetadata("dimension_names rank does not match shape")
            }
            version = .v3
            let parsed = try ZarrDataType.parseV3(meta.dataType)
            switch (parsed.kind, meta.fillValue) {
            case (.bool, .bool), (.int, .int), (.int, .uint), (.uint, .int), (.uint, .uint),
                (.float, .int), (.float, .uint), (.float, .string):
                break
            case (.float, .double(let value)) where value.isFinite:
                break
            default:
                throw ZarrArrayError.invalidMetadata("invalid V3 fill_value representation for \(meta.dataType)")
            }
            pipeline = try CodecPipeline(v3: meta.codecs, dataType: parsed)
            dataType = ZarrDataType(endian: pipeline.serializer.endian, kind: parsed.kind, size: parsed.size)
            chunkKeyEncoding = try ChunkKeyEncoding(v3: meta.chunkKeyEncoding)
            shape = try Self.checkedDimensions(meta.shape)
            chunkShape = try Self.checkedDimensions(meta.chunkGrid.configuration.chunkShape)
            orderIsF = false
            fillValue = meta.fillValue
        }

        self.dataType = dataType
        guard shape.count == chunkShape.count, chunkShape.allSatisfy({ $0 > 0 }) else {
            throw ZarrArrayError.invalidMetadata("chunk dimensions must be positive and match the array rank")
        }
        // totalElements is an Int, but a subset's byte count is checked when requested.
        if shape.contains(0) {
            totalElements = 0
        } else {
            var elements = 1
            for size in shape {
                let (product, overflow) = elements.multipliedReportingOverflow(by: size)
                guard !overflow else { throw ZarrArrayError.invalidMetadata("array element count overflows Int") }
                elements = product
            }
            totalElements = elements
        }
        numChunks = zip(shape, chunkShape).map { size, chunk in size / chunk + (size % chunk == 0 ? 0 : 1) }
        var chunkStride = [Int](repeating: 1, count: chunkShape.count)
        var elements = 1
        let dimensions =
            orderIsF ? Array(chunkShape.indices) : Array(chunkShape.indices.reversed())
        for d in dimensions {
            chunkStride[d] = elements
            let (product, overflow) = elements.multipliedReportingOverflow(by: chunkShape[d])
            guard !overflow else { throw ZarrArrayError.invalidMetadata("chunk element count overflows Int") }
            elements = product
        }
        let (bytes, overflow) = elements.multipliedReportingOverflow(by: dataType.elementSize)
        guard !overflow, bytes > 0 else { throw ZarrArrayError.invalidMetadata("invalid chunk byte count") }
        encodedFillValue = try dataType.encodeFillValue(fillValue)
        self.chunkStride = chunkStride
        chunkByteCount = bytes
        codecPipeline = pipeline
        concurrentLimit = max(4, ProcessInfo.processInfo.activeProcessorCount)
    }

    private static func checkedDimensions(_ dimensions: [UInt64]) throws -> [Int] {
        try dimensions.map { value in
            guard let size = Int(exactly: value) else {
                throw ZarrArrayError.invalidMetadata("dimension is not representable as Int")
            }
            return size
        }
    }

    /// Create an array from in-memory V2 metadata without reading from storage.
    public init(metadata: V2ArrayMetadata, storage: any Storage, path: String) throws {
        try self.init(metadata: .v2(metadata), storage: storage, path: path)
    }

    /// Create an array from in-memory V3 metadata without reading from storage.
    public init(metadata: V3ArrayMetadata, storage: any Storage, path: String) throws {
        try self.init(metadata: .v3(metadata), storage: storage, path: path)
    }

    @available(*, deprecated, renamed: "init(metadata:storage:path:)")
    public init(v3Metadata: V3ArrayMetadata, storage: any Storage, path: String) throws {
        try self.init(metadata: v3Metadata, storage: storage, path: path)
    }

    /// Number of chunks per dimension (the chunk grid shape).
    public func chunkGridShape() -> [Int] { numChunks }

    /// Shape of the chunk intersection with array bounds. Stored chunks always use `chunkShape`.
    public func chunkSize(_ indices: [Int]) throws -> [Int] {
        guard indices.count == ndim else {
            throw ZarrArrayError.mismatchedDimensions(expected: ndim, got: indices.count)
        }
        let c = chunkShape
        let s = shape
        return (0..<ndim).map { d in
            let start = indices[d] * c[d]
            return min(c[d], s[d] - start)
        }
    }

    /// Build the storage key using the array's resolved chunk-key encoding.
    /// V2 encoding uses separator-joined indices, or "0" for a scalar.
    /// V3 default encoding prefixes indices with "c", or uses "c" for a scalar.
    public func chunkKey(_ indices: [Int]) -> String {
        chunkKeyEncoding.key(indices)
    }

    // MARK: - Typed reads

    /// Retrieve a full stored chunk, including edge padding, in the declared array order.
    /// If the chunk file does not exist, returns the fill value.
    public func retrieveChunk<T: ZarrElement>(_ indices: [Int]) async throws -> [T] {
        try validateElementType(T.self)
        let data = try await readChunkRaw(indices)
        return try T.decode(data, endian: dataType.endian)
    }

    /// Retrieve and decode a single chunk, returning `nil` if the chunk file does not exist.
    public func retrieveChunkIfExists<T: ZarrElement>(_ indices: [Int]) async throws -> [T]? {
        try validateElementType(T.self)
        try validateIndices(indices)
        let key = zarrKey(path, chunkKey(indices))
        guard let raw = try await storage.readIfExists(path: key) else { return nil }
        let data = try decodeChunk(raw)
        return try T.decode(data, endian: dataType.endian)
    }

    /// Retrieve a sub-region of the array (slice read), crossing chunk boundaries as needed.
    public func retrieveArraySubset<T: ZarrElement>(_ ranges: [Range<Int>]) async throws -> [T] {
        try validateElementType(T.self)
        if let nativeType = T.self as? any NativeZarrElement.Type {
            // Opening the metatype preserves T; this cast does not reinterpret memory.
            return try await retrieveNativeSubset(nativeType, ranges: ranges) as! [T]
        }
        let bytes = try await assembleSubset(ranges)
        return bytes.isEmpty ? [] : try T.decode(bytes, endian: dataType.endian)
    }

    private func validateElementType<T: ZarrElement>(_ type: T.Type) throws {
        guard dataType.matches(type: T.self) else {
            throw ZarrElementError.typeMismatch(
                expected: T.zarrDtypeKind,
                expectedSize: T.zarrDtypeSize,
                actual: dataType
            )
        }
    }

    private func retrieveNativeSubset<T: NativeZarrElement>(
        _ type: T.Type,
        ranges: [Range<Int>]
    ) async throws -> Any {
        let byteCount = try subsetByteCount(ranges)
        guard byteCount > 0 else { return [T]() }
        let chunks = subsetChunks(ranges)
        if coversWholeChunk(ranges, chunks: chunks) {
            return try T.decode(await readChunkRaw(chunks[0]), endian: dataType.endian)
        }
        // Initialized storage remains valid across suspension and failed chunk reads.
        var values = T.makeArray(count: byteCount / elementSize)
        try await readSubsetChunks(ranges, chunks: chunks) { data, slice in
            // Safe only for the explicitly supported native numeric representations.
            values.withUnsafeMutableBytes { output in
                slice.copy(data, into: output, elementSize: elementSize)
            }
        }
        if (dataType.endian == .big && isLittleEndian) || (dataType.endian == .little && !isLittleEndian) {
            T.swapByteOrder(&values)
        }
        return values
    }

    private func subsetByteCount(_ ranges: [Range<Int>]) throws -> Int {
        guard ranges.count == ndim else {
            throw ZarrArrayError.mismatchedDimensions(expected: ndim, got: ranges.count)
        }
        for d in 0..<ndim {
            guard ranges[d].lowerBound >= 0 && ranges[d].upperBound <= shape[d] else {
                throw ZarrArrayError.invalidSlice(
                    "range \(ranges[d]) out of bounds for dimension \(d) (size \(shape[d]))"
                )
            }
        }
        if ranges.contains(where: { $0.isEmpty }) { return 0 }
        var bytes = elementSize
        for range in ranges {
            let (product, overflow) = bytes.multipliedReportingOverflow(by: range.count)
            guard !overflow else { throw ZarrArrayError.invalidSlice("subset byte count overflows Int") }
            bytes = product
        }
        return bytes
    }

    private func subsetChunks(_ ranges: [Range<Int>]) -> ChunkIndexBuffer {
        collectChunkIndices(
            ranges: (0..<ndim).map { d in
                (ranges[d].lowerBound / chunkShape[d])..<((ranges[d].upperBound - 1) / chunkShape[d] + 1)
            }
        )
    }

    private func coversWholeChunk(_ ranges: [Range<Int>], chunks: ChunkIndexBuffer) -> Bool {
        guard chunks.count == 1, !orderIsF || ndim <= 1 else { return false }
        let indices = chunks[0]
        return (0..<ndim).allSatisfy { d in
            ranges[d].lowerBound == indices[d] * chunkShape[d] && ranges[d].count == chunkShape[d]
        }
    }

    private func assembleSubset(_ ranges: [Range<Int>]) async throws -> Data {
        let byteCount = try subsetByteCount(ranges)
        guard byteCount > 0 else { return Data() }
        let chunks = subsetChunks(ranges)
        if coversWholeChunk(ranges, chunks: chunks) { return try await readChunkRaw(chunks[0]) }
        var bytes = Data(count: byteCount)
        try await readSubsetChunks(ranges, chunks: chunks) { data, slice in
            bytes.withUnsafeMutableBytes { output in
                slice.copy(data, into: output, elementSize: elementSize)
            }
        }
        return bytes
    }

    private func readSubsetChunks(
        _ ranges: [Range<Int>],
        chunks: ChunkIndexBuffer,
        consume: (Data, ChunkSlice) -> Void
    ) async throws {
        var outputStride = [Int](repeating: 1, count: ndim)
        if ndim > 1 {
            for d in (0..<ndim - 1).reversed() {
                outputStride[d] = outputStride[d + 1] * ranges[d + 1].count
            }
        }
        var localStart = [Int](repeating: 0, count: ndim)
        var outputStart = [Int](repeating: 0, count: ndim)
        var localCount = [Int](repeating: 0, count: ndim)

        func copyChunk(_ indices: [Int], _ data: Data) {
            for d in 0..<ndim {
                let origin = indices[d] * chunkShape[d]
                localStart[d] = max(ranges[d].lowerBound - origin, 0)
                let localEnd = min(ranges[d].upperBound - origin, chunkShape[d])
                localCount[d] = localEnd - localStart[d]
                outputStart[d] = origin + localStart[d] - ranges[d].lowerBound
            }
            consume(
                data,
                ChunkSlice(
                    fortran: orderIsF,
                    localCount: localCount,
                    localStart: localStart,
                    outputStart: outputStart,
                    outputStride: outputStride,
                    chunkStride: chunkStride
                )
            )
        }
        if chunks.count == 1 {
            let indices = chunks[0]
            copyChunk(indices, try await readChunkRaw(indices))
            return
        }
        for start in stride(from: 0, to: chunks.count, by: concurrentLimit) {
            try await withThrowingTaskGroup(of: ([Int], Data).self) { group in
                for i in start..<min(start + concurrentLimit, chunks.count) {
                    let indices = chunks[i]
                    group.addTask { (indices, try await self.readChunkRaw(indices)) }
                }
                for try await (indices, data) in group { copyChunk(indices, data) }
            }
        }
    }

    // MARK: - Internal

    /// Read and decompress a single chunk, returning decoded bytes in array byte order.
    /// Falls back to fill value if the chunk file does not exist.
    internal func readChunkRaw(_ indices: [Int]) async throws -> Data {
        try validateIndices(indices)
        let key = zarrKey(path, chunkKey(indices))
        if let raw = try await storage.readIfExists(path: key) {
            return try decodeChunk(raw)
        } else {
            return fillValueData()
        }
    }

    /// Read the full array, clipping stored chunks to the array bounds.
    internal func readRaw() async throws -> Data {
        try await assembleSubset(shape.map { 0..<$0 })
    }

    private func validateChunkSize(_ data: Data) throws {
        let expected = chunkByteCount
        guard data.count == expected else {
            throw ZarrArrayError.invalidDataSize(expected: expected, got: data.count)
        }
    }

    private func decodeChunk(_ raw: Data) throws -> Data {
        let decoded = try codecPipeline.decode(raw)
        try validateChunkSize(decoded)
        return decoded
    }

    internal func validateIndices(_ indices: [Int]) throws {
        guard indices.count == ndim else {
            throw ZarrArrayError.mismatchedDimensions(expected: ndim, got: indices.count)
        }
        for d in 0..<ndim {
            guard indices[d] >= 0 && indices[d] < numChunks[d] else {
                throw ZarrArrayError.invalidChunkIndex(indices)
            }
        }
    }

    // MARK: - Write

    /// Write the array metadata to storage (`.zarray` for V2, `zarr.json` for V3).
    public func storeMetadata() async throws {
        let encoder = JSONEncoder()
        switch metadata {
        case .v2(let meta):
            let data = try encoder.encode(meta)
            try await storage.write(path: zarrKey(path, ".zarray"), data: data)
        case .v3(let meta):
            let data = try encoder.encode(meta)
            try await storage.write(path: zarrKey(path, "zarr.json"), data: data)
        }
    }

    /// Encode and store a single chunk. `data` must contain exactly
    /// `chunkShape.product * elementSize` bytes, including edge padding, in the declared array order.
    public func storeChunk(_ indices: [Int], data: Data) async throws {
        try validateIndices(indices)
        try validateChunkSize(data)
        let encoded = try codecPipeline.encode(data)
        let key = zarrKey(path, chunkKey(indices))
        try await storage.write(path: key, data: encoded)
    }

    /// Delete a single chunk from storage.
    public func eraseChunk(_ indices: [Int]) async throws {
        try validateIndices(indices)
        let key = zarrKey(path, chunkKey(indices))
        try await storage.delete(path: key)
    }

    // MARK: - Private helpers

    private func fillValueData() -> Data {
        var result = Data(count: chunkByteCount)
        result.withUnsafeMutableBytes { destination in
            encodedFillValue.withUnsafeBytes { source in
                UnsafeMutableRawBufferPointer(rebasing: destination[..<source.count]).copyMemory(from: source)
                var filled = source.count
                while filled < destination.count {
                    let count = min(filled, destination.count - filled)
                    let prefix = UnsafeRawBufferPointer(rebasing: destination[..<count])
                    UnsafeMutableRawBufferPointer(rebasing: destination[filled..<filled + count]).copyMemory(
                        from: prefix
                    )
                    filled += count
                }
            }
        }
        return result
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

/// Shared chunk-copy geometry. Offsets/counts are in elements.
private struct ChunkSlice {
    let fortran: Bool
    let localCount: [Int]
    let localStart: [Int]
    let outputStart: [Int]
    let outputStride: [Int]
    let chunkStride: [Int]

    func copy(_ data: Data, into output: UnsafeMutableRawBufferPointer, elementSize: Int) {
        data.withUnsafeBytes { input in
            func copyRun(_ source: Int, _ destination: Int, _ count: Int) {
                let sourceOffset = source * elementSize
                let destinationOffset = destination * elementSize
                let byteCount = count * elementSize
                // Slice both buffers to check bounds before copying.
                let sourceBytes = UnsafeRawBufferPointer(rebasing: input[sourceOffset..<sourceOffset + byteCount])
                let destinationBytes = UnsafeMutableRawBufferPointer(
                    rebasing: output[destinationOffset..<destinationOffset + byteCount]
                )
                destinationBytes.copyMemory(from: sourceBytes)
            }

            let ndim = localCount.count
            if ndim == 0 {
                copyRun(0, 0, 1)
            } else if fortran && ndim > 1 {
                for flat in 0..<localCount.reduce(1, *) {
                    var position = flat
                    var source = 0
                    var destination = 0
                    for d in 0..<ndim {
                        let offset = position % localCount[d]
                        position /= localCount[d]
                        source += (localStart[d] + offset) * chunkStride[d]
                        destination += (outputStart[d] + offset) * outputStride[d]
                    }
                    copyRun(source, destination, 1)
                }
            } else {
                let innerCount = localCount[ndim - 1]
                let rows = localCount.dropLast().reduce(1, *)
                for row in 0..<rows {
                    var position = row
                    var source = localStart[ndim - 1] * chunkStride[ndim - 1]
                    var destination = outputStart[ndim - 1] * outputStride[ndim - 1]
                    for d in (0..<ndim - 1).reversed() {
                        let offset = position % localCount[d]
                        position /= localCount[d]
                        source += (localStart[d] + offset) * chunkStride[d]
                        destination += (outputStart[d] + offset) * outputStride[d]
                    }
                    copyRun(source, destination, innerCount)
                }
            }
        }
    }
}
