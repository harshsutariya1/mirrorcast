/// Constants shared by both apps for discovery and connection.
abstract final class MirrorProtocol {
  /// Bonjour/mDNS service type the Mac advertises.
  static const serviceType = '_mirrorcast._tcp';

  /// Default TCP port of the Mac's TLS server. (Port 5000 is taken by
  /// AirPlay Receiver on macOS 12+, so MirrorCast uses its own.)
  static const defaultPort = 47474;

  /// TXT record keys in the Bonjour advertisement.
  static const txtFingerprint = 'fp';
  static const txtVersion = 'v';
  static const protocolVersion = '1';

  /// Loopback address used for USB mode (`adb reverse`).
  static const usbHost = '127.0.0.1';

  static String adbReverseCommand(int port) => 'adb reverse tcp:$port tcp:$port';
}
