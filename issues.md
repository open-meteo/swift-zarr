# SwiftZarr audit

Updated 2026-11-07. Findings below are based on the current source. Priority reflects correctness, reliability, performance, and implementation value. Performance effects are inferred from code, not measured speedups. No fresh passing test result is asserted here; the audit's test invocation had not completed when its report was prepared. The previous document's claim of 68 passing tests is historical and is not evidence for this revision.

## 20 priority issues

### 1. HTTP 400 can silently become fill-value data — resolved

**Resolved 2026-11-07.** `exists` now treats only HTTP 404 as absence; HTTP 400 and other failures propagate. [S3HTTPErrorTests](Tests/SwiftZarrTests/S3HTTPErrorTests.swift) uses a local HTTP server to exercise chunk reads and optional chunk reads for 400, 403, and 404.

**Original finding — High · Correctness · Small fix.** [S3CompatibleStorage.exists](Sources/SwiftZarr/Storage/S3CompatibleStorage.swift) returns false for both 400 and 404. Array reads interpret absence as a missing chunk and synthesize fill values. A malformed request can therefore produce successful-looking, incorrect results.

**Fix:** Treat only genuine not-found responses as absence and propagate other errors. Test a chunk request returning 400 and assert that it throws rather than returning fills.

### 2. Blosc metadata can trigger an integer-conversion trap

**High · Correctness · Small fix.** [CodecPipeline.resolveCompressor](Sources/SwiftZarr/Codec/CodecPipeline.swift) converts an arbitrary `clevel` metadata integer with `CInt(...)`. Values outside the 32-bit range trap; representable but invalid levels also escape early validation.

**Fix:** Validate the supported level range before conversion. Reject incorrectly typed configuration values instead of silently defaulting them. Cover out-of-range and wrong-type metadata.

### 3. Decompression has no output budget

**High · Robustness · Medium fix.** [Array.decodeChunk](Sources/SwiftZarr/Array/Array.swift) checks decoded length only after the pipeline completes. [LZ4Codec](Sources/SwiftZarr/Codec/LZ4Codec.swift) and [BloscCodec](Sources/SwiftZarr/Codec/BloscCodec.swift) allocate from input-supplied lengths; other decoders also lack an output limit in the interface. A tiny expected chunk can trigger a large allocation before rejection.

**Fix:** Pass expected sizes or output limits into decoding. Bound intermediate pipeline stages separately, since their sizes need not equal the final chunk size. Test hostile length headers and excessive expansion.

### 4. Blosc decoding is globally serialized

**High · Performance · Small fix.** [BloscCodec.decode](Sources/SwiftZarr/Codec/BloscCodec.swift) calls `blosc_decompress`. The [vendored implementation](Sources/CBlosc/deps/c-blosc/blosc/blosc.c) normally holds a global mutex around decompression. Concurrent Swift chunk tasks cannot decode independently through that path. Encoding already uses the context API.

**Fix:** Use `blosc_decompress_ctx`, initially with one internal thread per chunk. Benchmark concurrent decoding across realistic chunk sizes and avoid nested thread oversubscription.

### 5. Local writes are not atomic

**High · Correctness · Small fix.** [LocalFileStorage.write](Sources/SwiftZarr/Storage/LocalFileStorage.swift) writes directly to the destination. Interrupted writes can leave truncated objects, and concurrent readers can observe incomplete contents.

**Fix:** Use atomic replacement for individual objects. Document that this does not provide multi-object transactions or, by itself, crash-durable storage. Test replacement while readers are active.

### 6. Storage listing semantics differ between backends

**High · Architecture/correctness · Medium fix.** [LocalFileStorage.list](Sources/SwiftZarr/Storage/LocalFileStorage.swift) recursively returns prefix-relative files. [S3CompatibleStorage.list](Sources/SwiftZarr/Storage/S3CompatibleStorage.swift) uses a delimiter and returns full keys plus directory prefixes. Callers cannot substitute backends reliably.

**Fix:** Specify one recursive blob-listing contract and a separate immediate-directory contract. Run equivalent backend contract tests for depth, roots, nested prefixes, and returned key formats. The old empty-prefix-to-`/` S3 bug is already fixed.

### 7. S3 XML parsing and pagination can silently lose results

**High · Correctness · Medium fix.** [S3ListV1Parser](Sources/SwiftZarr/Storage/S3CompatibleStorage.swift) searches literal tags, trims object-name whitespace, and decodes only named entities. Numeric character references are not decoded; malformed XML can become an empty successful result. Truncated responses without a marker terminate silently, and repeated markers are not detected.

**Fix:** Use an XML parser, preserve key contents, and validate pagination progress. Test malformed documents, whitespace-bearing keys, numeric entities, and missing/repeated markers.

### 8. Present chunks require an existence check followed by a read

