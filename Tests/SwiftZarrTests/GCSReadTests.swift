import Foundation
import Testing

@testable import SwiftZarr

#if canImport(FoundationXML)
import FoundationXML
#endif

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

@Test
func testS3ListParserExtractsKeysOnly() throws {
    let xml = """
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
        """.data(using: .utf8)!
    let parser = XMLParser(data: xml)
    let delegate = S3ListParserDelegate()
    parser.delegate = delegate
    let parsed = parser.parse()
    #expect(parsed)
    #expect(delegate.keys == ["prefix/file1", "prefix/file2"])
    #expect(delegate.prefixes == ["prefix/subdir/"])
}

@Test
func testS3ListParserKeyWithWhitespace() throws {
    let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Contents>
            <Key>
              prefix/file
            </Key>
            <Size>100</Size>
          </Contents>
        </ListBucketResult>
        """.data(using: .utf8)!
    let parser = XMLParser(data: xml)
    let delegate = S3ListParserDelegate()
    parser.delegate = delegate
    let parsed = parser.parse()
    #expect(parsed)
    #expect(delegate.keys == ["prefix/file"])
    #expect(delegate.prefixes == [])
}

@Test
func testS3ListParserEmptyResult() throws {
    let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
        </ListBucketResult>
        """.data(using: .utf8)!
    let parser = XMLParser(data: xml)
    let delegate = S3ListParserDelegate()
    parser.delegate = delegate
    let parsed = parser.parse()
    #expect(parsed)
    #expect(delegate.keys == [])
    #expect(delegate.prefixes == [])
}

@Test
func testS3ListParserTopLevelPrefixNotCaptured() throws {
    // The top-level <Prefix> is an echo of the query prefix, not a result.
    // It must not appear in delegate.prefixes.
    let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Prefix>some/query/prefix/</Prefix>
          <IsTruncated>false</IsTruncated>
          <CommonPrefixes>
            <Prefix>some/query/prefix/subdir/</Prefix>
          </CommonPrefixes>
        </ListBucketResult>
        """.data(using: .utf8)!
    let parser = XMLParser(data: xml)
    let delegate = S3ListParserDelegate()
    parser.delegate = delegate
    #expect(parser.parse())
    #expect(delegate.prefixes == ["some/query/prefix/subdir/"])
    #expect(delegate.isTruncated == false)
}

@Test
func testS3ListParserTruncatedWithNextMarker() throws {
    let xml = """
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
        """.data(using: .utf8)!
    let parser = XMLParser(data: xml)
    let delegate = S3ListParserDelegate()
    parser.delegate = delegate
    #expect(parser.parse())
    #expect(delegate.isTruncated == true)
    #expect(delegate.nextMarker == "prefix/file1000")
    #expect(delegate.keys == ["prefix/file1", "prefix/file1000"])
}

@Test
func testS3ListParserTruncatedWithoutNextMarker() throws {
    // Some providers omit NextMarker even when truncated.
    // The caller should fall back to keys.last as the marker.
    let xml = """
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
        """.data(using: .utf8)!
    let parser = XMLParser(data: xml)
    let delegate = S3ListParserDelegate()
    parser.delegate = delegate
    #expect(parser.parse())
    #expect(delegate.isTruncated == true)
    #expect(delegate.nextMarker == nil)
    #expect(delegate.keys.last == "prefix/file1000")
}

@Test
func testS3ListParserNotTruncated() throws {
    let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>prefix/file1</Key>
          </Contents>
        </ListBucketResult>
        """.data(using: .utf8)!
    let parser = XMLParser(data: xml)
    let delegate = S3ListParserDelegate()
    parser.delegate = delegate
    #expect(parser.parse())
    #expect(delegate.isTruncated == false)
    #expect(delegate.nextMarker == nil)
}
