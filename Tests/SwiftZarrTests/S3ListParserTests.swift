import Foundation
import Testing

@testable import SwiftZarr

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
