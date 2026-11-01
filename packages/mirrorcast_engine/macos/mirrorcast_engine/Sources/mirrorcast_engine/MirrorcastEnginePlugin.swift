import Cocoa
import FlutterMacOS

/// Entry point of the macOS engine: the bridge between Dart (control plane)
/// and the native data plane.
///
/// Method channel `com.mirrorcast/control`:
///  - `initReceiver()` -> {textureId, port, fingerprint, receiverName, decoders}
///  - `disposeReceiver()`
///  - `openPairing()` -> {pin, secret, expiresAt, fingerprint, port, receiverName}
///  - `closePairing()`
///  - `listTrustedDevices()` -> [{fingerprint, name, model, pairedAt, lastSeenAt}]
///  - `revokeDevice({fingerprint})` -> Bool
///  - `disconnect()`
///  - `setAudioMuted({muted})`
///  - `setAlwaysOnTop({enabled})`, `toggleFullScreen()`, `setMiniPlayer({enabled})`, `getWindowState()`
///
/// Event channel `com.mirrorcast/events`: see `EventEmitter`.
///
/// No video or audio bytes ever cross this bridge; frames reach Flutter as a
/// GPU texture.
public final class MirrorcastEnginePlugin: NSObject, FlutterPlugin {
    private let controller: ReceiverController
    private let emitter: EventEmitter

    private init(controller: ReceiverController, emitter: EventEmitter) {
        self.controller = controller
        self.emitter = emitter
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let emitter = EventEmitter()
        let instance = MirrorcastEnginePlugin(
            controller: ReceiverController(registrar: registrar, emitter: emitter),
            emitter: emitter
        )
        let control = FlutterMethodChannel(name: "com.mirrorcast/control", binaryMessenger: registrar.messenger)
        registrar.addMethodCallDelegate(instance, channel: control)
        let events = FlutterEventChannel(name: "com.mirrorcast/events", binaryMessenger: registrar.messenger)
        events.setStreamHandler(emitter)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "initReceiver":
            controller.initialize { outcome in
                switch outcome {
                case .success(let info):
                    result(info)
                case .failure(let error):
                    result(FlutterError(code: "init_failed", message: error.localizedDescription, details: nil))
                }
            }
        case "disposeReceiver":
            controller.dispose()
            result(nil)
        case "openPairing":
            controller.openPairing { result($0) }
        case "closePairing":
            controller.closePairing()
            result(nil)
        case "listTrustedDevices":
            controller.trustedDevices { result($0) }
        case "revokeDevice":
            guard let fingerprint = args["fingerprint"] as? String, Fingerprint.parse(fingerprint) != nil else {
                return result(FlutterError(code: "invalid_args", message: "A valid fingerprint is required", details: nil))
            }
            controller.revoke(fingerprint.lowercased()) { result($0) }
        case "disconnect":
            controller.disconnect()
            result(nil)
        case "setAudioMuted":
            controller.setAudioMuted(args["muted"] as? Bool ?? false)
            result(nil)
        case "setAlwaysOnTop":
            controller.windows.setAlwaysOnTop(args["enabled"] as? Bool ?? false)
            result(nil)
        case "toggleFullScreen":
            controller.windows.toggleFullScreen()
            result(nil)
        case "setMiniPlayer":
            controller.windows.setMiniPlayer(args["enabled"] as? Bool ?? false)
            result(nil)
        case "getWindowState":
            result(controller.windows.stateMap)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
