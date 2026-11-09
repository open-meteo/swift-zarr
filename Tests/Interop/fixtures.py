# /// script
# requires-python = ">=3.11"
# dependencies = ["zarr==3.1.3", "numpy==2.3.4", "numcodecs==0.16.3"]
# ///
"""Generate independent, committed stores and expected values. Run with uv."""
import gzip
import json
from pathlib import Path

import numpy as np
import numcodecs
import zarr
from zarr.codecs import BytesCodec, GzipCodec, BloscCodec, ZstdCodec

FIXTURES = Path(__file__).resolve().parents[1] / "SwiftZarrTests" / "Fixtures"
CASES = {
    "v2-c": dict(zarr_format=2, dtype="<i4", order="C", compressors=None),
    "v2-f-big": dict(zarr_format=2, dtype=">i4", order="F", compressors=None),
    "v3-slash": dict(zarr_format=3, dtype="int32", serializer=BytesCodec(endian="little"), compressors=None),
    "v3-dot-big-gzip": dict(zarr_format=3, dtype="int32", serializer=BytesCodec(endian="big"),
                            compressors=[GzipCodec(level=1)], chunk_key_encoding={"name": "default", "configuration": {"separator": "."}}),
    "v3-v2-keys": dict(zarr_format=3, dtype="int32", serializer=BytesCodec(endian="little"),
                       compressors=None, chunk_key_encoding={"name": "v2", "configuration": {"separator": "/"}}),
    "v3-missing": dict(zarr_format=3, dtype="int32", serializer=BytesCodec(endian="little"), compressors=None),
    "v2-scalar": dict(zarr_format=2, dtype="<i4", compressors=None),
    "v3-scalar": dict(zarr_format=3, dtype="int32", serializer=BytesCodec(endian="little"),
                      compressors=None, chunk_key_encoding={"name": "default", "configuration": {"separator": "."}}),
}

for mode, shuffle in [("none", 0), ("byte", 1), ("bit", 2)]:
    CASES[f"v2-blosc-{mode}"] = dict(zarr_format=2, dtype="<i4",
        compressors=numcodecs.Blosc(cname="lz4", clevel=1, shuffle=shuffle, blocksize=0))
    CASES[f"v3-blosc-{mode}"] = dict(zarr_format=3, dtype="int32", serializer=BytesCodec(endian="little"),
        compressors=[BloscCodec(cname="lz4", clevel=1, shuffle=["noshuffle", "shuffle", "bitshuffle"][shuffle], typesize=4)])
CASES["v3-blosc-blocks"] = dict(zarr_format=3, dtype="int32", serializer=BytesCodec(endian="little"),
    compressors=[BloscCodec(cname="lz4hc", clevel=9, shuffle="bitshuffle", typesize=8, blocksize=256)])
for level in (1, 9):
    CASES[f"v2-zlib-{level}"] = dict(zarr_format=2, dtype="<i4", compressors=numcodecs.Zlib(level=level))
    CASES[f"v2-bz2-{level}"] = dict(zarr_format=2, dtype="<i4", compressors=numcodecs.BZ2(level=level))
for level in (0, 9):
    CASES[f"v3-gzip-{level}"] = dict(zarr_format=3, dtype="int32", serializer=BytesCodec(endian="little"), compressors=[GzipCodec(level=level)])
CASES["v2-lz4"] = dict(zarr_format=2, dtype="<i4", compressors=numcodecs.LZ4(acceleration=3))

CASES["v2-blosc-auto"] = dict(zarr_format=2, dtype="<i4",
    compressors=numcodecs.Blosc(cname="lz4", shuffle=-1))
CASES["v2-blosc-typesize"] = dict(zarr_format=2, dtype="<i4",
    compressors=numcodecs.Blosc(cname="lz4", shuffle=2, typesize=8))
CASES["v3-blosc-level0-blocks"] = dict(zarr_format=3, dtype="int32", serializer=BytesCodec(endian="little"),
    compressors=[BloscCodec(cname="lz4", clevel=0, shuffle="noshuffle", typesize=4, blocksize=256)])


for checksum in (False, True):
    suffix = "checksum" if checksum else "no-checksum"
    CASES[f"v2-zstd-{suffix}"] = dict(zarr_format=2, dtype="<i4",
        compressors=numcodecs.Zstd(level=-3, checksum=checksum))
    CASES[f"v3-zstd-{suffix}"] = dict(zarr_format=3, dtype="int32",
        serializer=BytesCodec(endian="little"),
        compressors=[ZstdCodec(level=0, checksum=checksum)])
CASES["v2-blosc-zstd-byte"] = dict(zarr_format=2, dtype="<i4",
    compressors=numcodecs.Blosc(cname="zstd", clevel=3, shuffle=1))
CASES["v3-blosc-zstd-bit"] = dict(zarr_format=3, dtype="int32",
    serializer=BytesCodec(endian="little"),
    compressors=[BloscCodec(cname="zstd", clevel=3, shuffle="bitshuffle", typesize=4)])


def expected(name):
    if name.endswith("scalar"):
        return np.array(42, dtype="int32")
    shape = (17, 19) if name.endswith("-blocks") else ((9, 9) if "blosc" in name else (3, 5))
    indices = np.arange(np.prod(shape), dtype="int32")
    if "blosc" in name:
        indices %= 8
    values = (indices * 17 - 11).reshape(shape)
    if name == "v3-missing":
        values[2:, 3:] = -7
    return values


