import Foundation
import Network
import Security

/// TLS 1.3 server built on Network.framework.
///
/// - Presents this Mac's self-signed identity.
/// - Requires the phone to present a client certificate. The certificate is
///   accepted at the TLS layer and then checked against the trusted list by
///   `ClientSession`, which is why a fresh phone can still reach the pairing
///   flow but can never stream until it's paired.
/// - `TCP_NODELAY` is on so small packets are sent at once.
/// - If the preferred port is taken, the next few ports are tried.
final class ReceiverServer {
    static let defaultPort: UInt16 = 47474
    private static let portAttempts: UInt16 = 10

    private let identity: ReceiverIdentity
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var attempt: UInt16 = 0
    private var startCompletion: ((Result<UInt16, Error>) -> Void)?

    var onConnection: ((NWConnection) -> Void)?
    private(set) var port: UInt16 = 0

    init(identity: ReceiverIdentity, queue: DispatchQueue) {
        self.identity = identity
        self.queue = queue
    }

    func start(completion: @escaping (Result<UInt16, Error>) -> Void) {
        startCompletion = completion
        attempt = 0
        listen(on: Self.defaultPort)
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func listen(on port: UInt16) {
        do {
            let created = try NWListener(using: makeParameters(), on: NWEndpoint.Port(rawValue: port)!)
            created.newConnectionHandler = { [weak self] connection in self?.onConnection?(connection) }
            created.stateUpdateHandler = { [weak self] state in self?.listenerStateChanged(state, port: port) }
            listener = created
            created.start(queue: queue)
        } catch {
            retryOrFail(error, port: port)
        }
    }

    private func listenerStateChanged(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .ready:
            self.port = listener?.port?.rawValue ?? port
            startCompletion?(.success(self.port))
            startCompletion = nil
        case .failed(let error):
            listener?.cancel()
            listener = nil
            if startCompletion != nil {
                retryOrFail(error, port: port)
            } else {
                NSLog("MirrorCast: listener failed: \(error)")
            }
        default:
            break
        }
    }

    private func retryOrFail(_ error: Error, port: UInt16) {
        attempt += 1
        if attempt < Self.portAttempts {
            NSLog("MirrorCast: port \(port) unavailable (\(error)); trying \(port + 1)")
            listen(on: port + 1)
        } else {
            startCompletion?(.failure(error))
            startCompletion = nil
        }
    }

    private func makeParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)
        if let localIdentity = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(security, localIdentity)
        }
        // Ask for (and require) the phone's certificate...
        sec_protocol_options_set_peer_authentication_required(security, true)
        // ...but don't validate it against certificate authorities. It's
        // self-signed; ClientSession checks its fingerprint against the
        // trusted list instead.
        sec_protocol_options_set_verify_block(security, { _, _, complete in
            complete(true)
        }, queue)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.serviceClass = .interactiveVideo
        return parameters
    }
}
