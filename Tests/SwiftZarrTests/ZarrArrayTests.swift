import Foundation
import Testing

@testable import SwiftZarr

// MARK: - Test helpers

func createTempDir() throws -> String {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftzarr_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp.path
}

/// Extract a chunk from a flat C-order array.
func extractChunk(
    from flatData: Data,
    arrayShape: [Int],
    chunkShape: [Int],
    chunkIndices: [Int],
    elementSize: Int
) -> Data {
    let ndim = arrayShape.count
    var chunkStart = [Int](repeating: 0, count: ndim)
    var actualChunkShape = [Int](repeating: 0, count: ndim)
    for d in 0..<ndim {
        chunkStart[d] = chunkIndices[d] * chunkShape[d]
        actualChunkShape[d] = min(chunkShape[d], arrayShape[d] - chunkStart[d])
    }
    let chunkElements = actualChunkShape.reduce(1, *)
    var chunkData = Data(count: chunkElements * elementSize)

    var chunkStride = [Int](repeating: 0, count: ndim)
    var s = 1
    for d in (0..<ndim).reversed() {
        chunkStride[d] = s
        s *= actualChunkShape[d]
    }

    var arrayStride = [Int](repeating: 0, count: ndim)
    s = 1
    for d in (0..<ndim).reversed() {
        arrayStride[d] = s
        s *= arrayShape[d]
    }

    for localFlat in 0..<chunkElements {
        var remaining = localFlat
        var globalFlat = 0
        for d in 0..<ndim {
            let localCoord = remaining / chunkStride[d]
            remaining %= chunkStride[d]
            let globalCoord = chunkStart[d] + localCoord
            globalFlat += globalCoord * arrayStride[d]
        }
        let srcOff = globalFlat * elementSize
        let dstOff = localFlat * elementSize
        chunkData[dstOff..<dstOff + elementSize] = flatData[srcOff..<srcOff + elementSize]
    }
    return chunkData
}

/// Recursively store all chunks of an array from flat C-order data.
func storeAllChunks(array: ZarrArray, data: Data) async throws {
    let ndim = array.ndim
    let chunkShape = array.chunkShape
    let numChunks = array.chunkGridShape()
    let elementSize = array.elementSize
    let arrayShape = array.shape

    func store(dim: Int, indices: [Int]) async throws {
        if dim == ndim {
            let chunkData = extractChunk(
                from: data,
                arrayShape: arrayShape,
                chunkShape: chunkShape,
                chunkIndices: indices,
                elementSize: elementSize
            )
            try await array.storeChunk(indices, data: chunkData)
            return
        }
        for i in 0..<numChunks[dim] {
            try await store(dim: dim + 1, indices: indices + [i])
        }
    }
    try await store(dim: 0, indices: [])
}

func int32LERange(_ count: Int) -> Data {
    var data = Data()
    data.reserveCapacity(count * 4)
    for i in 0..<count {
        var le = Int32(i).littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    return data
}

func float64BEArray(_ values: [Double]) -> Data {
    var data = Data()
    data.reserveCapacity(values.count * 8)
    for v in values {
        var be = v.bitPattern.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
    return data
}

// MARK: - Basic array tests

@Test
func test1DArraySingleChunk() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let shape = [10]
    let chunks = [10]
    let data = int32LERange(10)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: shape.map(UInt64.init),
        chunks: chunks.map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    let readData = try await array.readRaw()
    #expect(readData == data)
}

@Test
func testTypedRead() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(10)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [10].map(UInt64.init),
        chunks: [10].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    let values: [Int32] = try await array.retrieveArraySubset([0..<10])
    #expect(values == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
}

@Test
func testTypedChunkRead() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(10)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [10].map(UInt64.init),
        chunks: [5].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    let chunk0: [Int32] = try await array.retrieveChunk([0])
    #expect(chunk0 == [0, 1, 2, 3, 4])
    let chunk1: [Int32] = try await array.retrieveChunk([1])
    #expect(chunk1 == [5, 6, 7, 8, 9])
}

// MARK: - Slice / subset tests

@Test
func testSliceRead() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(24)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4, 6].map(UInt64.init),
        chunks: [4, 6].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    let slice: [Int32] = try await array.retrieveArraySubset([0..<2, 0..<2])
    #expect(slice == [0, 1, 6, 7])
}

@Test
func testMultiChunkSliceRead() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(24)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4, 6].map(UInt64.init),
        chunks: [2, 3].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    let slice: [Int32] = try await array.retrieveArraySubset([1..<3, 1..<5])
    #expect(slice == [7, 8, 9, 10, 13, 14, 15, 16])
}

// MARK: - Multi-chunk tests

