// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftZarr",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SwiftZarr", targets: ["SwiftZarr"])
    ],
    dependencies: [
        .package(url: "https://github.com/tsolomko/SWCompression", from: "4.8.0"),
        .package(url: "https://github.com/swift-server/async-http-client", from: "1.30.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CSwiftZarrZlib",
            pkgConfig: "zlib",
            providers: [.brew(["zlib"]), .apt(["zlib1g-dev"])]
        ),
        // Match the vendored module name so Clang does not import zstd while compiling itself.
        .target(
            name: "libzstd",
            path: "Sources/CBlosc/deps/c-blosc/internal-complibs/zstd-1.5.6",
            sources: ["common", "compress", "decompress"],
            publicHeadersPath: "."
        ),
        .target(
            name: "CBlosc",
            dependencies: ["libzstd", "CSwiftZarrZlib"],
            sources: [
                "deps/c-blosc/blosc/blosc.c",
                "deps/c-blosc/blosc/blosclz.c",
                "deps/c-blosc/blosc/shuffle.c",
                "deps/c-blosc/blosc/shuffle-generic.c",
                "deps/c-blosc/blosc/shuffle-sse2.c",
                "deps/c-blosc/blosc/shuffle-avx2.c",
                "deps/c-blosc/blosc/bitshuffle-generic.c",
                "deps/c-blosc/blosc/bitshuffle-sse2.c",
                "deps/c-blosc/blosc/bitshuffle-avx2.c",
                "deps/c-blosc/blosc/fastcopy.c",
                "deps/c-blosc/internal-complibs/lz4-1.10.0/lz4.c",
                "deps/c-blosc/internal-complibs/lz4-1.10.0/lz4hc.c",
            ],
            cSettings: [
                .define("HAVE_LZ4"),
                .define("HAVE_ZSTD"),
                .define("HAVE_ZLIB"),
                .headerSearchPath("deps/c-blosc/blosc"),
                .headerSearchPath("deps/c-blosc/internal-complibs/lz4-1.10.0"),
                .headerSearchPath("include"),
            ]
        ),
        .target(
            name: "SwiftZarr",
            dependencies: [
                .product(name: "SWCompression", package: "SWCompression"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                "CBlosc",
                "CSwiftZarrZlib",
                "libzstd",
            ]
        ),
        .testTarget(
            name: "SwiftZarrTests",
            dependencies: ["SwiftZarr"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
