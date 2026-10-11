import Foundation
import zlib

/// Why a gzip call failed; the transport then sends the body uncompressed with a WARN (HTTP 2).
package struct GzipError: Error, Equatable {
    package var code: Int32

    package init(code: Int32) {
        self.code = code
    }
}

/// gzip through the system `zlib`, which every iOS release ships (iOS HTTP 2): `deflateInit2_` with
/// the default level, window bits `15 + 16` for a gzip header and trailer, memory level 8, in one
/// in-memory pass. Apple's `Compression` framework writes a headerless deflate stream instead.
package enum Gzip {
    package static func compress(_ input: Data) throws(GzipError) -> Data {
        var stream = z_stream()
        var status = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw GzipError(code: status) }
        defer { deflateEnd(&stream) }
        let capacity = Int(deflateBound(&stream, UInt(input.count)))
        var output = [UInt8](repeating: 0, count: max(capacity, 32))
        let inputBytes = [UInt8](input)
        inputBytes.withUnsafeBufferPointer { inPointer in
            output.withUnsafeMutableBufferPointer { outPointer in
                stream.next_in = UnsafeMutablePointer(mutating: inPointer.baseAddress)
                stream.avail_in = UInt32(inPointer.count)
                stream.next_out = outPointer.baseAddress
                stream.avail_out = UInt32(outPointer.count)
                status = deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw GzipError(code: status) }
        return Data(output.prefix(Int(stream.total_out)))
    }
}
