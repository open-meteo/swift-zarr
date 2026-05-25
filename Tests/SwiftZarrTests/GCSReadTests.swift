import Foundation
import Testing

@testable import SwiftZarr

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let gcsBaseURL = "https://storage.googleapis.com/gcp-public-data-arco-era5"
let gcsStorePath = "ar/1959-2022-6h-64x32_equiangular_conservative.zarr"

// MARK: - Metadata tests

@Test
func testGCSGroupMetadata() async throws {
    let storage = try S3CompatibleStorage(baseURL: gcsBaseURL)
    let group = try await ZarrGroup(storage: storage, path: gcsStorePath)
    #expect(group.metadata.zarrFormat == 2)
}

@Test
func testGCSArrayMetadataLat() async throws {
    let storage = try S3CompatibleStorage(baseURL: gcsBaseURL)
    let lat = try await ZarrArray(storage: storage, path: "\(gcsStorePath)/latitude")
    #expect(lat.shape == [32])
    #expect(lat.chunkShape == [32])
    #expect(lat.metadata.dtype == "<f8")
    #expect(lat.metadata.compressorID == "blosc")
}

@Test
func testGCSArrayMetadataT2m() async throws {
    let storage = try S3CompatibleStorage(baseURL: gcsBaseURL)
    let t2m = try await ZarrArray(storage: storage, path: "\(gcsStorePath)/2m_temperature")
    #expect(t2m.shape == [92044, 64, 32])
    #expect(t2m.chunkShape == [100, 64, 32])
    #expect(t2m.metadata.dtype == "<f4")
}

@Test
func testGCSArrayMetadataLevel() async throws {
    let storage = try S3CompatibleStorage(baseURL: gcsBaseURL)
    let level = try await ZarrArray(storage: storage, path: "\(gcsStorePath)/level")
    #expect(level.shape == [13])
    #expect(level.metadata.dtype == "<i8")
}

// MARK: - Typed reads

@Test
func testGCSLatitudeTypedRead() async throws {
    let storage = try S3CompatibleStorage(baseURL: gcsBaseURL)
    let lat = try await ZarrArray(storage: storage, path: "\(gcsStorePath)/latitude")

    let values: [Double] = try await lat.retrieveChunk([0])
    #expect(values.count == 32)
    for v in values {
        #expect(v >= -90)
        #expect(v <= 90)
    }
    print("Latitude: \(values.prefix(5))...\(values.suffix(3))")
}

@Test
func testGCSLevelTypedRead() async throws {
    let storage = try S3CompatibleStorage(baseURL: gcsBaseURL)
    let level = try await ZarrArray(storage: storage, path: "\(gcsStorePath)/level")

    let values: [Int64] = try await level.retrieveChunk([0])
    #expect(values == [50, 100, 150, 200, 250, 300, 400, 500, 600, 700, 850, 925, 1000])
    print("Level: \(values)")
}

@Test
func testGCSTemperatureTypedRead() async throws {
    let storage = try S3CompatibleStorage(baseURL: gcsBaseURL)
    let t2m = try await ZarrArray(storage: storage, path: "\(gcsStorePath)/2m_temperature")

    let values: [Float] = try await t2m.retrieveChunk([0, 0, 0])
    #expect(values.count == 100 * 64 * 32)
    print("2m_temperature chunk 0.0.0: first 5 = \(values.prefix(5))")
}

// MARK: - Group listing

@Test
func testGCSListChildren() async throws {
    let storage = try S3CompatibleStorage(baseURL: gcsBaseURL)
    let group = try await ZarrGroup(storage: storage, path: gcsStorePath)
    let children = try await group.listChildren()
    let names = children.map(\.name).sorted()
    print("Group children: \(names)")
    #expect(names.contains("latitude"))
    #expect(names.contains("longitude"))
    #expect(names.contains("level"))
    #expect(names.contains("2m_temperature"))
    #expect(names.contains("10m_u_component_of_wind"))
    #expect(names.contains("10m_v_component_of_wind"))
    #expect(children.count >= 4)
}
