import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import '../../shared/protocol.dart';

/// Announces this Mac on the local network as `_mirrorcast._tcp` so phones
/// find it without typing an address.
///
/// The TXT record carries the certificate fingerprint so a phone can tell
/// which of its paired Macs this is. It's only a hint: the phone still pins
/// the fingerprint during the TLS handshake.
class ReceiverAdvertiser {
  BonsoirBroadcast? _broadcast;

  Future<void> start({required String name, required int port, required String fingerprint}) async {
    await stop();
    final service = BonsoirService(
      name: name,
      type: MirrorProtocol.serviceType,
      port: port,
      attributes: {
        MirrorProtocol.txtVersion: MirrorProtocol.protocolVersion,
        MirrorProtocol.txtFingerprint: fingerprint,
      },
    );
    final broadcast = BonsoirBroadcast(service: service);
    await broadcast.initialize();
    await broadcast.start();
    _broadcast = broadcast;
  }

  Future<void> stop() async {
    final broadcast = _broadcast;
    _broadcast = null;
    if (broadcast != null && !broadcast.isStopped) {
      try {
        await broadcast.stop();
      } on Exception {
        // Already gone.
      }
    }
  }
}

/// This Mac's IPv4 addresses, for the "Connection details" card and the QR code.
abstract final class NetworkAddresses {
  static Future<List<String>> current() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      // en0 is usually Wi-Fi on Macs; list it first.
      interfaces.sort((a, b) => _rank(a.name).compareTo(_rank(b.name)));
      return [
        for (final interface in interfaces)
          for (final address in interface.addresses)
            if (!address.isLoopback && !address.isLinkLocal) address.address,
      ];
    } on SocketException {
      return const [];
    }
  }

  static int _rank(String name) => switch (name) {
    'en0' => 0,
    'en1' => 1,
    _ when name.startsWith('en') => 2,
    _ when name.startsWith('bridge') => 3,
    _ => 4,
  };
}
