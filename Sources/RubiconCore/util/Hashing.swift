import CryptoKit
import Foundation

package enum Hashing {
    private static let hex = Array("0123456789abcdef".utf8)

    /// The SHA-256 of `text` in UTF-8, as 64 lowercase hex characters. The event directory uses the
    /// first 16 of the API key's hash (Disk 2c). `CryptoKit` is an Apple framework, not a dependency.
    package static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hex[Int(byte >> 4)])
            out.append(hex[Int(byte & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