@Test
func test1DArrayMultipleChunks() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(10)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [10].map(UInt64.init),
        chunks: [3].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    #expect(array.chunkGridShape() == [4])
    let chunk0 = try await array.readChunkRaw([0])
    #expect(chunk0.count == 3 * 4)
    #expect(chunk0[0..<4] == data[0..<4])
    let chunk3 = try await array.readChunkRaw([3])
    #expect(chunk3.count == 1 * 4)
    let readData = try await array.readRaw()
    #expect(readData == data)
}

@Test
func test2DArrayMultipleChunks() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(24)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4, 6].map(UInt64.init),
        chunks: [2, 3].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    #expect(array.chunkGridShape() == [2, 2])
    let readData = try await array.readRaw()
    #expect(readData == data)
}

@Test
func testReadIndividual2DChunk() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let shape = [4, 6]
    let chunks = [2, 3]
    let data = int32LERange(24)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: shape.map(UInt64.init),
        chunks: chunks.map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    let chunk00 = try await array.readChunkRaw([0, 0])
    #expect(chunk00.count == 6 * 4)
    let chunk01 = try await array.readChunkRaw([0, 1])
    #expect(
        chunk01
            == extractChunk(from: data, arrayShape: shape, chunkShape: chunks, chunkIndices: [0, 1], elementSize: 4)
    )
    let chunk11 = try await array.readChunkRaw([1, 1])
    #expect(
        chunk11
            == extractChunk(from: data, arrayShape: shape, chunkShape: chunks, chunkIndices: [1, 1], elementSize: 4)
    )
}

// MARK: - Data type / endian tests

@Test
func testBigEndianFloat64() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let values: [Double] = [1.5, 2.5, 3.5, 4.5, 5.5]
    let data = float64BEArray(values)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [5].map(UInt64.init),
        chunks: [5].map(UInt64.init),
        dtype: ">f8",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    let readData = try await array.readRaw()
    #expect(readData == data)
}

@Test
func testDimensionSeparatorSlash() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(16)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4, 4].map(UInt64.init),
        chunks: [2, 2].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: "/"
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    #expect(try await storage.exists(path: "arr/0/0"))
    #expect(try await storage.exists(path: "arr/0/1"))
    #expect(try await storage.exists(path: "arr/1/0"))
    #expect(try await storage.exists(path: "arr/1/1"))
    let readData = try await array.readRaw()
    #expect(readData == data)
    #expect(array.chunkKey([0, 0]) == "0/0")
    #expect(array.chunkKey([1, 1]) == "1/1")
}

@Test
func testDimensionSeparatorDot() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(16)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4, 4].map(UInt64.init),
        chunks: [2, 2].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: "."
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    #expect(try await storage.exists(path: "arr/0.0"))
    #expect(try await storage.exists(path: "arr/0.1"))
    #expect(try await storage.exists(path: "arr/1.0"))
    #expect(try await storage.exists(path: "arr/1.1"))
    let readData = try await array.readRaw()
    #expect(readData == data)
    #expect(array.chunkKey([0, 0]) == "0.0")
    #expect(array.chunkKey([1, 1]) == "1.1")
}

@Test
func testV3SeparatorDot() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let shape: [UInt64] = [4, 4]
    let chunkShape: [UInt64] = [2, 2]
    let data = int32LERange(16)
    let v3meta = V3ArrayMetadata(
        zarrFormat: 3,
        nodeType: "array",
        shape: shape,
        dataType: "<i4",
        chunkGrid: .init(name: "regular", configuration: .init(chunkShape: chunkShape)),
        chunkKeyEncoding: .init(name: "default", configuration: .init(separator: ".")),
        fillValue: nil,
        codecs: nil,
        storageTransformers: nil,
        dimensionNames: nil,
        attributes: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(v3Metadata: v3meta, storage: storage, path: "arr")
    #expect(array.version == .v3)
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    #expect(try await storage.exists(path: "arr/data/c/0.0"))
    #expect(try await storage.exists(path: "arr/data/c/0.1"))
    #expect(array.chunkKey([0, 0]) == "data/c/0.0")

    let readData = try await array.readRaw()
    #expect(readData == data)

    let reopened = try await ZarrArray(storage: storage, path: "arr")
    #expect(reopened.chunkKey([0, 0]) == "data/c/0.0")
    #expect(try await reopened.readRaw() == data)
}

@Test
func testPartialEdgeChunks() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let shape = [3, 5]
    let chunks = [2, 3]
    let data = int32LERange(15)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: shape.map(UInt64.init),
        chunks: chunks.map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    #expect(array.chunkGridShape() == [2, 2])
    let chunk11 = try await array.readChunkRaw([1, 1])
    #expect(chunk11.count == 2 * 4)
    let readData = try await array.readRaw()
    #expect(readData == data)
}

// MARK: - Fill value tests

