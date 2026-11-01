import Foundation

/// What a `ClientSession` needs from the receiver. Implemented by `ReceiverController`.
protocol ClientSessionHost: AnyObject {
    var receiverName: String { get }
    var receiverFingerprint: Data { get }
    var supportedDecoders: [String] { get }
    var pairing: PairingCoordinator { get }
    var trustStore: TrustedDeviceStore { get }

    /// Returns nil to accept the stream, or the reason to refuse it. Must not
    /// send anything to the phone: WELCOME has to be the first packet it gets.
    func sessionWantsToStream(_ session: ClientSession) -> RejectCode?
    /// Called right after WELCOME was sent; from here on the Mac may send PINGs etc.
    func sessionDidStartStreaming(_ session: ClientSession)
    func session(_ session: ClientSession, didReceive packet: Packet)
    func sessionDidPair(_ session: ClientSession)
    func sessionPairingFailed(_ session: ClientSession, reason: String)
    func sessionDidClose(_ session: ClientSession, error: Error?)
}

/// One phone connection: handshake, then either pairing or streaming.
///
/// State machine:
///
///     awaitingHello --HELLO(stream)--> streaming
///                   --HELLO(pair_pin)--> pinPairing(round 0..19) --> paired
///                   --HELLO(pair_qr)--> qrPairing --> paired
///
/// Anything unexpected sends REJECT and closes the connection.
final class ClientSession {
    enum Mode {
        case awaitingHello
        case pinPairing(round: Int, theirCommit: Data?, ourNonce: Data?)
        case qrPairing
        case streaming
        case finished
    }

    let id = UUID()
    let connection: PacketConnection
    private let queue: DispatchQueue
    private weak var host: ClientSessionHost?

    private(set) var mode: Mode = .awaitingHello
    private(set) var peerFingerprint = Data()
    private(set) var deviceName = "Phone"
    private(set) var model = ""
    private(set) var lastActivity = Date()
    private var credential: PairingCoordinator.Credential?
    private var timeout: DispatchWorkItem?

    var peerFingerprintHex: String { Fingerprint.hex(peerFingerprint) }
    var isStreaming: Bool { if case .streaming = mode { return true } else { return false } }
    private var isPairing: Bool {
        switch mode {
        case .pinPairing, .qrPairing: return true
        default: return false
        }
    }

    static let helloTimeout: TimeInterval = 10
    static let pairingTimeout: TimeInterval = 60

    init(connection: PacketConnection, queue: DispatchQueue, host: ClientSessionHost) {
        self.connection = connection
        self.queue = queue
        self.host = host
    }

    func start() {
        connection.onReady = { [weak self] in self?.connectionReady() }
        connection.onPacket = { [weak self] packet in self?.handle(packet) }
        connection.onClose = { [weak self] error in self?.connectionClosed(error) }
        connection.start()
    }

    /// Closes the connection, optionally telling the phone why.
    func close(reject code: RejectCode? = nil, message: String = "") {
        if let code {
            connection.sendControl(.reject, ["code": code.rawValue, "message": message])
        }
        // Give the reject a moment to flush before cancelling the socket.
        let connection = self.connection
        queue.asyncAfter(deadline: .now() + (code == nil ? 0 : 0.2)) { connection.close() }
    }

    func send(_ type: PacketType, _ body: [String: Any] = [:]) {
        connection.sendControl(type, body)
    }

    // MARK: - Connection lifecycle

    private func connectionReady() {
        guard let fingerprint = connection.peerCertificateFingerprint() else {
            NSLog("MirrorCast: rejecting connection without a client certificate")
            return close()
        }
        peerFingerprint = fingerprint
        arm(timeout: Self.helloTimeout)
    }

    private func connectionClosed(_ error: Error?) {
        timeout?.cancel()
        if isPairing { host?.pairing.attemptFailed(id) }
        mode = .finished
        host?.sessionDidClose(self, error: error)
    }

    private func arm(timeout seconds: TimeInterval) {
        timeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSLog("MirrorCast: session timed out in mode \(self.mode)")
            if self.isPairing { self.host?.sessionPairingFailed(self, reason: "timeout") }
            self.close(reject: .protocolError, message: "Timed out")
        }
        timeout = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: - Packet handling

    private func handle(_ packet: Packet) {
        lastActivity = Date()
        do {
            switch mode {
            case .awaitingHello:
                guard packet.type == .hello else { throw ProtocolError.malformed("expected HELLO") }
                try handleHello(packet.json())
            case .pinPairing(let round, let theirCommit, let ourNonce):
                try handlePinRound(packet, round: round, theirCommit: theirCommit, ourNonce: ourNonce)
            case .qrPairing:
                try handleQrProof(packet)
            case .streaming:
                host?.session(self, didReceive: packet)
            case .finished:
                break
            }
        } catch {
            NSLog("MirrorCast: protocol violation from \(connection.remoteDescription): \(error)")
            if isPairing { host?.sessionPairingFailed(self, reason: "protocol") }
            close(reject: .protocolError, message: "\(error)")
        }
    }

