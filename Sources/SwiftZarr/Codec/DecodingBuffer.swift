import Foundation

/// Decode a block whose validated header supplies its output size.
/// A mismatched destination still requires payload validation before reporting the size error.
internal func decodeBuffer(
    size: Int,
    into destination: UnsafeMutableRawBufferPointer?,
    decode: (UnsafeMutableRawBufferPointer) throws -> Void
) throws -> Data {
    if let destination, destination.count == size {
        try decode(destination)
        return Data()
    }
    var output = Data(count: size)
    try output.withUnsafeMutableBytes(decode)
    if let destination {
        throw ZarrArrayError.invalidDataSize(expected: destination.count, got: size)
    }
    return output
}

/// Share output storage between streaming decoders. Each step must finish or make progress.
/// Once a fixed destination fills, drain into scratch storage to validate the remaining
/// frames and count excess bytes without allocating a second full decoded buffer.
internal func decodeStream(
    into destination: UnsafeMutableRawBufferPointer?,
    bufferSize: Int,
    step: (UnsafeMutableRawBufferPointer) throws -> (count: Int, finished: Bool)
) throws -> Data {
    var output = Data()
    var scratch = Data()
    var count = 0
    while true {
        let result: (count: Int, finished: Bool)
        if let destination, count < destination.count {
            result = try step(UnsafeMutableRawBufferPointer(rebasing: destination[count...]))
        } else {
            if scratch.isEmpty { scratch = Data(count: bufferSize) }
            result = try scratch.withUnsafeMutableBytes { buffer in
                let result = try step(buffer)
                if destination == nil {
                    output.append(buffer.bindMemory(to: UInt8.self).baseAddress!, count: result.count)
                }
                return result
            }
        }
        let (total, overflow) = count.addingReportingOverflow(result.count)
        guard !overflow else { throw CodecError.invalidData("decoded size overflows Int") }
        count = total
        if result.finished {
            if let destination, count != destination.count {
                throw ZarrArrayError.invalidDataSize(expected: destination.count, got: count)
            }
            return output
        }
    }
}
