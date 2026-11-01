import AppKit
import CoreMedia
import FlutterMacOS
import Foundation
import Network
import SystemConfiguration
import VideoToolbox

/// The heart of the macOS receiver. Owns the TLS server, the pairing window,
/// the trusted-phone list, the decoder, the audio player and the Flutter
/// texture, and routes packets between them.
///
/// Threading: everything here runs on `queue` (a serial, high-priority queue)
/// except the Flutter-facing entry points, which are called on the main thread
/// and hop onto `queue`. Window control stays on the main thread.
final class ReceiverController: ClientSessionHost {
    let queue = DispatchQueue(label: "com.mirrorcast.receiver", qos: .userInteractive)
    let windows: WindowController

    // ClientSessionHost
    private(set) var receiverName = "Mac"
    var receiverFingerprint: Data { identity?.fingerprint ?? Data() }
    let supportedDecoders: [String]
    let pairing = PairingCoordinator()
    let trustStore: TrustedDeviceStore

    private let emitter: EventEmitter
    private let textures: FlutterTextureRegistry
    private let storageDirectory: URL
    private var identity: ReceiverIdentity?
    private var server: ReceiverServer?
    private var sessions: [UUID: ClientSession] = [:]
    private var streamingSession: ClientSession?
    private var texture: VideoTexture?
    private let decoder = VideoDecoder()
    private lazy var audio = AudioPlayer(queue: queue)
    private let stats = StreamStats()
    private let clock = ClockSync()
    private var timer: DispatchSourceTimer?
    private var audioEnabled = false
    private var audioMuted = false
    private var lastKeyframeRequest = Date.distantPast
    private var videoInfo: [String: Any] = [:]

    private static let maxConnections = 8
    private static let streamIdleTimeout: TimeInterval = 10

    init(registrar: FlutterPluginRegistrar, emitter: EventEmitter) {
        self.emitter = emitter
        textures = registrar.textures
        windows = WindowController(view: registrar.view)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        storageDirectory = support.appendingPathComponent("MirrorCast", isDirectory: true)
        trustStore = TrustedDeviceStore(storageDirectory: storageDirectory)
        supportedDecoders = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? ["hevc", "avc"] : ["avc"]

        pairing.onChange = { [weak self] change in self?.pairingChanged(change) }
        windows.onChange = { [weak emitter] state in emitter?.emit(state) }
    }

    // MARK: - Flutter entry points (main thread)