@Test
func testMissingChunkReturnsFillValue() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4, 4].map(UInt64.init),
        chunks: [2, 2].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    let chunk00Data = int32LERange(4)
    try await array.storeChunk([0, 0], data: chunk00Data)

    let chunk01 = try await array.readChunkRaw([0, 1])
    #expect(chunk01.count == 4 * 4)
    #expect(chunk01.allSatisfy { $0 == 0 })

    let readData = try await array.readRaw()
    #expect(readData.count == 16 * 4)
    let int32Data = readData.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
    #expect(int32Data[0] == 0)
    #expect(int32Data[1] == 1)
    #expect(int32Data[4] == 2)
    #expect(int32Data[5] == 3)
    for idx in [2, 3, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15] {
        #expect(int32Data[idx] == 0)
    }
}

@Test
func testFillValueNaNfloat32() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4].map(UInt64.init),
        chunks: [2].map(UInt64.init),
        dtype: "<f4",
        compressor: nil,
        fillValue: .string("NaN"),
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    var data = Data(capacity: 8)
    var v1: Float = 1.0; withUnsafeBytes(of: &v1) { data.append(contentsOf: $0) }
    var v2: Float = 2.0; withUnsafeBytes(of: &v2) { data.append(contentsOf: $0) }
    try await array.storeChunk([0], data: data)

    let chunk1 = try await array.readChunkRaw([0]); #expect(chunk1.count == 8)
    let chunk2 = try await array.readChunkRaw([1]); #expect(chunk2.count == 8)
    let values = chunk2.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    #expect(values.count == 2)
    #expect(values[0].isNaN); #expect(values[1].isNaN)
}

@Test
func testFillValueInfinityFloat64() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [2].map(UInt64.init),
        chunks: [2].map(UInt64.init),
        dtype: "<f8",
        compressor: nil,
        fillValue: .string("Infinity"),
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    let data = try await array.readChunkRaw([0])
    let values = data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
    #expect(values == [Double.infinity, Double.infinity])
}

@Test
func testFillValueInteger() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [3].map(UInt64.init),
        chunks: [3].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: .int(-1),
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    let data = try await array.readChunkRaw([0])
    let values = data.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
    #expect(values == [-1, -1, -1])
}

@Test
func testFillValueDefaultZero() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [3].map(UInt64.init),
        chunks: [3].map(UInt64.init),
        dtype: "<f8",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    let data = try await array.readChunkRaw([0])
    let values = data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
    #expect(values == [0, 0, 0])
}

// MARK: - N-dimensional tests

@Test
func test3DArray() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(24)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [2, 3, 4].map(UInt64.init),
        chunks: [2, 3, 4].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    #expect(array.chunkGridShape() == [1, 1, 1])
    let readData = try await array.readRaw()
    #expect(readData == data)
}

@Test
func test3DArrayMultipleChunks() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let shape = [4, 6, 8]
    let chunks = [2, 3, 4]
    let data = int32LERange(192)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: shape.map(UInt64.init),
        chunks: chunks.map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    #expect(array.chunkGridShape() == [2, 2, 2])
    let readData = try await array.readRaw()
    #expect(readData == data)
    let individualChunk = try await array.readChunkRaw([1, 1, 1])
    #expect(
        individualChunk
            == extractChunk(from: data, arrayShape: shape, chunkShape: chunks, chunkIndices: [1, 1, 1], elementSize: 4)
    )
}

// MARK: - Group tests

@Test
func testGroupHierarchy() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let storage = LocalFileStorage(basePath: tmp)
    let group = ZarrGroup(metadata: V2GroupMetadata(zarrFormat: 2), storage: storage, path: "group")
    try await group.storeMetadata()

    let data1 = int32LERange(12)
    let meta1 = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [3, 4].map(UInt64.init),
        chunks: [3, 4].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let a1 = try ZarrArray(metadata: meta1, storage: storage, path: "group/a1")
    try await a1.storeMetadata(); try await storeAllChunks(array: a1, data: data1)

    let data2 = int32LERange(20)
    let meta2 = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4, 5].map(UInt64.init),
        chunks: [4, 5].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let a2 = try ZarrArray(metadata: meta2, storage: storage, path: "group/a2")
    try await a2.storeMetadata(); try await storeAllChunks(array: a2, data: data2)

    let groupRead = try await ZarrGroup(storage: storage, path: "group")
    #expect(groupRead.metadata.zarrFormat == 2)
    #expect(try await groupRead.listChildren() == [.array("a1"), .array("a2")])

    let a1Read = try await groupRead.openArray(name: "a1")
    #expect(a1Read.shape == [3, 4])
    #expect(try await a1Read.readRaw() == data1)

    let a2Read = try await groupRead.openArray(name: "a2")
    #expect(try await a2Read.readRaw() == data2)
}

