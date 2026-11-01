import Cocoa
import FlutterMacOS

/// The main window. All receiver logic lives in the `mirrorcast_engine`
/// plugin (packages/mirrorcast_engine/macos), registered below.
class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // A comfortable default size, centred on first launch; macOS remembers
    // the user's size and position afterwards.
    self.title = "MirrorCast"
    self.setContentSize(NSSize(width: 1100, height: 720))
    self.contentMinSize = NSSize(width: 240, height: 240)
    self.center()
    self.setFrameAutosaveName("MirrorCastMainWindow")
    self.tabbingMode = .disallowed
    // A black backdrop avoids a white flash behind the video while resizing.
    self.backgroundColor = .black

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
