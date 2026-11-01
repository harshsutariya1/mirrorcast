import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import '../../shared/protocol.dart';

/// A Mac found on the local network via Bonjour.
class DiscoveredMac {
  const DiscoveredMac({required this.serviceName, required this.fingerprint, required this.hosts, required this.port});

  /// The Mac's computer name (Bonjour service name).
  final String serviceName;

  /// Certificate fingerprint advertised in the TXT record. Only a hint for
  /// matching against paired Macs: TLS pinning does the real verification.
  final String? fingerprint;

  /// Resolved addresses, IPv4 first.
  final List<String> hosts;
  final int port;

  bool get isResolved => hosts.isNotEmpty && port > 0;
}

/// Thin wrapper around a Bonsoir discovery for `_mirrorcast._tcp`.
class MacDiscovery {
  MacDiscovery({required this.onChanged});

  final void Function(Map<String, DiscoveredMac> macs) onChanged;
  final Map<String, DiscoveredMac> _macs = {};
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _subscription;

  Future<void> start() async {
    await stop();
    final discovery = BonsoirDiscovery(type: MirrorProtocol.serviceType);
    _discovery = discovery;
    await discovery.initialize();
    _subscription = discovery.eventStream?.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          _upsert(event.service);
          unawaited(event.service.resolve(discovery.serviceResolver));
        case BonsoirDiscoveryServiceResolvedEvent():
          _upsert(event.service);
        case BonsoirDiscoveryServiceUpdatedEvent():
          _upsert(event.service);
        case BonsoirDiscoveryServiceLostEvent():
          if (_macs.remove(event.service.name) != null) onChanged(Map.unmodifiable(_macs));
        default:
          break;
      }
    });
    await discovery.start();
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null && !discovery.isStopped) {
      try {
        await discovery.stop();
      } on Exception {
        // Already stopped by the platform; nothing to clean up.
      }
    }
    _macs.clear();
  }

  void _upsert(BonsoirService service) {
    if (service.attributes[MirrorProtocol.txtVersion] case final v? when v != MirrorProtocol.protocolVersion) {
      return; // a future, incompatible MirrorCast version
    }
    final fingerprint = service.attributes[MirrorProtocol.txtFingerprint]?.toLowerCase();
    final previous = _macs[service.name];
    final hosts = _sortHosts(service.hostAddresses);
    _macs[service.name] = DiscoveredMac(
      serviceName: service.name,
      fingerprint: fingerprint != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)
          ? fingerprint
          : previous?.fingerprint,
      hosts: hosts.isNotEmpty ? hosts : (previous?.hosts ?? const []),
      port: service.port > 0 ? service.port : (previous?.port ?? 0),
    );
    onChanged(Map.unmodifiable(_macs));
  }

  /// IPv4 first (most reliable on home routers), then global IPv6, then link-local.
  static List<String> _sortHosts(List<String> addresses) {
    int rank(String address) {
      final parsed = InternetAddress.tryParse(address.split('%').first);
      if (parsed == null) return 3;
      if (parsed.type == InternetAddressType.IPv4) return 0;
      return parsed.isLinkLocal ? 2 : 1;
    }

    final unique = addresses.toSet().toList()..sort((a, b) => rank(a).compareTo(rank(b)));
    return unique;
  }
}