@Test
func testNestedGroups() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let storage = LocalFileStorage(basePath: tmp)
    let root = ZarrGroup(metadata: V2GroupMetadata(zarrFormat: 2), storage: storage, path: "root")
    try await root.storeMetadata()
    let sub = ZarrGroup(metadata: V2GroupMetadata(zarrFormat: 2), storage: storage, path: "root/sub")
    try await sub.storeMetadata()

    let data = int32LERange(6)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [2, 3].map(UInt64.init),
        chunks: [2, 3].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let arr = try ZarrArray(metadata: meta, storage: storage, path: "root/sub/arr")
    try await arr.storeMetadata(); try await storeAllChunks(array: arr, data: data)

    let rootRead = try await ZarrGroup(storage: storage, path: "root")
    #expect(try await rootRead.listChildren() == [.group("sub")])
    let subRead = try await rootRead.openGroup(name: "sub")
    #expect(try await subRead.listChildren() == [.array("arr")])
    let arrRead = try await subRead.openArray(name: "arr")
    #expect(try await arrRead.readRaw() == data)
}

// MARK: - Error handling tests

@Test
func testInvalidChunkIndex() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(10)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [10].map(UInt64.init),
        chunks: [5].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    await #expect(throws: ZarrArrayError.mismatchedDimensions(expected: 1, got: 2)) {
        try await array.readChunkRaw([0, 0])
    }
}

@Test
func testInvalidDtype() async throws {
    #expect(throws: Error.self) {
        let meta = V2ArrayMetadata(
            zarrFormat: 2,
            shape: [1].map(UInt64.init),
            chunks: [1].map(UInt64.init),
            dtype: "invalid",
            compressor: nil,
            fillValue: nil,
            order: nil,
            filters: nil,
            dimensionSeparator: nil
        )
        _ = try ZarrArray(metadata: meta, storage: LocalFileStorage(basePath: "/tmp"), path: "arr")
    }
}

@Test
func testMissingMetadata() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    try FileManager.default.createDirectory(atPath: tmp + "/arr", withIntermediateDirectories: true)
    let storage = LocalFileStorage(basePath: tmp)
    await #expect(throws: Error.self) {
        try await ZarrArray(storage: storage, path: "arr")
    }
}

@Test
func testReadChunkValidateDimensions() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(24)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4, 6].map(UInt64.init),
        chunks: [2, 3].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    await #expect(throws: ZarrArrayError.mismatchedDimensions(expected: 2, got: 3)) {
        try await array.readChunkRaw([0, 0, 0])
    }
}

@Test
func testGroupWithoutMetadataFails() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    try FileManager.default.createDirectory(atPath: tmp + "/empty", withIntermediateDirectories: true)
    let storage = LocalFileStorage(basePath: tmp)
    await #expect(throws: Error.self) {
        try await ZarrGroup(storage: storage, path: "empty")
    }
}

@Test
func testListEmptyGroup() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let storage = LocalFileStorage(basePath: tmp)
    let group = ZarrGroup(metadata: V2GroupMetadata(zarrFormat: 2), storage: storage, path: "empty")
    try await group.storeMetadata()
    #expect(try await ZarrGroup(storage: storage, path: "empty").listChildren().isEmpty)
}

@Test
func testGroupAttrs() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let storage = LocalFileStorage(basePath: tmp)
    let group = ZarrGroup(metadata: V2GroupMetadata(zarrFormat: 2), storage: storage, path: "group")
    try await group.storeMetadata()
    try await group.storeAttributes(V2Attrs(values: ["key1": .string("value1"), "key2": .int(42)]))

    let decodedAttrs = try await ZarrGroup(storage: storage, path: "group").attributes()
    #expect(decodedAttrs?.values["key1"]?.stringValue == "value1")
    #expect(decodedAttrs?.values["key2"]?.intValue == 42)
}

@Test
func testMetadataParsing() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [10].map(UInt64.init),
        chunks: [5].map(UInt64.init),
        dtype: "|i1",
        compressor: nil,
        fillValue: .int(42),
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    #expect(array.shape == [10])
    #expect(array.chunkShape == [5])
    #expect(array.metadata.dtype == "|i1")
    #expect(array.metadata.fillValue?.intValue == 42)
    #expect(array.metadata.order == .C)
}

@Test
func testZarrJSONValueArrayRoundtrip() throws {
    let arr: [ZarrJSONValue] = [.int(1), .double(2.5), .string("three"), .bool(true)]
    let original = ZarrJSONValue.array(arr)
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ZarrJSONValue.self, from: encoded)
    if case .array(let vals) = decoded {
        #expect(vals.count == 4)
        #expect(vals[0].intValue == 1)
        #expect(vals[1].doubleValue == 2.5)
        #expect(vals[2].stringValue == "three")
        #expect(vals[3].boolValue == true)
    } else {
        Issue.record("expected .array, got \(decoded)")
    }
}

