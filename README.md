# SwiftZarr

A native Swift library for reading and writing [Zarr](https://zarr.dev) V2 and V3 arrays. Inspired by and related to the [zarrs](https://github.com/zarrs/zarrs) Rust library.

## Requirements

- Swift 6.0+
- Swift Package Manager
- macOS 15+ / iOS 18+

## Installation

Add SwiftZarr as a dependency in your `Package.swift`:

<!-- x-release-please-start-version -->

```swift
dependencies: [
    .package(url: "https://github.com/open-meteo/swift-zarr", from: "0.1.5"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "SwiftZarr", package: "swift-zarr"),
        ]
    ),
]
```

<!-- x-release-please-end -->

## Features

- **Zarr V2 and V3** — read and write arrays and groups
- **Codecs** — Blosc+LZ4 (vendored c-blosc), gzip, zlib, bzip2, and uncompressed
- **Storage backends** — local filesystem, S3-compatible (AWS, GCS, etc.)
- **Typed reads** — generic `retrieveChunk` and `retrieveArraySubset` returning typed Swift arrays
- **Slice/subset reading** — retrieve arbitrary N-dimensional ranges without loading full chunks
- **C and F order** — row-major and column-major chunk layouts
- **Fill values** — missing chunks transparently return the array fill value, including NaN/Infinity/hex
- **Parallel chunk fetching** — concurrent chunk reads using Swift structured concurrency

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

Create an array from metadata, then save it explicitly. Array initialization validates
dimensions, supported metadata, and codec configuration:

```swift
let localStorage = LocalFileStorage(basePath: "/path/to/store")
let metadata = V3ArrayMetadata(
    shape: [100],
    dataType: "float32",
    chunkGrid: .init(configuration: .init(chunkShape: [20])),
    fillValue: .int(0),
    codecs: [.init(name: "bytes", configuration: ["endian": .string("little")])]
)
let array = try ZarrArray(metadata: metadata, storage: localStorage, path: "example")
try await array.storeMetadata()
```

Group attributes are editable local snapshots for both V2 and V3. Save edits explicitly:

```swift
let localStorage = LocalFileStorage(basePath: "/path/to/store")
var group = try await ZarrGroup(storage: localStorage, path: "example")
group.attributes["description"] = .string("Updated description")
try await group.storeMetadata()
```

Copies keep independent snapshots. Reopen a group to read external changes. Failed saves retain local edits for retry; V2 metadata and attributes are written as separate files. This replaces the previous `attributes()` and `storeAttributes(_:)` methods.

## Development

```bash
swift build
swift test
```

## TODO

- V2 filter support (nonempty filter chains are currently rejected)
- Zstd codec (requires a separate dependency not included in SWCompression)
- Consolidated metadata (`.zmetadata`) to reduce round-trips on remote storage
- LRU chunk cache to avoid redundant decompression for overlapping reads
- bfloat16 data type support

## License

MIT. See [LICENSE](LICENSE).
