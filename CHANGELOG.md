# Changelog

## [0.1.2](https://github.com/open-meteo/swift-zarr/compare/v0.1.1...v0.1.2) (2026-06-04)


### Bug Fixes

* pagination in S3 listing ([#7](https://github.com/open-meteo/swift-zarr/issues/7)) ([7d2c3ed](https://github.com/open-meteo/swift-zarr/commit/7d2c3ed3e9b8209aaaeb002d8b7988d8f419281f))
* S3CompatibleStorage retry during body collect  ([#5](https://github.com/open-meteo/swift-zarr/issues/5)) ([e1d01e8](https://github.com/open-meteo/swift-zarr/commit/e1d01e860ee09976f74a88b4254d21887e461c3b))

## [0.1.1](https://github.com/open-meteo/swift-zarr/compare/v0.1.0...v0.1.1) (2026-06-03)


### Bug Fixes

* proper retry logic for s3 backend ([#3](https://github.com/open-meteo/swift-zarr/issues/3)) ([5f87323](https://github.com/open-meteo/swift-zarr/commit/5f87323c120f6f365cbac04a3827fef72451bb70))

## 0.1.0 (2026-05-28)


### Features

* add release-please config ([0a95d5e](https://github.com/open-meteo/swift-zarr/commit/0a95d5e9c08168e4782e7b633e1b17b85b835c92))
* initial version ([ddc6c6c](https://github.com/open-meteo/swift-zarr/commit/ddc6c6cf87bd3126ac04a3e14f7a3c4cb8f8a0e6))


### Bug Fixes

* BloscCodec init on big endian systems ([dae0710](https://github.com/open-meteo/swift-zarr/commit/dae071059502f26452040efaeb0f1f7fc7ab5973))
* bool decoding ([beb2e34](https://github.com/open-meteo/swift-zarr/commit/beb2e3414baa7fe6bf0ed6f21cd8a16c720eeedd))
* checkout with submodule ([d556307](https://github.com/open-meteo/swift-zarr/commit/d55630769a7f9b9c8e5c7497c8c125795139dfc2))
* directory listing on mac os ([d2e438d](https://github.com/open-meteo/swift-zarr/commit/d2e438d01a611b81bbaa137e8fcc9cb2da3cd189))
* do not store FileManager in Sendable class ([2371504](https://github.com/open-meteo/swift-zarr/commit/237150405f43a8d234c0e28f741f41d67ad11023))
* do not swallow v3 metadata silently ([51eb993](https://github.com/open-meteo/swift-zarr/commit/51eb993b0653faa0b5dc7145137a309fe334c4c6))
* linter ([b5b353b](https://github.com/open-meteo/swift-zarr/commit/b5b353b0925e0e672eb89e43522d0d2e4c35894b))
* only test on swift 6.1 and 6.2 ([1ab8bf4](https://github.com/open-meteo/swift-zarr/commit/1ab8bf4d29db9a89185de1ff193027ffc2364de2))
* potential fix for path resolution on mac os ([972fe3c](https://github.com/open-meteo/swift-zarr/commit/972fe3cb47a8f9676f898c83da344c8c9228c9f8))
* release please manifest empty for initial release ([5b590c9](https://github.com/open-meteo/swift-zarr/commit/5b590c92c5ddb66a4e19c7a455d3780f00c03b7d))
* release please should not require package-name ([7861739](https://github.com/open-meteo/swift-zarr/commit/7861739db359abaa14bbdda66b48379ece380276))
* remove FoundationNetworking import ([3929468](https://github.com/open-meteo/swift-zarr/commit/392946810dd9a0751df3b253147cf2e6664be6cb))
* separate macos versions for 6.1 and 6.2 ([cd0a187](https://github.com/open-meteo/swift-zarr/commit/cd0a187e4fbb8f2ac9f5fcb5817dfaaadad68a33))
* swift 6.3 not yet supported ([4b1a802](https://github.com/open-meteo/swift-zarr/commit/4b1a802c13ffa801a7ebd7d512419ae8ee08d286))
* update to test on macos-26 ([d624211](https://github.com/open-meteo/swift-zarr/commit/d6242111c09a5e49245f54ccc0c3472dfbd7fdeb))
* use AsyncHttpClient instead of URLSession ([0673efb](https://github.com/open-meteo/swift-zarr/commit/0673efb73381eaf8fdae0101e88f6c4e24ed1e58))
* use ZarrDataType.Kind over String ([2a4e65a](https://github.com/open-meteo/swift-zarr/commit/2a4e65a60bc98ff7c800df2ab4014f9b113bd4b4))
* v3 nested subgroups ([72eef71](https://github.com/open-meteo/swift-zarr/commit/72eef711f21c0e18140eeb9f6247d9e864b61417))
