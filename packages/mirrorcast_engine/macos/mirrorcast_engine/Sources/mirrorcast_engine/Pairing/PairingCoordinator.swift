import Foundation

/// Owns the "pairing window": the period after you click "Pair new phone"
/// during which a phone may pair using the PIN or the QR code.
///
/// Rules:
/// - The window lasts 2 minutes.
/// - Only one pairing attempt can run at a time.
/// - The PIN and QR secret are single-use: any failed or abandoned attempt
///   immediately replaces them, so an attacker never gets a second guess at
///   the same code.
/// - After 5 failures the window closes.
///
/// Not thread-safe: use from the receiver queue only.
final class PairingCoordinator {
    struct Credential {
        let pin: Int
        let secret: Data
        let expiresAt: Date

        var pinString: String { String(format: "%06d", pin) }
    }

    enum Change {
        case updated(Credential)
        case closed(reason: String)
    }

    static let lifetime: TimeInterval = 120
    static let maxFailures = 5

    private(set) var credential: Credential?
    private var activeAttempt: UUID?
    private var failures = 0

    var onChange: ((Change) -> Void)?

    var isOpen: Bool {
        guard let credential else { return false }
        return credential.expiresAt > Date()
    }

    @discardableResult
    func open() -> Credential {
        failures = 0
        activeAttempt = nil
        return rotate()
    }

    func close(reason: String) {
        guard credential != nil else { return }
        credential = nil
        activeAttempt = nil
        onChange?(.closed(reason: reason))
    }

    /// Reserves the current credential for one attempt, or nil if pairing isn't possible now.
    func beginAttempt(_ id: UUID) -> Credential? {
        guard let credential, credential.expiresAt > Date(), activeAttempt == nil else { return nil }
        activeAttempt = id
        return credential
    }

    func attemptSucceeded(_ id: UUID) {
        guard activeAttempt == id else { return }
        activeAttempt = nil
        credential = nil
        onChange?(.closed(reason: "paired"))
    }

    /// Call for wrong codes *and* for attempts that disconnect midway.
    func attemptFailed(_ id: UUID) {
        guard activeAttempt == id else { return }
        activeAttempt = nil
        failures += 1
        if failures >= Self.maxFailures {
            close(reason: "too_many_attempts")
        } else {
            rotate()
        }
    }

    func expireIfNeeded() {
        if let credential, credential.expiresAt <= Date(), activeAttempt == nil {
            close(reason: "expired")
        }
    }

    @discardableResult
    private func rotate() -> Credential {
        let next = Credential(
            pin: PairingCrypto.randomPin(),
            secret: PairingCrypto.randomBytes(PairingCrypto.qrSecretSize),
            expiresAt: Date().addingTimeInterval(Self.lifetime)
        )
        credential = next
        onChange?(.updated(next))
        return next
    }
}
