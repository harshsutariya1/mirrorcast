import CryptoKit
import Foundation

/// Certificate fingerprints: SHA-256 of the DER-encoded certificate.
enum Fingerprint {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Parses 64 hex characters (colons and spaces allowed).
    static func parse(_ text: String) -> Data? {
        let clean = text.lowercased().filter { $0 != ":" && !$0.isWhitespace }
        guard clean.count == 64 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
