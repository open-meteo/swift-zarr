// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SwiftZarr",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "SwiftZarr", targets: ["SwiftZarr"])
    ],
    dependencies: [
        .package(url: "https://github.com/tsolomko/SWCompression", from: "4.8.0")
    ],
    targets: [
        .target(
            name: "CBlosc",
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
                .headerSearchPath("deps/c-blosc/blosc"),
                .headerSearchPath("deps/c-blosc/internal-complibs/lz4-1.10.0"),
                .headerSearchPath("include"),
            ]
        ),
        .target(
            name: "SwiftZarr",
            dependencies: [
                .product(name: "SWCompression", package: "SWCompression"),
                "CBlosc",
            ]
        ),
        .testTarget(
            name: "SwiftZarrTests",
            dependencies: ["SwiftZarr"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
