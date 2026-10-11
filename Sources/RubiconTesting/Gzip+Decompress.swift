import Foundation
import RubiconCore
import zlib

extension Gzip {
    /// The inverse of `compress`, for the tests that check a request body: `inflateInit2_` with
    /// the gzip window, growing the output as needed.
    package static func decompress(_ input: Data) throws -> Data {
        var stream = z_stream()
        var status = inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw GzipError(code: status) }
        defer { inflateEnd(&stream) }
        var output = Data()
        let inputBytes = [UInt8](input)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        try inputBytes.withUnsafeBufferPointer { inPointer in
            stream.next_in = UnsafeMutablePointer(mutating: inPointer.baseAddress)
            stream.avail_in = UInt32(inPointer.count)
            repeat {
                let produced: Int = chunk.withUnsafeMutableBufferPointer { outPointer in
                    stream.next_out = outPointer.baseAddress
                    stream.avail_out = UInt32(outPointer.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return outPointer.count - Int(stream.avail_out)
                }
                output.append(chunk, count: produced)
                guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                    throw GzipError(code: status)
                }
            } while status != Z_STREAM_END && stream.avail_in > 0
        }
        guard status == Z_STREAM_END else { throw GzipError(code: status) }
        return output
    }
}