**High · Performance/correctness · Small fix.** [Array.readChunkRaw and retrieveChunkIfExists](Sources/SwiftZarr/Array/Array.swift) perform `exists` before `read`. S3 therefore needs sequential HEAD and GET requests per present chunk, with a deletion race between them. Metadata and attribute loading use similar patterns.

**Fix:** Read directly and catch only `StorageError.noSuchFile`. Preserve all other errors. Assert request counts and missing-object behavior with a recording backend.

### 9. Chunk scheduling introduces batch barriers

**High · Performance · Small fix.** [Array.readSubsetChunks](Sources/SwiftZarr/Array/Array.swift) waits for every task in a batch before scheduling the next batch. One slow request leaves completed slots idle.

**Fix:** Use a rolling bounded task group, submitting a replacement on each completion. Verify the concurrency bound and benchmark with variable request latency.

### 10. Concurrency ignores storage characteristics and memory budgets

**High · Performance/architecture · Medium fix.** [Array initialization](Sources/SwiftZarr/Array/Array.swift) chooses `max(4, activeProcessorCount)`. Large chunks on many-core machines can create excessive simultaneous allocations. CPU count is also a weak proxy for remote I/O concurrency, and independent subset calls multiply the load.

**Fix:** Expose read options for request concurrency and estimated in-flight bytes. Consider a shared limiter across reads. Measure peak memory as well as throughput.

### 11. All chunk coordinates are allocated before reading begins

**Medium · Performance · Medium fix.** [Array.collectChunkIndices](Sources/SwiftZarr/Array/Array.swift) materializes `chunkCount × ndim` integers, then allocates a coordinate array per scheduled chunk. Planning can dominate small-chunk, high-rank workloads; capacity multiplication is unchecked.

**Fix:** Generate coordinates lazily with an iterative multidimensional counter. Use checked arithmetic wherever capacity calculations remain.

### 12. Several async filesystem methods block executor threads

**Medium · Performance/architecture · Medium fix.** [LocalFileStorage](Sources/SwiftZarr/Storage/LocalFileStorage.swift) dispatches reads off the caller's executor, but writes, listings, existence checks, and deletion execute blocking filesystem calls directly inside async methods.

**Fix:** Use a consistent bounded blocking-I/O executor. Check cancellation before starting operations and define the behavior of already-running I/O. Exercise slow filesystem workloads without starving unrelated tasks.

### 13. Retry policy mishandles throttling, cancellation, and configuration

**Medium · Reliability · Medium fix.** [RetryingHTTPClient](Sources/SwiftZarr/Storage/RetryingHTTPClient.swift) retries 5xx but not 429 responses, retries all `HTTPClientError` values, and maps a caught `CancellationError` to `connectionFailed`. Unvalidated jitter and attempt settings can make backoff arithmetic unsafe.

**Fix:** Preserve cancellation, classify transient failures explicitly, support throttling delays, and validate configuration at construction. Use deterministic tests for attempts, cancellation, delays, and permanent failures.

### 14. chunkSize does not validate coordinates

**Medium · Correctness · Small fix.** [Array.chunkSize](Sources/SwiftZarr/Array/Array.swift) checks only rank before multiplying arbitrary indices by chunk dimensions. Invalid indices can produce negative or nonsensical dimensions; extreme inputs can overflow.

**Fix:** Call the existing `validateIndices` first. Test negative, out-of-grid, and extreme coordinates.

### 15. Compression settings are not consistently honored

**Medium · Correctness/API · Medium fix.** [CodecPipeline](Sources/SwiftZarr/Codec/CodecPipeline.swift) constructs gzip and zlib codecs without using configured levels. Bzip2 validates its level only during encoding. Metadata can describe settings the encoder did not use.

**Fix:** Validate configuration during array construction and honor supported encoding options. Reject unsupported options explicitly. Test encoder configuration independently of Swift readback.

### 16. Blosc accepts compressor names absent from the build

**Medium · Compatibility · Medium fix.** [Package.swift](Package.swift) enables LZ4 but does not compile the bundled zstd or zlib implementations. [CodecPipeline](Sources/SwiftZarr/Codec/CodecPipeline.swift) accepts arbitrary `cname` values, so unavailable compressors fail only during chunk operations.

**Fix:** Validate availability early and report the unsupported compressor clearly. Adding zstd support would expand interoperability; test both supported and unavailable configurations.

### 17. Public byte encoding accepts arbitrary Swift representations

**Medium · Correctness/API · Medium fix.** [ZarrDataType.data(from:)](Sources/SwiftZarr/DataType.swift) accepts unconstrained `T` and copies its memory representation without validating dtype kind or width. A String value serializes Swift representation bytes, not string contents.

**Fix:** Provide a constrained, throwing element encoder and typed `storeChunk` overload. Validate type/width and handle endian conversion centrally. Deprecate or restrict the unconstrained helper.

### 18. Fortran-order subset copying performs costly per-element work

