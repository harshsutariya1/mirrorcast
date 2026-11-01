/// A Mac this phone has paired with.
///
/// Only public data is kept: the Mac's name, its certificate fingerprint
/// (used to pin TLS connections) and where we last reached it.
class TrustedMac {
  const TrustedMac({
    required this.fingerprint,
    required this.name,
    required this.lastHost,
    required this.port,
    required this.pairedAt,
    this.lastConnectedAt,
  });

  final String fingerprint;
  final String name;
  final String lastHost;
  final int port;
  final DateTime pairedAt;
  final DateTime? lastConnectedAt;

  TrustedMac copyWith({String? name, String? lastHost, int? port, DateTime? lastConnectedAt}) => TrustedMac(
    fingerprint: fingerprint,
    name: name ?? this.name,
    lastHost: lastHost ?? this.lastHost,
    port: port ?? this.port,
    pairedAt: pairedAt,
    lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
  );

  Map<String, Object?> toJson() => {
    'fingerprint': fingerprint,
    'name': name,
    'lastHost': lastHost,
    'port': port,
    'pairedAt': pairedAt.millisecondsSinceEpoch,
    'lastConnectedAt': lastConnectedAt?.millisecondsSinceEpoch,
  };

  /// Returns null for entries that don't look valid (corrupted storage).
  static TrustedMac? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final fingerprint = json['fingerprint'];
    final port = json['port'];
    if (fingerprint is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) return null;
    if (port is! int || port < 1 || port > 65535) return null;
    final paired = json['pairedAt'];
    final connected = json['lastConnectedAt'];
    return TrustedMac(
      fingerprint: fingerprint,
      name: json['name'] is String ? json['name'] as String : 'Mac',
      lastHost: json['lastHost'] is String ? json['lastHost'] as String : '',
      port: port,
      pairedAt: DateTime.fromMillisecondsSinceEpoch(paired is int ? paired : 0),
      lastConnectedAt: connected is int ? DateTime.fromMillisecondsSinceEpoch(connected) : null,
    );
  }
}