@Test
func testZarrJSONValueNestedArray() throws {
    let inner: [ZarrJSONValue] = [.int(1), .int(2)]
    let outer: [ZarrJSONValue] = [.int(0), .array(inner)]
    let original = ZarrJSONValue.array(outer)
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ZarrJSONValue.self, from: encoded)
    if case .array(let outerVals) = decoded {
        #expect(outerVals.count == 2)
        #expect(outerVals[0].intValue == 0)
        if case .array(let innerVals) = outerVals[1] {
            #expect(innerVals.count == 2)
            #expect(innerVals[0].intValue == 1)
            #expect(innerVals[1].intValue == 2)
        } else {
            Issue.record("expected nested .array")
        }
    } else {
        Issue.record("expected .array")
    }
}

@Test
func testZarrJSONValueArrayInAttrs() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let attrs = V2Attrs(values: ["tags": .array([.string("a"), .string("b")])])
    let storage = LocalFileStorage(basePath: tmp)
    let group = ZarrGroup(metadata: V2GroupMetadata(zarrFormat: 2), storage: storage, path: "g")
    try await group.storeMetadata()
    try await group.storeAttributes(attrs)

    let reopened = try await ZarrGroup(storage: storage, path: "g")
    let decoded = try await reopened.attributes()
    let tags = decoded?.values["tags"]?.arrayValue
    #expect(tags?.count == 2)
    #expect(tags?[0].stringValue == "a")
    #expect(tags?[1].stringValue == "b")
}

@Test
func testDtypeParsing() throws {
    let f8 = try ZarrDataType.parse(">f8")
    #expect(f8.endian == .big); #expect(f8.kind == .float); #expect(f8.size == 8)
    let i4 = try ZarrDataType.parse("<i4")
    #expect(i4.endian == .little); #expect(i4.kind == .int); #expect(i4.size == 4)
    let b1 = try ZarrDataType.parse("|b1")
    #expect(b1.endian == .none); #expect(b1.kind == .bool); #expect(b1.size == 1)
    let u2 = try ZarrDataType.parse("|u2")
    #expect(u2.kind == .uint); #expect(u2.size == 2)
    #expect(throws: ZarrDataTypeError.invalidDtype("xx")) { try ZarrDataType.parse("xx") }
    #expect(throws: ZarrDataTypeError.invalidDtype("")) { try ZarrDataType.parse("") }
}

// MARK: - Codec tests

@Test
func testGzipCodecRoundtrip() async throws {
    let original = int32LERange(100)
    let compressed = try GzipCodec().encode(original)
    #expect(compressed.count < original.count)
    #expect(try GzipCodec().decode(compressed) == original)
}

@Test
func testGzipArrayWriteRead() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(24)
    let compressor: [String: ZarrJSONValue] = ["id": .string("gzip"), "level": .int(5)]
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4, 6].map(UInt64.init),
        chunks: [2, 3].map(UInt64.init),
        dtype: "<i4",
        compressor: compressor,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)
    #expect(try await array.readRaw() == data)
}

@Test
func testGzipChunkRead() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(10)
    let compressor: [String: ZarrJSONValue] = ["id": .string("gzip"), "level": .int(5)]
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [10].map(UInt64.init),
        chunks: [5].map(UInt64.init),
        dtype: "<i4",
        compressor: compressor,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    let chunk0: [Int32] = try await array.retrieveChunk([0])
    #expect(chunk0 == [0, 1, 2, 3, 4])
    let chunk1: [Int32] = try await array.retrieveChunk([1])
    #expect(chunk1 == [5, 6, 7, 8, 9])
}

@Test
func testZlibCodecRoundtrip() async throws {
    let original = int32LERange(100)
    let compressed = try ZlibCodec().encode(original)
    #expect(compressed.count < original.count)
    #expect(try ZlibCodec().decode(compressed) == original)
}

@Test
func testZlibArrayWriteRead() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(24)
    let compressor: [String: ZarrJSONValue] = ["id": .string("zlib"), "level": .int(5)]
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4, 6].map(UInt64.init),
        chunks: [2, 3].map(UInt64.init),
        dtype: "<i4",
        compressor: compressor,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)
    #expect(try await array.readRaw() == data)
}

@Test
func testBZip2CodecRoundtrip() async throws {
    let original = int32LERange(100)
    let compressed = try BZip2Codec().encode(original)
    #expect(compressed.count < original.count)
    #expect(try BZip2Codec().decode(compressed) == original)
}

@Test
func testBZip2ArrayWriteRead() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(24)
    let compressor: [String: ZarrJSONValue] = ["id": .string("bz2"), "level": .int(5)]
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4, 6].map(UInt64.init),
        chunks: [2, 3].map(UInt64.init),
        dtype: "<i4",
        compressor: compressor,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)
    #expect(try await array.readRaw() == data)
}

