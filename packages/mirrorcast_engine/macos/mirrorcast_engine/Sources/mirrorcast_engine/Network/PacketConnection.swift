import Foundation
import Network
import Security

/// Reads and writes MirrorCast packets on one TLS `NWConnection`.
///
/// All callbacks run on the queue passed to `init`. Reading is a simple loop:
/// receive exactly 14 header bytes, validate them, receive exactly `length`
/// payload bytes, deliver, repeat. Anything malformed closes the connection.
final class PacketConnection {
    let connection: NWConnection
    private let queue: DispatchQueue
    private var isClosed = false

    var onReady: (() -> Void)?
    var onPacket: ((Packet) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    var remoteDescription: String {
        switch connection.endpoint {
        case .hostPort(let host, _): return "\(host)"
        default: return "\(connection.endpoint)"
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receiveHeader()
            case .failed(let error), .waiting(let error):
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func close() {
        finish(nil)
    }

    /// Sends one packet. Errors close the connection.
    func send(_ type: PacketType, payload: Data = Data(), ptsUs: Int64 = 0, flags: UInt8 = 0) {
        guard !isClosed else { return }
        var data = PacketHeader.encode(type: type, flags: flags, ptsUs: ptsUs, length: payload.count)
        data.append(payload)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            self?.queue.async { self?.finish(error) }
        })
    }

    func sendControl(_ type: PacketType, _ body: [String: Any] = [:]) {
        send(type, payload: Control.encode(body))
    }

    /// SHA-256 of the phone's TLS client certificate, available once `.ready`.
    func peerCertificateFingerprint() -> Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        var leaf: Data?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            guard leaf == nil else { return } // first certificate = the phone's own
            let secCertificate = sec_certificate_copy_ref(certificate).takeRetainedValue()
            leaf = SecCertificateCopyData(secCertificate) as Data
        }
        return leaf.map(Fingerprint.sha256)
    }

    // MARK: - Reading

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: Wire.headerSize, maximumLength: Wire.headerSize) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let error { return self.finish(error) }
            guard let data, data.count == Wire.headerSize else {
                return self.finish(isComplete ? nil : ProtocolError.malformed("short header"))
            }
            do {
                let header = try PacketHeader.parse(data)
                if header.length == 0 {
                    self.deliver(Packet(type: header.type, flags: header.flags, ptsUs: header.ptsUs, payload: Data()))
                    self.receiveHeader()
                } else {
                    self.receivePayload(header)
                }
            } catch {
                self.finish(error)
            }
        }
    }

    private func receivePayload(_ header: PacketHeader) {
        connection.receive(minimumIncompleteLength: header.length, maximumLength: header.length) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let error { return self.finish(error) }
            guard let data, data.count == header.length else {
                return self.finish(isComplete ? nil : ProtocolError.malformed("short payload"))
            }
            self.deliver(Packet(type: header.type, flags: header.flags, ptsUs: header.ptsUs, payload: data))
            self.receiveHeader()
        }
    }

    private func deliver(_ packet: Packet) {
        guard !isClosed else { return }
        onPacket?(packet)
    }

    private func finish(_ error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        let callback = onClose
        onClose = nil
        onPacket = nil
        onReady = nil
        callback?(error)
    }
}
