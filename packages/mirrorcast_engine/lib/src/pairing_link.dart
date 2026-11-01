import 'dart:convert';
import 'dart:typed_data';

/// The contents of the QR code the Mac shows while pairing.
///
/// Format (a URI, so any QR scanner shows something readable):
///
/// ```text
/// mirrorcast://pair?v=1&n=<receiver name>&fp=<64 hex>&s=<base64url secret>
///                  &p=<port>&a=<address>,<address>
/// ```
///
/// * `fp` lets the phone pin the Mac's certificate *before* connecting, so
///   QR pairing is safe even on an untrusted network.
/// * `s` is a single-use 128-bit secret that proves the phone saw this screen.
class PairingLink {
  const PairingLink({
    required this.receiverName,
    required this.fingerprint,
    required this.secret,
    required this.port,
    required this.addresses,
  });

  static const scheme = 'mirrorcast';
  static const version = '1';

  final String receiverName;
  final String fingerprint;
  final Uint8List secret;
  final int port;
  final List<String> addresses;

  String toUri() {
    final uri = Uri(
      scheme: scheme,
      host: 'pair',
      queryParameters: {
        'v': version,
        'n': receiverName,
        'fp': fingerprint,
        's': base64Url.encode(secret).replaceAll('=', ''),
        'p': '$port',
        'a': addresses.join(','),
      },
    );
    return uri.toString();
  }

  /// Parses and validates a scanned QR code. Returns null for anything that
  /// isn't a well-formed MirrorCast pairing link.
  static PairingLink? tryParse(String raw) {
    final Uri uri;
    try {
      uri = Uri.parse(raw.trim());
    } on FormatException {
      return null;
    }
    if (uri.scheme != scheme || uri.host != 'pair') return null;
    final query = uri.queryParameters;
    if (query['v'] != version) return null;

    final fingerprint = (query['fp'] ?? '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) return null;

    final port = int.tryParse(query['p'] ?? '');
    if (port == null || port < 1 || port > 65535) return null;

    final Uint8List secret;
    try {
      secret = base64Url.decode(base64Url.normalize(query['s'] ?? ''));
    } on FormatException {
      return null;
    }
    if (secret.length < 16) return null;

    final addresses = (query['a'] ?? '').split(',').map((a) => a.trim()).where(_looksLikeAddress).take(8).toList();
    if (addresses.isEmpty) return null;

    final name = (query['n'] ?? 'Mac').trim();
    return PairingLink(
      receiverName: name.isEmpty ? 'Mac' : name.substring(0, name.length.clamp(0, 64)),
      fingerprint: fingerprint,
      secret: secret,
      port: port,
      addresses: addresses,
    );
  }

  static bool _looksLikeAddress(String value) =>
      value.isNotEmpty && value.length <= 64 && RegExp(r'^[0-9A-Za-z.:%\-]+$').hasMatch(value);
}