**Medium · Performance · Medium fix.** [ChunkSlice.copy](Sources/SwiftZarr/Array/Array.swift) computes coordinates with division/modulo across dimensions for every F-order element, then performs a one-element copy.

**Fix:** Use incremental offsets and tiled transpose implementations for common ranks. Benchmark rank, dtype width, and slice geometry while retaining padded-edge and full-chunk correctness tests.

### 19. Group enumeration has unbounded fan-out and weak classification

**Medium · Reliability/performance · Medium fix.** [Group.listChildren](Sources/SwiftZarr/Group/Group.swift) launches one task per directory. Any V3 `node_type` other than `group` becomes an array; unrelated directories fail the entire listing.

**Fix:** Bound concurrency, explicitly recognize valid node types, and document whether non-Zarr directories are skipped or reported. Test invalid node types and large groups.

### 20. Arrays lack an attribute editing workflow

**Medium · Missing feature/API · Small-to-medium fix.** [Array](Sources/SwiftZarr/Array/Array.swift) does not load V2 `.zattrs`; V3 attributes remain inside immutable metadata. [Group](Sources/SwiftZarr/Group/Group.swift) already supports editable attributes and persistence.

**Fix:** Reuse the group snapshot model for arrays, with explicit persistence and independent-copy semantics. Test V2 and V3 attribute round trips.

## Reconciliation with the previous issues.md

The previous file contained eight numbered entries, not a complete 20-item list. Their status is:

| Previous entry | Current status |
| --- | --- |
| 10: Path normalization and storage escape | Partially fixed. Array/group constructors now normalize paths, reject traversal, and handle roots correctly. Direct LocalFileStorage calls still append unchecked paths; retain the residual issue below. |
| 12: V2/V3 codec conflation | The cited defects are fixed: CodecPipeline requires a serializer, respects bytes endianness, handles V3 shuffle strings, and forwards Blosc block size. Remaining validation/configuration gaps are covered by issues 2, 15, and 16. Unsupported transforms remain a capability limitation, not evidence that the current supported pipeline is incorrect. |
| 14: HEAD/GET and HTTP 400 | Still relevant; split into issues 1 and 8. |
| 15: Global Blosc mutex | Still relevant; issue 4. |
| 16: Batch barriers/eager coordinates | Still relevant; issues 9–11. |
| 17: Non-atomic/blocking local writes | Still relevant; issues 5 and 12. |
| 18: Listing contract | Still relevant; issues 6 and 7. The specific empty S3 prefix bug is fixed. |
| 20: Self-consistency-only tests | Substantially outdated. Independent Python fixtures and focused correctness tests now exist. A narrower compressed-write and performance coverage gap remains below. |

The old introduction's blanket assertions about broken V3 interoperability and malformed lengths reaching unchecked copies are not retained. Current code validates decoded chunk lengths before assembly, and independent fixtures exercise supported V3 layouts. This does not remove the pre-validation allocation problem in issue 3.

## Additional relevant items omitted from the 20-item audit

### A. Direct LocalFileStorage paths are not confined to basePath

**Potentially high when callers supply untrusted storage keys.** [LocalFileStorage](Sources/SwiftZarr/Storage/LocalFileStorage.swift) directly appends paths in its public methods. Array/group normalization protects normal high-level calls, but direct storage calls can still supply `..` components. Symlinks can also lead outside the root even for lexically valid keys.

**Fix:** Validate logical keys at the storage boundary and explicitly define whether basePath is merely a location prefix or an isolation boundary. If confinement is promised, enforce an appropriate symlink policy as well; lexical normalization alone is insufficient. Add direct-backend tests rather than relying only on [PathTests](Tests/SwiftZarrTests/PathTests.swift). For untrusted-key deployments, prioritize this ahead of lower-ranked API enhancements.

### B. Independent compressed-write validation and performance regression coverage remain gaps

[Interop documentation](Tests/Interop/README.md) and [InteroperabilityTests](Tests/SwiftZarrTests/InteroperabilityTests.swift) now include Python-generated fixtures, padded edges, V3 key encodings, endianness, fills, malformed decoded lengths, and independent uncompressed-write comparisons. [PublicMetadataConstructionTests](Tests/SwiftZarrTests/PublicMetadataConstructionTests.swift), [ChunkLayoutTests](Tests/SwiftZarrTests/ChunkLayoutTests.swift), and [CodecPipelineTests](Tests/SwiftZarrTests/CodecPipelineTests.swift) also address the older coverage complaints.

However, the interop documentation explicitly says compressed fixtures test reading only and do not verify that Swift encoding honors compression levels. The audit also supplies no measured performance baseline.

**Fix:** Decode Swift-written compressed stores with an independent implementation, and separately verify that encoding options are honored; successful decompression alone does not establish the selected level. Add reproducible package-level benchmarks for concurrent Blosc decode, remote request counts/latency, F-order assembly, and peak memory. Keep live network tests separate from deterministic tests.