def chunk_key(name, indices):
    if name.startswith("v2"):
        return ".".join(map(str, indices)) if indices else "0"
    if name == "v3-v2-keys":
        return "/".join(map(str, indices))
    separator = "." if name in ("v3-dot-big-gzip", "v3-scalar") else "/"
    return separator.join(["c", *map(str, indices)])


LIMITS = [
    ("bool", "bool", True, "little"),
    ("uint8-max", "uint8", 255, "little"),
    ("int8-min", "int8", -128, "little"),
    ("uint64-max", "uint64", 2**64 - 1, "big"),
    ("uint64-exact", "uint64", 2**63 + 1, "little"),
    ("int64-min", "int64", -(2**63), "big"),
    ("int64-max", "int64", 2**63 - 1, "little"),
    ("float32-nan", "float32", float("nan"), "little"),
    ("float32-infinity", "float32", float("inf"), "big"),
    ("float32-negative-infinity", "float32", -float("inf"), "little"),
    ("float32-negative-zero", "float32", -0.0, "big"),
    ("float64-negative-zero", "float64", -0.0, "little"),
]


def generate_limits():
    manifest = []
    for version in (2, 3):
        for label, dtype, fill, endian in LIMITS:
            name = f"v{version}-fill-{label}"
            options = dict(zarr_format=version, compressors=None)
            if version == 2:
                options["dtype"] = np.dtype(dtype).newbyteorder("<" if endian == "little" else ">")
            else:
                options.update(dtype=dtype, serializer=BytesCodec(endian=endian))
            array = zarr.create_array(str(FIXTURES / name), shape=(3,), chunks=(2,),
                                      fill_value=fill, overwrite=True, **options)
            expected_values = np.full(3, fill, dtype=dtype)
            np.testing.assert_array_equal(array[:], expected_values)
            bits = int.from_bytes(expected_values.astype(np.dtype(dtype).newbyteorder("<")).tobytes()[:np.dtype(dtype).itemsize], "little")
            manifest.append(dict(name=name, type=dtype, bits=bits))
    (FIXTURES / "limits.json").write_text(json.dumps(manifest, indent=2) + "\n")


def generate():
    FIXTURES.mkdir(parents=True, exist_ok=True)
    manifest = []
    for name, options in CASES.items():
        values = expected(name)
        shape = values.shape
        chunks = (16, 16) if name.endswith("-blocks") else ((8, 8) if "blosc" in name else ((2, 3) if shape else ()))
        store = FIXTURES / name
        if options["zarr_format"] == 3 and shape:
            options = dict(options, dimension_names=["rows", None])
        array = zarr.create_array(str(store), shape=shape, chunks=chunks, fill_value=-7,
                                  overwrite=True, **options)
        if name == "v3-missing":
            array[:2, :] = values[:2, :]
            array[2:, :3] = values[2:, :3]
        else:
            array[...] = values
        if options["zarr_format"] == 3:
            array.attrs["description"] = "Zarr-Python interoperability fixture"
        # numcodecs stamps gzip headers with wall-clock time. Normalize only
        # that timestamp; payload/compression still comes from Zarr-Python.
        if "gzip" in name:
            for path in store.rglob("*"):
                if not path.is_file() or path.name == "zarr.json":
                    continue
                encoded = path.read_bytes()
                assert encoded[:4] == b"\x1f\x8b\x08\x00"
                path.write_bytes(encoded[:4] + bytes(4) + encoded[8:])
        np.testing.assert_array_equal(array[...], values)
        if "blosc" in name and "level0" not in name:
            encoded = (store / chunk_key(name, (0, 0))).read_bytes()
            assert not encoded[2] & 2, f"{name}: first chunk bypassed compression/shuffle"
        # Independent nominal chunk buffers for exercising Swift's writer. NumPy
        # supplies padding and physical C/F order; no Swift helpers are involved.
        buffers = []
        grid = tuple((size + chunk - 1) // chunk for size, chunk in zip(shape, chunks))
        for indices in np.ndindex(grid) if options["compressors"] is None else []:
            if not (store / chunk_key(name, indices)).is_file():
                continue
            block = np.full(chunks, -7, dtype="int32")
            slices = tuple(slice(i * c, min((i + 1) * c, s)) for i, c, s in zip(indices, chunks, shape))
            valid = values[slices]
            block[tuple(slice(0, n) for n in valid.shape)] = valid
            buffers.append(dict(indices=list(indices), values=block.ravel(order=options.get("order", "C")).tolist()))
        manifest.append(dict(name=name, shape=list(shape), chunks=list(chunks), values=values.ravel().tolist(),
                             bigEndian=name in ("v2-f-big", "v3-dot-big-gzip"), buffers=buffers))
    # Valid gzip streams whose decoded payloads violate the nominal chunk size.
    malformed = FIXTURES / "malformed"
    malformed.mkdir(exist_ok=True)
    payload = gzip.decompress((FIXTURES / "v3-dot-big-gzip" / "c.0.0").read_bytes())
    for data in [payload[:-4], payload + bytes(4)]:
        (malformed / f"{len(data)}.gzip").write_bytes(gzip.compress(data, mtime=0))
    (FIXTURES / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    generate_limits()
    print(f"Generated {len(CASES) + 2 * len(LIMITS)} stores with Zarr-Python {zarr.__version__}")


if __name__ == "__main__":
    generate()
