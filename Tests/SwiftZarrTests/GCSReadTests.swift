import Foundation
import Testing

@testable import SwiftZarr

let gcsBaseURL = "https://storage.googleapis.com/gcp-public-data-arco-era5"
let gcsStorePath = "ar/1959-2022-6h-64x32_equiangular_conservative.zarr"

// MARK: - Metadata tests

@Test
func testGCSGroupMetadata() async throws {
    let storage = try S3CompatibleStorage(baseURL: gcsBaseURL)
    let group = try await ZarrGroup(storage: storage, path: gcsStorePath)
    guard case .v2(let groupMeta) = group.metadata else {
        Issue.record("Expected V2 group metadata"); return
    }
    #expect(groupMeta.zarrFormat == 2)
}

@Test
func testGCSArrayMetadataLat() async throws {
    let storage = try S3CompatibleStorage(baseURL: gcsBaseURL)
    let lat = try await ZarrArray(storage: storage, path: "\(gcsStorePath)/latitude")
    #expect(lat.shape == [32])
    #expect(lat.chunkShape == [32])
    guard case .v2(let latMeta) = lat.metadata else {
        Issue.record("Expected V2 array metadata"); return
    }
    #expect(latMeta.dtype == "<f8")
    #expect(latMeta.compressorID == "blosc")
}

@Test
func testGCSArrayMetadataT2m() async throws {
    let storage = try S3CompatibleStorage(baseURL: gcsBaseURL)
    let t2m = try await ZarrArray(storage: storage, path: "\(gcsStorePath)/2m_temperature")
    #expect(t2m.shape == [92044, 64, 32])
    #expect(t2m.chunkShape == [100, 64, 32])
    guard case .v2(let t2mMeta) = t2m.metadata else {
        Issue.record("Expected V2 array metadata"); return
    }
    #expect(t2mMeta.dtype == "<f4")
}

@Test
func testGCSArrayMetadataLevel() async throws {
    let storage = try S3CompatibleStorage(baseURL: gcsBaseURL)
    let level = try await ZarrArray(storage: storage, path: "\(gcsStorePath)/level")
    #expect(level.shape == [13])
    guard case .v2(let levelMeta) = level.metadata else {
        Issue.record("Expected V2 array metadata"); return
    }
    #expect(levelMeta.dtype == "<i8")
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

// MARK: - S3 ListBucket XML parser tests

private func parseS3List(_ xml: String) throws -> S3ListV1Result {
    try S3ListV1Parser.parse(xml.data(using: .utf8)!)
}

@Test
func testS3ListParserExtractsKeysOnly() throws {
    let result = try parseS3List(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Contents>
            <Key>prefix/file1</Key>
            <Size>100</Size>
            <LastModified>2024-01-01T00:00:00Z</LastModified>
            <ETag>"abc123"</ETag>
          </Contents>
          <Contents>
            <Key>prefix/file2</Key>
            <Size>200</Size>
            <LastModified>2024-01-02T00:00:00Z</LastModified>
            <ETag>"def456"</ETag>
          </Contents>
          <CommonPrefixes>
            <Prefix>prefix/subdir/</Prefix>
          </CommonPrefixes>
        </ListBucketResult>
        """
    )
    #expect(result.keys == ["prefix/file1", "prefix/file2"])
    #expect(result.prefixes == ["prefix/subdir/"])
}

@Test
func testS3ListParserKeyWithWhitespace() throws {
    let result = try parseS3List(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Contents>
            <Key>
              prefix/file
            </Key>
            <Size>100</Size>
          </Contents>
        </ListBucketResult>
        """
    )
    #expect(result.keys == ["prefix/file"])
    #expect(result.prefixes == [])
}

@Test
func testS3ListParserEmptyResult() throws {
    let result = try parseS3List(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
        </ListBucketResult>
        """
    )
    #expect(result.keys == [])
    #expect(result.prefixes == [])
}

@Test
func testS3ListParserTopLevelPrefixNotCaptured() throws {
    // The top-level <Prefix> is an echo of the query prefix, not a result.
    // It must not appear in result.prefixes.
    let result = try parseS3List(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Prefix>some/query/prefix/</Prefix>
          <IsTruncated>false</IsTruncated>
          <CommonPrefixes>
            <Prefix>some/query/prefix/subdir/</Prefix>
          </CommonPrefixes>
        </ListBucketResult>
        """
    )
    #expect(result.prefixes == ["some/query/prefix/subdir/"])
    #expect(result.isTruncated == false)
}

@Test
func testS3ListParserTruncatedWithNextMarker() throws {
    let result = try parseS3List(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <IsTruncated>true</IsTruncated>
          <NextMarker>prefix/file1000</NextMarker>
          <Contents>
            <Key>prefix/file1</Key>
          </Contents>
          <Contents>
            <Key>prefix/file1000</Key>
          </Contents>
        </ListBucketResult>
        """
    )
    #expect(result.isTruncated == true)
    #expect(result.nextMarker == "prefix/file1000")
    #expect(result.keys == ["prefix/file1", "prefix/file1000"])
}

@Test
func testS3ListParserTruncatedWithoutNextMarker() throws {
    let result = try parseS3List(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <IsTruncated>true</IsTruncated>
          <Contents>
            <Key>prefix/file1</Key>
          </Contents>
          <Contents>
            <Key>prefix/file1000</Key>
          </Contents>
        </ListBucketResult>
        """
    )
    #expect(result.isTruncated == true)
    #expect(result.nextMarker == nil)
    #expect(result.keys.last == "prefix/file1000")
}

@Test
func testS3ListParserNotTruncated() throws {
    let result = try parseS3List(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>prefix/file1</Key>
          </Contents>
        </ListBucketResult>
        """
    )
    #expect(result.isTruncated == false)
    #expect(result.nextMarker == nil)
}

@Test
func testS3ListParserDecodesNamedEntities() throws {
    let result = try parseS3List(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <NextMarker>prefix/a&amp;b</NextMarker>
          <Contents>
            <Key>prefix/a&amp;b&lt;c&gt;&quot;d&apos;e</Key>
          </Contents>
          <CommonPrefixes>
            <Prefix>prefix/a&amp;b/</Prefix>
          </CommonPrefixes>
        </ListBucketResult>
        """
    )
    #expect(result.nextMarker == "prefix/a&b")
    #expect(result.keys == ["prefix/a&b<c>\"d'e"])
    #expect(result.prefixes == ["prefix/a&b/"])
}
