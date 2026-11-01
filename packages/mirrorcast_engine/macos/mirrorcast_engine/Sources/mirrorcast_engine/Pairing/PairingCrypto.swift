import CryptoKit
import Foundation
import Security

/// The math behind pairing. Must stay byte-for-byte identical to
/// `PairingCrypto.kt` on Android (see the known-answer vectors in
/// `docs/PROTOCOL.md`).
///
/// PIN pairing checks the 6-digit code one bit per round, Bluetooth "passkey
/// entry" style. In each round both sides commit to (nonce, PIN bit, both TLS
/// certificate fingerprints) before revealing the nonce. An attacker in the
/// middle must guess every bit in advance: 20 rounds give it a 1 in 1,048,576
/// chance, and since the code changes after each failure it gets one try.
enum PairingCrypto {
    static let pinRounds = 20
    static let nonceSize = 16
    static let qrSecretSize = 16

    private static let labelSender = Data("MirrorCast-PIN-v1/sender".utf8)
    private static let labelReceiver = Data("MirrorCast-PIN-v1/receiver".utf8)
    private static let labelQR = Data("MirrorCast-QR-v1".utf8)

    static func pinBit(_ pin: Int, round: Int) -> UInt8 {
        UInt8((pin >> round) & 1)
    }

    static func senderCommit(nonce: Data, phoneFp: Data, macFp: Data, bit: UInt8) -> Data {
        hmac(key: nonce, [labelSender, phoneFp, macFp, Data([0x80 | bit])])
    }

    static func receiverCommit(nonce: Data, macFp: Data, phoneFp: Data, bit: UInt8) -> Data {
        hmac(key: nonce, [labelReceiver, macFp, phoneFp, Data([0x80 | bit])])
    }

    static func qrProof(secret: Data, phoneFp: Data, macFp: Data) -> Data {
        hmac(key: secret, [labelQR, phoneFp, macFp])
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "System random number generator failed")
        return Data(bytes)
    }

    /// A uniformly random 6-digit PIN (rejection sampling avoids modulo bias).
    static func randomPin() -> Int {
        while true {
            let value = randomBytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            if value < 4_294_000_000 { return Int(value % 1_000_000) }
        }
    }

    /// Compares without leaking where the first difference is.
    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    private static func hmac(key: Data, _ parts: [Data]) -> Data {
        var mac = HMAC<SHA256>(key: SymmetricKey(data: key))
        for part in parts { mac.update(data: part) }
        return Data(mac.finalize())
    }
}