@Test
func testLZ4CodecRoundtrip() async throws {
    let original = int32LERange(100)
    let compressed = try LZ4Codec().encode(original)
    #expect(try LZ4Codec().decode(compressed) == original)
}

@Test
func testBloscCodecRoundtrip() async throws {
    let original = int32LERange(100)
    let compressed = try BloscCodec().encode(original)
    #expect(try BloscCodec().decode(compressed) == original)
}

@Test
func testBloscLZ4HCWorks() async throws {
    let original = int32LERange(100)
    let compressed = try BloscCodec(compressorName: "lz4hc").encode(original)
    #expect(try BloscCodec(compressorName: "lz4hc").decode(compressed) == original)
}

@Test
func testBloscUnsupportedCnameFails() async throws {
    let original = int32LERange(100)
    #expect(throws: BloscError.self) {
        try BloscCodec(compressorName: "zstd").encode(original)
    }
}

// MARK: - V3 tests

@Test
func testV3ArrayWriteRead() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let shape: [UInt64] = [4, 6]
    let chunkShape: [UInt64] = [2, 3]
    let data = int32LERange(24)
    let v3meta = V3ArrayMetadata(
        zarrFormat: 3,
        nodeType: "array",
        shape: shape,
        dataType: "<i4",
        chunkGrid: .init(name: "regular", configuration: .init(chunkShape: chunkShape)),
        chunkKeyEncoding: .init(name: "default", configuration: .init(separator: "/")),
        fillValue: nil,
        codecs: nil,
        storageTransformers: nil,
        dimensionNames: nil,
        attributes: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(v3Metadata: v3meta, storage: storage, path: "v3arr")
    #expect(array.version == .v3)
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    #expect(array.chunkKey([0, 0]) == "data/c/0/0")
    #expect(array.chunkKey([1, 1]) == "data/c/1/1")
    #expect(try await storage.exists(path: "v3arr/data/c/0/0"))
    #expect(try await storage.exists(path: "v3arr/data/c/1/1"))

    let readData = try await array.readRaw()
    #expect(readData == data)

    let reopened = try await ZarrArray(storage: storage, path: "v3arr")
    #expect(reopened.version == .v3)
    #expect(reopened.shape == [4, 6])
    #expect(reopened.chunkShape == [2, 3])
    #expect(try await reopened.readRaw() == data)
}

@Test
func testV3GroupWriteRead() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let v3meta = V3GroupMetadata(
        zarrFormat: 3,
        nodeType: "group",
        attributes: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let group = ZarrGroup(v3Metadata: v3meta, storage: storage, path: "v3group")
    #expect(group.version == .v3)
    try await group.storeMetadata()

    let reopened = try await ZarrGroup(storage: storage, path: "v3group")
    #expect(reopened.version == .v3)
    #expect(try await storage.exists(path: "v3group/zarr.json"))
}

@Test
func testV3GroupAttrs() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let v3meta = V3GroupMetadata(
        zarrFormat: 3,
        nodeType: "group",
        attributes: ["key1": .string("v3value"), "key2": .int(99)]
    )
    let storage = LocalFileStorage(basePath: tmp)
    let group = ZarrGroup(v3Metadata: v3meta, storage: storage, path: "v3group")
    try await group.storeMetadata()

    let reopened = try await ZarrGroup(storage: storage, path: "v3group")
    let attrs = try await reopened.attributes()
    #expect(attrs?.values["key1"]?.stringValue == "v3value")
    #expect(attrs?.values["key2"]?.intValue == 99)
}

@Test
func testV3NestedGroups() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let storage = LocalFileStorage(basePath: tmp)
    let root = ZarrGroup(
        v3Metadata: V3GroupMetadata(
            zarrFormat: 3,
            nodeType: "group",
            attributes: nil
        ),
        storage: storage,
        path: "root"
    )
    try await root.storeMetadata()

    let data = int32LERange(6)
    let shape: [UInt64] = [2, 3]
    let chunkShape: [UInt64] = [2, 3]
    let arr = try ZarrArray(
        v3Metadata: V3ArrayMetadata(
            zarrFormat: 3,
            nodeType: "array",
            shape: shape,
            dataType: "<i4",
            chunkGrid: .init(name: "regular", configuration: .init(chunkShape: chunkShape)),
            chunkKeyEncoding: .init(name: "default", configuration: .init(separator: "/")),
            fillValue: nil,
            codecs: nil,
            storageTransformers: nil,
            dimensionNames: nil,
            attributes: nil
        ),
        storage: storage,
        path: "root/arr"
    )
    try await arr.storeMetadata()
    try await storeAllChunks(array: arr, data: data)

    let children = try await root.listChildren()
    #expect(children == [.array("arr")])
    let arrRead = try await root.openArray(name: "arr")
    #expect(arrRead.version == .v3)
    #expect(try await arrRead.readRaw() == data)
}

