import Foundation
import Security

/// Builds a minimal X.509 v3 certificate for an ECDSA P-256 key.
///
/// macOS has no public API to create a certificate, so this writes the DER
/// encoding directly (about 60 lines). The certificate is self-signed and is
/// never validated against a CA: phones trust it only because they recorded
/// its SHA-256 fingerprint during pairing.
enum SelfSignedCertificate {
    enum BuildError: Error {
        case publicKeyExport(String)
        case signing(String)
        case invalidCertificate
    }

    static func make(commonName: String, privateKey: SecKey, validYears: Int = 25) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw BuildError.publicKeyExport("no public key") }
        var error: Unmanaged<CFError>?
        guard let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw BuildError.publicKeyExport(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }

        let algorithm = DER.sequence([DER.oid(OID.ecdsaWithSHA256)])
        let name = DER.sequence([
            DER.set([DER.sequence([DER.oid(OID.commonName), DER.utf8String(commonName)])]),
        ])
        let now = Date()
        let notAfter = Calendar(identifier: .gregorian).date(byAdding: .year, value: validYears, to: now) ?? now
        let validity = DER.sequence([DER.time(now.addingTimeInterval(-86_400)), DER.time(notAfter)])
        let subjectPublicKeyInfo = DER.sequence([
            DER.sequence([DER.oid(OID.ecPublicKey), DER.oid(OID.prime256v1)]),
            DER.bitString([UInt8](publicBytes)),
        ])
        let extensions = DER.explicit(3, DER.sequence([
            // basicConstraints (critical): not a CA
            DER.sequence([DER.oid(OID.basicConstraints), DER.boolean(true), DER.octetString(DER.sequence([]))]),
            // keyUsage (critical): digitalSignature
            DER.sequence([DER.oid(OID.keyUsage), DER.boolean(true), DER.octetString(DER.bitString([0x80], unusedBits: 7))]),
        ]))

        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else {
            throw BuildError.signing("random serial")
        }
        serial[0] = (serial[0] & 0x7F) | 0x01 // positive and non-zero

        let tbs = DER.sequence([
            DER.explicit(0, DER.integer([2])), // version v3
            DER.integer(serial),
            algorithm,
            name, // issuer
            validity,
            name, // subject (self-signed)
            subjectPublicKeyInfo,
            extensions,
        ])

        guard let signature = SecKeyCreateSignature(
            privateKey, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &error
        ) as Data? else {
            throw BuildError.signing(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }

        let certificate = Data(DER.sequence([tbs, algorithm, DER.bitString([UInt8](signature))]))
        guard SecCertificateCreateWithData(nil, certificate as CFData) != nil else { throw BuildError.invalidCertificate }
        return certificate
    }
}

/// Encoded object identifiers (the bytes after the 0x06 tag).
private enum OID {
    static let ecdsaWithSHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02] // 1.2.840.10045.4.3.2
    static let ecPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01] // 1.2.840.10045.2.1
    static let prime256v1: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07] // 1.2.840.10045.3.1.7
    static let commonName: [UInt8] = [0x55, 0x04, 0x03] // 2.5.4.3
    static let basicConstraints: [UInt8] = [0x55, 0x1D, 0x13] // 2.5.29.19
    static let keyUsage: [UInt8] = [0x55, 0x1D, 0x0F] // 2.5.29.15
}

/// Tiny DER (Distinguished Encoding Rules) writer: just what a certificate needs.
private enum DER {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes = [UInt8]()
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
    static func oid(_ encoded: [UInt8]) -> [UInt8] { tlv(0x06, encoded) }
    static func utf8String(_ text: String) -> [UInt8] { tlv(0x0C, Array(text.utf8)) }
    static func octetString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }
    static func boolean(_ value: Bool) -> [UInt8] { tlv(0x01, [value ? 0xFF : 0x00]) }
    static func explicit(_ number: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | number, content) }

    static func bitString(_ bytes: [UInt8], unusedBits: UInt8 = 0) -> [UInt8] {
        tlv(0x03, [unusedBits] + bytes)
    }

    /// Unsigned big-endian integer, minimally encoded.
    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var value = Array(bytes.drop { $0 == 0 })
        if value.isEmpty { value = [0] }
        if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
        return tlv(0x02, value)
    }

    /// UTCTime before 2050, GeneralizedTime after (RFC 5280 section 4.1.2.5).
    static func time(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2000
        if year < 2050 {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(0x17, Array(formatter.string(from: date).utf8))
        }
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return tlv(0x18, Array(formatter.string(from: date).utf8))
    }
}