    private func handleHello(_ body: [String: Any]) throws {
        guard let host else { return close() }
        guard body.int("protocol") == Wire.protocolVersion else {
            return close(reject: .unsupportedVersion, message: "This Mac speaks protocol \(Wire.protocolVersion)")
        }
        guard let intent = body.string("intent").flatMap(SessionIntent.init(rawValue:)) else {
            throw ProtocolError.malformed("unknown intent")
        }
        deviceName = body.string("deviceName") ?? "Phone"
        model = body.string("model", maxLength: 96) ?? ""

        let welcome: [String: Any] = [
            "protocol": Wire.protocolVersion,
            "receiverName": host.receiverName,
            "decoders": host.supportedDecoders,
        ]

        switch intent {
        case .stream:
            if let refusal = host.sessionWantsToStream(self) {
                return close(reject: refusal)
            }
            timeout?.cancel()
            mode = .streaming
            // WELCOME must be the first packet the phone receives.
            send(.welcome, welcome)
            host.sessionDidStartStreaming(self)

        case .pairPin, .pairQr:
            guard let credential = host.pairing.beginAttempt(id) else {
                return close(reject: .pairingClosed, message: "Pairing is not open on this Mac")
            }
            self.credential = credential
            mode = intent == .pairPin ? .pinPairing(round: 0, theirCommit: nil, ourNonce: nil) : .qrPairing
            arm(timeout: Self.pairingTimeout)
            send(.welcome, welcome)
        }
    }

    /// One round of PIN pairing (see `PairingCrypto` for the reasoning).
    private func handlePinRound(_ packet: Packet, round: Int, theirCommit: Data?, ourNonce: Data?) throws {
        guard let host, let credential else { throw ProtocolError.malformed("no pairing credential") }
        let body = try packet.json()
        guard body.int("round") == round, let value = (body["value"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            throw ProtocolError.malformed("pairing round")
        }
        let bit = PairingCrypto.pinBit(credential.pin, round: round)
        let macFp = host.receiverFingerprint

        switch (packet.type, theirCommit) {
        case (.pairCommit, nil):
            // Phone committed; answer with our own commitment.
            guard value.count == 32 else { throw ProtocolError.malformed("commit size") }
            let nonce = PairingCrypto.randomBytes(PairingCrypto.nonceSize)
            let commit = PairingCrypto.receiverCommit(nonce: nonce, macFp: macFp, phoneFp: peerFingerprint, bit: bit)
            mode = .pinPairing(round: round, theirCommit: value, ourNonce: nonce)
            send(.pairCommit, ["round": round, "value": commit.base64EncodedString()])

        case (.pairReveal, let commit?):
            // Phone revealed its nonce: verify it used the same PIN bit.
            guard value.count == PairingCrypto.nonceSize, let ourNonce else { throw ProtocolError.malformed("reveal") }
            let expected = PairingCrypto.senderCommit(nonce: value, phoneFp: peerFingerprint, macFp: macFp, bit: bit)
            guard PairingCrypto.constantTimeEquals(expected, commit) else {
                host.sessionPairingFailed(self, reason: "code_mismatch")
                host.pairing.attemptFailed(id)
                self.credential = nil
                mode = .finished
                return close(reject: .codeMismatch)
            }
            send(.pairReveal, ["round": round, "value": ourNonce.base64EncodedString()])
            if round + 1 == PairingCrypto.pinRounds {
                completePairing()
            } else {
                mode = .pinPairing(round: round + 1, theirCommit: nil, ourNonce: nil)
            }

        default:
            throw ProtocolError.malformed("pairing message out of order")
        }
    }

    private func handleQrProof(_ packet: Packet) throws {
        guard let host, let credential else { throw ProtocolError.malformed("no pairing credential") }
        guard packet.type == .pairProof,
              let proof = (try packet.json()["proof"] as? String).flatMap({ Data(base64Encoded: $0) })
        else { throw ProtocolError.malformed("expected PAIR_PROOF") }

        let expected = PairingCrypto.qrProof(secret: credential.secret, phoneFp: peerFingerprint, macFp: host.receiverFingerprint)
        guard PairingCrypto.constantTimeEquals(expected, proof) else {
            host.sessionPairingFailed(self, reason: "invalid_qr")
            host.pairing.attemptFailed(id)
            self.credential = nil
            mode = .finished
            return close(reject: .codeMismatch, message: "The QR code is no longer valid")
        }
        completePairing()
    }

    private func completePairing() {
        guard let host else { return }
        timeout?.cancel()
        host.trustStore.trust(fingerprint: peerFingerprintHex, name: deviceName, model: model)
        host.pairing.attemptSucceeded(id)
        credential = nil
        mode = .finished
        send(.pairResult, ["ok": true, "receiverName": host.receiverName])
        host.sessionDidPair(self)
        // The phone closes the connection; make sure it doesn't linger.
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.close() }
    }
}
