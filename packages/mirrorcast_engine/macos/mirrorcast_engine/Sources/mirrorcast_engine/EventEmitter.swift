import FlutterMacOS
import Foundation

/// The one-way pipe from native code to Dart (`com.mirrorcast/events`).
///
/// `emit` can be called from any thread; events are delivered on the main
/// thread. The latest event of each "sticky" type is replayed when Dart starts
/// listening, so the UI is always in sync (for example after a hot restart).
final class EventEmitter: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    private var sticky: [String: [String: Any]] = [:]
    private static let stickyTypes: Set<String> = ["server", "session", "video", "audio", "window"]

    func emit(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let type = event["type"] as? String, Self.stickyTypes.contains(type) {
                self.sticky[type] = event
            }
            self.sink?(event)
        }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        for type in ["server", "session", "video", "audio", "window"] {
            if let event = sticky[type] { events(event) }
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}
