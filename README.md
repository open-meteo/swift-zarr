# SwiftZarr

A native Swift Zarr V2/V3 reader/writer port. Lives in the `swift/` subdirectory of the [zarrs] Rust workspace.

Supports Blosc+LZ4 (via vendored c-blosc), gzip, zlib, and bzip2 (via SWCompression) compressed arrays, as well as uncompressed arrays.

## Feature comparison with zarrs (Rust)

### Implemented

| Feature | zarrs (Rust) | SwiftZarr |
|---|---|---|
| V2 array read | ✅ | ✅ |
| V2 group read | ✅ | ✅ |
| V3 array read | ✅ | ✅ |
| V3 group read | ✅ | ✅ |
| V2 attrs | ✅ | ✅ |
| Blosc decompression | ✅ | ✅ (LZ4 only) |
| Gzip decompression | ✅ | ✅ |
| Zlib decompression | ✅ | ✅ |
| BZip2 decompression | ✅ | ✅ |
| Shuffle filter | ✅ | ✅ (via blosc) |
| C order (row-major) | ✅ | ✅ |
| F order (column-major) | ✅ | ✅ |
| NaN/Infinity/hex fill values | ✅ | ✅ |
| Missing chunks → fill | ✅ | ✅ |
| Integer fill values | ✅ | ✅ |
| Parallel chunk reading | ✅ | ✅ |
| Typed reads (generic) | ✅ | ✅ |
| Slice/subset reading | ✅ | ✅ |
| S3-compatible storage | ✅ | ✅ |
| GCS S3-compatible listing | ✅ | ✅ (via S3 XML `ListBucket` API) |
| Local filesystem storage | ✅ | ✅ |
| V2 array write | ✅ | ✅ |
| V2 group write | ✅ | ✅ |
| Array/group type distinction | ✅ | ✅ |

### Not implemented (prioritised)

| # | Feature | Priority | Reason |
|---|---|---|---|---|
| 1 | **Zstd codec** | Medium | Not in SWCompression — needs separate dependency |
| 2 | **Consolidated metadata** | Medium | `.zmetadata` avoids N+1 HEAD requests per child in `listChildren()` |
| 4 | **Chunk cache** | Low | LRU cache for decoded chunks |
| 5 | **float16/bfloat16 / complex types** | Low | Not in ERA5 |
| 6 | **vlen-utf8 / vlen-bytes** | Low | Variable-length string types |
| 8 | **Standalone Shuffle codec** | Low | Blosc includes shuffle |
| 9 | **ndarray integration** | Low | Return `ArraySlice` or similar |
| 10 | **CRC32C / Adler32 checksums** | Low | Identity read doesn't verify |

## Remaining work

### High
- (none — all high-priority items complete)

### Medium
- **Zstd codec**: needs separate dependency (not in SWCompression)
- **Consolidated metadata (`.zmetadata`)**: read once instead of N+1 HEAD requests per child in `listChildren()`
- **V3 attributes**: read attributes from `zarr.json` instead of separate `.zattrs`

### Low
- **Cached `BloscCodec` instance**: allocate once instead of one per `decompress()` call
- **Chunk cache**

## Building

```bash
cd swift
swift build
swift test
```

## Usage

```swift
import SwiftZarr

let storage = try S3CompatibleStorage(baseURL: "https://storage.googleapis.com/gcp-public-data-arco-era5")
let path = "ar/1959-2022-6h-64x32_equiangular_conservative.zarr"

let group = try await ZarrGroup(storage: storage, path: path)
let children = try await group.listChildren()

let lat = try await group.openArray(name: "latitude")
let values: [Double] = try await lat.retrieveChunk([0])

let t2m = try await group.openArray(name: "2m_temperature")
let slice: [Float] = try await t2m.retrieveArraySubset([0..<10, 0..<64, 0..<8])
```

[zarrs]: https://github.com/zarrs/zarrs