@Test
func testV3CompressorRoundtrip() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let data = int32LERange(24)
    let shape: [UInt64] = [4, 6]
    let chunkShape: [UInt64] = [2, 3]
    let codecs = [V3Codec(name: "gzip", configuration: ["level": .int(5)])]
    let v3meta = V3ArrayMetadata(
        zarrFormat: 3,
        nodeType: "array",
        shape: shape,
        dataType: "<i4",
        chunkGrid: .init(name: "regular", configuration: .init(chunkShape: chunkShape)),
        chunkKeyEncoding: .init(name: "default", configuration: .init(separator: "/")),
        fillValue: nil,
        codecs: codecs,
        storageTransformers: nil,
        dimensionNames: nil,
        attributes: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(v3Metadata: v3meta, storage: storage, path: "v3comp")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)
    #expect(try await array.readRaw() == data)
}

// MARK: - F-order tests

@Test
func testFOrderSingleChunk() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let shape = [2, 3]
    let chunks = [2, 3]
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: shape.map(UInt64.init),
        chunks: chunks.map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .F,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "fsingle")
    try await array.storeMetadata()

    var fData = Data(capacity: 24)
    for j in 0..<3 {
        for i in 0..<2 {
            var v = Int32(i + j * 2).littleEndian
            withUnsafeBytes(of: &v) { fData.append(contentsOf: $0) }
        }
    }
    try await array.storeChunk([0, 0], data: fData)

    let values: [Int32] = try await array.retrieveChunk([0, 0])
    #expect(values == [0, 1, 2, 3, 4, 5])
}

@Test
func testFOrderMultiChunk() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4, 6].map(UInt64.init),
        chunks: [2, 3].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .F,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "fmulti")
    try await array.storeMetadata()

    // Chunk [0,0]: rows 0-1, cols 0-2 → [[0,1,2],[6,7,8]] → F: [0,6,1,7,2,8]
    var f00 = Data(capacity: 24)
    for j in 0..<3 {
        for i in 0..<2 { var v = Int32(i * 6 + j).littleEndian; withUnsafeBytes(of: &v) { f00.append(contentsOf: $0) } }
    }
    try await array.storeChunk([0, 0], data: f00)
    // Chunk [0,1]: rows 0-1, cols 3-5 → [[3,4,5],[9,10,11]] → F: [3,9,4,10,5,11]
    var f01 = Data(capacity: 24)
    for j in 0..<3 {
        for i in 0..<2 {
            var v = Int32(i * 6 + j + 3).littleEndian; withUnsafeBytes(of: &v) { f01.append(contentsOf: $0) }
        }
    }
    try await array.storeChunk([0, 1], data: f01)
    // Chunk [1,0]: rows 2-3, cols 0-2 → [[12,13,14],[18,19,20]] → F: [12,18,13,19,14,20]
    var f10 = Data(capacity: 24)
    for j in 0..<3 {
        for i in 0..<2 {
            var v = Int32((i + 2) * 6 + j).littleEndian; withUnsafeBytes(of: &v) { f10.append(contentsOf: $0) }
        }
    }
    try await array.storeChunk([1, 0], data: f10)
    // Chunk [1,1]: rows 2-3, cols 3-5 → [[15,16,17],[21,22,23]] → F: [15,21,16,22,17,23]
    var f11 = Data(capacity: 24)
    for j in 0..<3 {
        for i in 0..<2 {
            var v = Int32((i + 2) * 6 + j + 3).littleEndian; withUnsafeBytes(of: &v) { f11.append(contentsOf: $0) }
        }
    }
    try await array.storeChunk([1, 1], data: f11)

    #expect(try await array.readRaw() == int32LERange(24))
    let slice: [Int32] = try await array.retrieveArraySubset([1..<3, 1..<5])
    #expect(slice == [7, 8, 9, 10, 13, 14, 15, 16])
}

