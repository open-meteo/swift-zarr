import CSwiftZarrZlib
import Foundation

/// Shared implementation for gzip and zlib framing.
internal enum DeflateCodec {
    static func encode(_ data: Data, windowBits: CInt, level: Int) throws -> Data {
        let minimumLevel = windowBits == 15 ? -1 : 0
        guard (minimumLevel...9).contains(level) else {
            throw CodecError.encodeFailed("compression level must be in \(minimumLevel)...9")
        }
        var stream = z_stream()
        let initialized = deflateInit2_(
            &stream,
            CInt(level),
            Z_DEFLATED,
            windowBits,
            8,
            Z_DEFAULT_STRATEGY,
            zlibVersion(),
            CInt(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else {
            throw CodecError.encodeFailed("zlib initialization failed: \(initialized)")
        }
        defer { deflateEnd(&stream) }
        var output = Data()
        var buffer = Data(count: 64 * 1024)
        try data.withUnsafeBytes { source in
            var supplied = 0
            while true {
                supplyInput(source, supplied: &supplied, stream: &stream)
                let previous = stream.avail_in
                let status = buffer.withUnsafeMutableBytes { destination in
                    stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress!
                    stream.avail_out = UInt32(destination.count)
                    return deflate(&stream, supplied == source.count ? Z_FINISH : Z_NO_FLUSH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                output.append(buffer.prefix(produced))
                if status == Z_STREAM_END { break }
                guard status == Z_OK, previous != stream.avail_in || produced != 0 else {
                    throw CodecError.encodeFailed("zlib compression failed: \(status)")
                }
            }
        }
        return output
    }

    static func decode(_ data: Data, windowBits: CInt) throws -> Data {
        try decode(data, windowBits: windowBits, destination: nil)
    }

    static func decode(_ data: Data, windowBits: CInt, into destination: UnsafeMutableRawBufferPointer) throws {
        _ = try decode(data, windowBits: windowBits, destination: destination)
    }

    private static func decode(
        _ data: Data,
        windowBits: CInt,
        destination: UnsafeMutableRawBufferPointer?
    ) throws -> Data {
        var stream = z_stream()
        let initialized = inflateInit2_(
            &stream,
            windowBits,
            zlibVersion(),
            CInt(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else {
            throw CodecError.invalidData("zlib initialization failed: \(initialized)")
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { source in
            var supplied = 0
            return try decodeStream(into: destination, bufferSize: 64 * 1024) { buffer in
                supplyInput(source, supplied: &supplied, stream: &stream)
                let previous = stream.avail_in
                let capacity = min(buffer.count, Int(UInt32.max))
                stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress!
                stream.avail_out = UInt32(capacity)
                let status = inflate(&stream, Z_NO_FLUSH)
                let produced = capacity - Int(stream.avail_out)
                if status == Z_STREAM_END {
                    if stream.avail_in != 0 || supplied < source.count {
                        // gzip permits concatenated members; each member has its own checksum.
                        guard windowBits == 31, inflateReset(&stream) == Z_OK else {
                            throw CodecError.invalidData("unexpected bytes after zlib stream")
                        }
                        return (produced, false)
                    }
                    return (produced, true)
                }
                guard status == Z_OK else {
                    throw CodecError.invalidData("zlib decompression failed: \(status)")
                }
                guard previous != stream.avail_in || produced != 0 else {
                    throw CodecError.invalidData("incomplete zlib stream")
                }
                return (produced, false)
            }
        }
    }

    private static func supplyInput(_ source: UnsafeRawBufferPointer, supplied: inout Int, stream: inout z_stream) {
        guard stream.avail_in == 0, supplied < source.count else { return }
        let count = min(source.count - supplied, Int(UInt32.max))
        stream.next_in = UnsafeMutablePointer(
            mutating: source.bindMemory(to: UInt8.self).baseAddress!.advanced(by: supplied)
        )
        stream.avail_in = UInt32(count)
        supplied += count
    }
}
