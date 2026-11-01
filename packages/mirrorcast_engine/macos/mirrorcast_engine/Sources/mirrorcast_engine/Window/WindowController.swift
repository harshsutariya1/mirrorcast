import AppKit
import Foundation

/// Window modes for the viewer: always-on-top, full screen and a compact
/// "mini player" (a small floating window in the corner, like Picture in
/// Picture). Main thread only.
final class WindowController {
    private weak var view: NSView?
    private var savedFrame: NSRect?
    private var observers: [NSObjectProtocol] = []

    private(set) var alwaysOnTop = false
    private(set) var isMiniPlayer = false
    private var contentAspect = NSSize(width: 16, height: 9)

    /// Called whenever a window mode changes.
    var onChange: (([String: Any]) -> Void)?

    init(view: NSView?) {
        self.view = view
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private var window: NSWindow? {
        view?.window ?? NSApp.mainWindow ?? NSApp.windows.first
    }

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    var stateMap: [String: Any] {
        ["type": "window", "alwaysOnTop": alwaysOnTop, "miniPlayer": isMiniPlayer, "fullScreen": isFullScreen]
    }

    /// Starts listening for full-screen changes (the user can also use the green button).
    func observe() {
        guard observers.isEmpty, let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.notify()
            })
        }
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        alwaysOnTop = enabled
        applyLevel()
        notify()
    }

    func toggleFullScreen() {
        guard let window else { return }
        if isMiniPlayer { setMiniPlayer(false) }
        window.toggleFullScreen(nil)
    }

    /// Remembers the stream's aspect ratio so the mini player has no black bars.
    func setContentAspect(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        contentAspect = NSSize(width: width, height: height)
        guard isMiniPlayer, let window else { return }
        window.contentAspectRatio = contentAspect
        var frame = window.frame
        let contentWidth = window.contentRect(forFrameRect: frame).width
        let contentHeight = contentWidth * contentAspect.height / contentAspect.width
        frame.size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)).size
        window.setFrame(frame, display: true, animate: true)
    }

    func setMiniPlayer(_ enabled: Bool) {
        guard let window, enabled != isMiniPlayer else { return }
        if enabled && isFullScreen {
            // Leaving full screen animates; switch to the mini player afterwards.
            window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.setMiniPlayer(true) }
            return
        }

        if enabled {
            savedFrame = window.frame
            isMiniPlayer = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.contentAspectRatio = contentAspect

            let landscape = contentAspect.width >= contentAspect.height
            let width: CGFloat = landscape ? 480 : 260
            let height = width * contentAspect.height / contentAspect.width
            let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let content = NSRect(x: screen.maxX - width - 24, y: screen.minY + 24, width: width, height: height)
            window.setFrame(window.frameRect(forContentRect: content), display: true, animate: true)
        } else {
            isMiniPlayer = false
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false
            window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.contentResizeIncrements = NSSize(width: 1, height: 1) // clears the aspect lock
            if let savedFrame { window.setFrame(savedFrame, display: true, animate: true) }
        }
        applyLevel()
        notify()
    }

    private func applyLevel() {
        window?.level = (alwaysOnTop || isMiniPlayer) ? .floating : .normal
    }

    private func notify() {
        onChange?(stateMap)
    }
}