@Test
func testFOrderEdgeChunk() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [3, 5].map(UInt64.init),
        chunks: [2, 3].map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .F,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "fedge")
    try await array.storeMetadata()

    // Chunk [0,0]: rows 0-1, cols 0-2 → [[0,1,2],[5,6,7]] → F: [0,5,1,6,2,7]
    var f00 = Data(capacity: 24)
    for j in 0..<3 {
        for i in 0..<2 { var v = Int32(i * 5 + j).littleEndian; withUnsafeBytes(of: &v) { f00.append(contentsOf: $0) } }
    }
    try await array.storeChunk([0, 0], data: f00)
    // Chunk [0,1]: rows 0-1, cols 3-4 → [[3,4],[8,9]] → F: [3,8,4,9]
    var f01 = Data(capacity: 16)
    for j in 0..<2 {
        for i in 0..<2 {
            var v = Int32(i * 5 + j + 3).littleEndian; withUnsafeBytes(of: &v) { f01.append(contentsOf: $0) }
        }
    }
    try await array.storeChunk([0, 1], data: f01)
    // Chunk [1,0]: rows 2-2, cols 0-2 → [[10,11,12]] → F order same as C (1D first dim)
    var f10 = Data(capacity: 12)
    for j in 0..<3 { var v = Int32(10 + j).littleEndian; withUnsafeBytes(of: &v) { f10.append(contentsOf: $0) } }
    try await array.storeChunk([1, 0], data: f10)
    // Chunk [1,1]: rows 2-2, cols 3-4 → [[13,14]] → F order same as C
    var f11 = Data(capacity: 8)
    for j in 0..<2 { var v = Int32(13 + j).littleEndian; withUnsafeBytes(of: &v) { f11.append(contentsOf: $0) } }
    try await array.storeChunk([1, 1], data: f11)

    #expect(try await array.readRaw() == int32LERange(15))
}

// MARK: - 4D array

@Test
func test4DArray() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    // 2×2×2×2 array, 2×2×2×2 chunks (single chunk)
    let shape = [2, 2, 2, 2]
    let count = shape.reduce(1, *)
    let data = int32LERange(count)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: shape.map(UInt64.init),
        chunks: shape.map(UInt64.init),
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr4d")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: data)

    // Full read matches.
    let readBack = try await array.readRaw()
    #expect(readBack == data)

    // Typed subset read: pick the first half of the last axis, i.e. [:,:,:,0:1].
    let subset: [Int32] = try await array.retrieveArraySubset([0..<2, 0..<2, 0..<2, 0..<1])
    // Expected: elements at index [..., 0] in last dim = 0,2,4,6,8,10,12,14
    let expected: [Int32] = [0, 2, 4, 6, 8, 10, 12, 14]
    #expect(subset == expected)
}

// MARK: - Empty-shape (scalar) array

@Test
func testEmptyShapeArray() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    // 0-D array (scalar)
    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [],
        chunks: [],
        dtype: "<i4",
        compressor: nil,
        fillValue: .int(42),
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "scalar")
    try await array.storeMetadata()
    // Do not store any chunk; it should use fill value.
    let result: [Int32] = try await array.retrieveArraySubset([])
    #expect(result == [42])
}

// MARK: - Type-mismatch error

@Test
func testTypeMismatchError() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4],
        chunks: [4],
        dtype: "<i4",  // int32
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: int32LERange(4))

    // Reading as Float (f4) should throw typeMismatch.
    await #expect(throws: ZarrElementError.self) {
        let _: [Float] = try await array.retrieveArraySubset([0..<4])
    }
}

// MARK: - Out-of-bounds slice

@Test
func testOutOfBoundsSlice() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [5],
        chunks: [5],
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: int32LERange(5))

    // Range beyond array bounds.
    await #expect(throws: ZarrArrayError.self) {
        let _: [Int32] = try await array.retrieveArraySubset([0..<6])
    }
}

// MARK: - retrieveChunkIfExists

@Test
func testRetrieveChunkIfExists() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [6],
        chunks: [3],
        dtype: "<i4",
        compressor: nil,
        fillValue: nil,
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()

    // Store only chunk [0]; chunk [1] is absent.
    let chunk0Data = Data(int32LERange(3).prefix(12))
    try await array.storeChunk([0], data: chunk0Data)

    let present: [Int32]? = try await array.retrieveChunkIfExists([0])
    #expect(present == [0, 1, 2])

    let absent: [Int32]? = try await array.retrieveChunkIfExists([1])
    #expect(absent == nil)
}

// MARK: - eraseChunk

@Test
func testEraseChunk() async throws {
    let tmp = try createTempDir()
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let meta = V2ArrayMetadata(
        zarrFormat: 2,
        shape: [4],
        chunks: [4],
        dtype: "<i4",
        compressor: nil,
        fillValue: .int(99),
        order: .C,
        filters: nil,
        dimensionSeparator: nil
    )
    let storage = LocalFileStorage(basePath: tmp)
    let array = try ZarrArray(metadata: meta, storage: storage, path: "arr")
    try await array.storeMetadata()
    try await storeAllChunks(array: array, data: int32LERange(4))

    // Chunk exists; read it back.
    let before: [Int32] = try await array.retrieveChunk([0])
    #expect(before == [0, 1, 2, 3])

    // Erase it; subsequent read should return fill value.
    try await array.eraseChunk([0])
    let after: [Int32] = try await array.retrieveChunk([0])
    #expect(after == [99, 99, 99, 99])
}
