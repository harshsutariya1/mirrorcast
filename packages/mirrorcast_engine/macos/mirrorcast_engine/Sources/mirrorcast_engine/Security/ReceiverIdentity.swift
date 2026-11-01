import Foundation
import Security

/// This Mac's long-term TLS identity: an ECDSA P-256 private key in the
/// user's keychain plus a self-signed certificate.
///
/// - The private key never leaves the keychain.
/// - The certificate is public, so it's simply cached as a file in the app's
///   sandbox container.
/// - Phones pin the certificate's SHA-256 fingerprint when they pair. If the
///   identity is ever reset, every phone has to pair again (by design).
final class ReceiverIdentity {
    let identity: SecIdentity
    let certificateData: Data
    let fingerprint: Data

    var fingerprintHex: String { Fingerprint.hex(fingerprint) }

    private init(identity: SecIdentity, certificateData: Data) {
        self.identity = identity
        self.certificateData = certificateData
        self.fingerprint = Fingerprint.sha256(certificateData)
    }

    enum IdentityError: LocalizedError {
        case keychain(OSStatus, String)
        case certificate(String)

        var errorDescription: String? {
            switch self {
            case .keychain(let status, let step):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain error while \(step): \(message)"
            case .certificate(let message):
                return "Could not create the secure identity: \(message)"
            }
        }
    }

    private static let keyLabel = "MirrorCast Receiver Identity"
    private static let keyTag = Data("com.mirrorcast.receiver.identity.v1".utf8)

    /// Loads the identity, or creates one on first launch.
    static func loadOrCreate(storageDirectory: URL) throws -> ReceiverIdentity {
        let certificateURL = storageDirectory.appendingPathComponent("receiver-certificate.der")

        if let data = try? Data(contentsOf: certificateURL),
           let certificate = SecCertificateCreateWithData(nil, data as CFData),
           let identity = makeIdentity(certificate) {
            return ReceiverIdentity(identity: identity, certificateData: data)
        }

        // First launch (or the keychain item was deleted): start fresh.
        deleteKey()
        let privateKey = try createKey()
        let data: Data
        do {
            data = try SelfSignedCertificate.make(commonName: "MirrorCast Receiver", privateKey: privateKey)
        } catch {
            throw IdentityError.certificate("\(error)")
        }
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw IdentityError.certificate("invalid certificate")
        }
        guard let identity = makeIdentity(certificate) else {
            throw IdentityError.certificate("the keychain could not pair the key with its certificate")
        }
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try data.write(to: certificateURL, options: .atomic)
        return ReceiverIdentity(identity: identity, certificateData: data)
    }

    private static func createKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrLabel as String: keyLabel,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrLabel as String: keyLabel,
            ] as [String: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? Int(errSecInternalError)
            throw IdentityError.keychain(OSStatus(truncatingIfNeeded: code), "creating the private key")
        }
        return key
    }

    /// Finds the private key matching `certificate` in the keychain.
    private static func makeIdentity(_ certificate: SecCertificate) -> SecIdentity? {
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        return status == errSecSuccess ? identity : nil
    }

    private static func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