    func initialize(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let texture = self.texture ?? VideoTexture(registry: textures)
        self.texture = texture
        windows.observe()

        queue.async { [self] in
            let reply = { (result: Result<[String: Any], Error>) in DispatchQueue.main.async { completion(result) } }
            if let server, server.port != 0 {
                return reply(.success(info()))
            }
            receiverName = Self.computerName()
            do {
                identity = try ReceiverIdentity.loadOrCreate(storageDirectory: storageDirectory)
            } catch {
                return reply(.failure(error))
            }
            configureDecoder(texture: texture)

            let newServer = ReceiverServer(identity: identity!, queue: queue)
            newServer.onConnection = { [weak self] connection in self?.accept(connection) }
            server = newServer
            newServer.start { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let port):
                    self.startTimer()
                    self.emitter.emit(["type": "server", "state": "listening", "port": Int(port)])
                    reply(.success(self.info()))
                case .failure(let error):
                    self.server = nil
                    self.emitter.emit(["type": "server", "state": "failed", "message": "\(error)"])
                    reply(.failure(error))
                }
            }
        }
    }

    func dispose() {
        let texture = self.texture
        self.texture = nil
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            for session in sessions.values { session.close() }
            sessions.removeAll()
            streamingSession = nil
            server?.stop()
            server = nil
            pairing.close(reason: "disposed")
            decoder.reset(codec: .avc)
            audio.stop()
            audioEnabled = false
            DispatchQueue.main.async { texture?.unregister() }
        }
    }

    func openPairing(completion: @escaping ([String: Any]) -> Void) {
        queue.async { [self] in
            let credential = pairing.open()
            let map = pairingMap(credential)
            DispatchQueue.main.async { completion(map) }
        }
    }

    func closePairing() {
        queue.async { [self] in pairing.close(reason: "cancelled") }
    }

    func trustedDevices(completion: @escaping ([[String: Any]]) -> Void) {
        queue.async { [self] in
            let list = trustStore.all().map(\.asMap)
            DispatchQueue.main.async { completion(list) }
        }
    }

    func revoke(_ fingerprint: String, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            let removed = trustStore.revoke(fingerprint)
            // Kick the phone off right away if it's connected.
            for session in sessions.values where session.peerFingerprintHex == fingerprint {
                session.close(reject: .notPaired, message: "This phone was removed on the Mac")
            }
            emitter.emit(["type": "devices"])
            DispatchQueue.main.async { completion(removed) }
        }
    }

    func disconnect() {
        queue.async { [self] in
            guard let session = streamingSession else { return }
            session.send(.bye, ["reason": "receiver"])
            queue.asyncAfter(deadline: .now() + 0.2) { session.close() }
        }
    }

    func setAudioMuted(_ muted: Bool) {
        queue.async { [self] in
            audioMuted = muted
            audio.isMuted = muted
            emitAudioState()
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard sessions.count < Self.maxConnections else {
            connection.cancel() // simple protection against connection floods
            return
        }
        let session = ClientSession(connection: PacketConnection(connection: connection, queue: queue), queue: queue, host: self)
        sessions[session.id] = session
        session.start()
    }

    func sessionWantsToStream(_ session: ClientSession) -> RejectCode? {
        guard trustStore.isTrusted(session.peerFingerprintHex) else {
            emitter.emit(["type": "session", "state": "rejected", "deviceName": session.deviceName, "reason": "not_paired"])
            return .notPaired
        }
        if let current = streamingSession, current !== session {
            return .busy
        }
        streamingSession = session
        trustStore.markSeen(session.peerFingerprintHex, name: session.deviceName, model: session.model)
        return nil
    }

    func sessionDidStartStreaming(_ session: ClientSession) {
        guard session === streamingSession else { return }
        beginStream(for: session)
    }

    func session(_ session: ClientSession, didReceive packet: Packet) {
        guard session === streamingSession else { return }
        switch packet.type {
        case .videoFormat:
            guard let body = try? packet.json() else { return }
            let codec = VideoDecoder.Codec(rawValue: body.string("codec") ?? "avc") ?? .avc
            decoder.reset(codec: codec)
            videoInfo = [
                "type": "video",
                "active": true,
                "codec": codec.rawValue,
                "width": body.int("width") ?? 0,
                "height": body.int("height") ?? 0,
                "fps": body.int("fps") ?? 0,
                "bitrate": body.int("bitrate") ?? 0,
            ]
            emitter.emit(videoInfo)
        case .videoConfig:
            stats.addBytes(packet.payload.count)
            decoder.handleConfig(packet.payload)
        case .videoFrame:
            stats.addBytes(packet.payload.count)
            decoder.decode(packet.payload, ptsUs: packet.ptsUs, isKeyframe: packet.isKeyframe)
        case .audioPCM:
            stats.addBytes(packet.payload.count)
            if audioEnabled { audio.enqueue(packet.payload) }
        case .audioState:
            let enabled = (try? packet.json())?.bool("enabled") ?? false
            setAudioEnabled(enabled)
        case .pong:
            if let body = try? packet.json(), let sentAt = body.int64("t"), let phoneTime = body.int64("p") {
                clock.addPong(sentAtUs: sentAt, phoneTimeUs: phoneTime)
            }
        case .bye:
            session.close()
        default:
            break // ignore unknown control packets from a trusted phone
        }
    }

    func sessionDidPair(_ session: ClientSession) {
        emitter.emit([
            "type": "pairing",
            "state": "paired",
            "deviceName": session.deviceName,
            "model": session.model,
            "fingerprint": session.peerFingerprintHex,
        ])
        emitter.emit(["type": "devices"])
    }

    func sessionPairingFailed(_ session: ClientSession, reason: String) {
        emitter.emit(["type": "pairing", "state": "failed", "reason": reason, "deviceName": session.deviceName])
    }

    func sessionDidClose(_ session: ClientSession, error: Error?) {
        sessions.removeValue(forKey: session.id)
        guard session === streamingSession else { return }
        streamingSession = nil
        endStream(deviceName: session.deviceName, error: error)
    }

    // MARK: - Streaming

    private func configureDecoder(texture: VideoTexture) {
        decoder.onFrame = { [weak self, weak texture] pixelBuffer, ptsUs in
            texture?.push(pixelBuffer)
            guard let self else { return }
            self.stats.frameDisplayed(latencyMs: self.clock.latencyMs(phonePtsUs: ptsUs))
        }
        decoder.onNeedKeyframe = { [weak self] in self?.requestKeyframe() }
        decoder.onDimensionsChanged = { [weak self] width, height in
            guard let self else { return }
            // The decoded size is authoritative (it accounts for encoder cropping).
            if !self.videoInfo.isEmpty {
                self.videoInfo["width"] = width
                self.videoInfo["height"] = height
                self.emitter.emit(self.videoInfo)
            }
            DispatchQueue.main.async { self.windows.setContentAspect(width: width, height: height) }
        }
    }

    private func beginStream(for session: ClientSession) {
        decoder.reset(codec: .avc)
        stats.reset()
        clock.reset()
        texture?.clear()
        emitter.emit([
            "type": "session",
            "state": "streaming",
            "deviceName": session.deviceName,
            "model": session.model,
            "fingerprint": session.peerFingerprintHex,
            "address": session.connection.remoteDescription,
        ])
        sendPing(to: session) // start clock sync immediately
    }

    private func endStream(deviceName: String, error: Error?) {
        decoder.reset(codec: .avc)
        setAudioEnabled(false)
        texture?.clear()
        videoInfo = [:]
        emitter.emit(["type": "video", "active": false])
        var event: [String: Any] = ["type": "session", "state": "idle", "deviceName": deviceName]
        if let error { event["reason"] = "\(error)" }
        emitter.emit(event)
    }

    private func setAudioEnabled(_ enabled: Bool) {
        guard enabled != audioEnabled else { return }
        audioEnabled = enabled
        if enabled {
            audio.start()
            audio.isMuted = audioMuted
        } else {
            audio.stop()
        }
        emitAudioState()
    }

    private func emitAudioState() {
        emitter.emit(["type": "audio", "enabled": audioEnabled, "muted": audioMuted])
    }

    private func requestKeyframe() {
        let now = Date()
        guard now.timeIntervalSince(lastKeyframeRequest) > 0.3, let session = streamingSession else { return }
        lastKeyframeRequest = now
        session.send(.keyframeRequest)
    }

    private func sendPing(to session: ClientSession) {
        session.send(.ping, ["t": NSNumber(value: ClockSync.nowMicros())])
    }

    private func startTimer() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    /// Once per second: clock sync, stats, timeouts.
    private func tick() {
        pairing.expireIfNeeded()
        guard let session = streamingSession else { return }

        if Date().timeIntervalSince(session.lastActivity) > Self.streamIdleTimeout {
            NSLog("MirrorCast: stream idle for \(Self.streamIdleTimeout)s, closing")
            session.close()
            return
        }

        sendPing(to: session)
        let snapshot = stats.takeSnapshot()
        var remote: [String: Any] = ["fps": snapshot.fps]
        if let latency = snapshot.latencyMs { remote["latencyMs"] = latency }
        if let rtt = clock.rttMs { remote["rttMs"] = rtt }
        session.send(.receiverStats, remote)

        var event: [String: Any] = [
            "type": "stats",
            "fps": snapshot.fps,
            "bitrateKbps": snapshot.bitrateKbps,
            "decodeErrors": decoder.decodeErrors,
            "audioBufferMs": audioEnabled ? audio.bufferedMilliseconds : 0,
            "audioDropped": audio.droppedChunks,
        ]
        if let latency = snapshot.latencyMs { event["latencyMs"] = latency }
        if let rtt = clock.rttMs { event["rttMs"] = rtt }
        emitter.emit(event)
    }

    // MARK: - Pairing

    private func pairingChanged(_ change: PairingCoordinator.Change) {
        switch change {
        case .updated(let credential):
            var event = pairingMap(credential)
            event["type"] = "pairing"
            event["state"] = "open"
            emitter.emit(event)
        case .closed(let reason):
            emitter.emit(["type": "pairing", "state": "closed", "reason": reason])
        }
    }

    private func pairingMap(_ credential: PairingCoordinator.Credential) -> [String: Any] {
        [
            "pin": credential.pinString,
            "secret": Self.base64URL(credential.secret),
            "expiresAt": Int64(credential.expiresAt.timeIntervalSince1970 * 1000),
            "fingerprint": identity?.fingerprintHex ?? "",
            "port": Int(server?.port ?? 0),
            "receiverName": receiverName,
        ]
    }

    // MARK: - Helpers

    private func info() -> [String: Any] {
        [
            "textureId": texture?.textureId ?? -1,
            "port": Int(server?.port ?? 0),
            "fingerprint": identity?.fingerprintHex ?? "",
            "receiverName": receiverName,
            "decoders": supportedDecoders,
        ]
    }

    private static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return Host.current().localizedName ?? "Mac"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
