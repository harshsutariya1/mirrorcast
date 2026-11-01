import CoreVideo
import FlutterMacOS
import Foundation

/// Hands decoded frames to Flutter's `Texture` widget.
///
/// The decoder pushes the newest `CVPixelBuffer`; Flutter's raster thread
/// pulls it in `copyPixelBuffer()`. Only the latest frame is kept: if the
/// screen refreshes slower than frames arrive, older frames are skipped
/// rather than queued, which keeps latency at its minimum.
final class VideoTexture: NSObject, FlutterTexture {
    private struct State {
        var latest: CVPixelBuffer?
        var notifyPending = false
    }

    private let state = Locked(State())
    private weak var registry: FlutterTextureRegistry?
    private(set) var textureId: Int64 = -1

    init(registry: FlutterTextureRegistry) {
        self.registry = registry
        super.init()
        textureId = registry.register(self)
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        state.withLock { state -> Unmanaged<CVPixelBuffer>? in
            guard let buffer = state.latest else { return nil }
            return Unmanaged.passRetained(buffer)
        }
    }

    /// Called from the decoder thread for every new frame.
    func push(_ buffer: CVPixelBuffer) {
        let shouldNotify = state.withLock { state -> Bool in
            state.latest = buffer
            if state.notifyPending { return false }
            state.notifyPending = true
            return true
        }
        guard shouldNotify else { return } // a notification is already on its way
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state.withLock { $0.notifyPending = false }
            self.registry?.textureFrameAvailable(self.textureId)
        }
    }

    /// Drops the last frame (the widget shows its placeholder again).
    func clear() {
        state.withLock { $0.latest = nil }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.registry?.textureFrameAvailable(self.textureId)
        }
    }

    func unregister() {
        let id = textureId
        let registry = self.registry
        DispatchQueue.main.async { registry?.unregisterTexture(id) }
        textureId = -1
    }
}
