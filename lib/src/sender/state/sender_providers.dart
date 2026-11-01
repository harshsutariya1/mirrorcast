import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mirrorcast_engine/mirrorcast_engine.dart';

import '../../shared/preferences.dart';
import '../data/discovery.dart';
import '../data/sender_settings.dart';
import '../data/trusted_mac.dart';

final senderEngineProvider = Provider<SenderEngine>((ref) => SenderEngine());

/// This phone's name, model, fingerprint and codec support.
final deviceInfoProvider = FutureProvider<SenderDeviceInfo>((ref) => ref.watch(senderEngineProvider).deviceInfo());

// ---------------------------------------------------------------- settings

final senderSettingsProvider = NotifierProvider<SenderSettingsNotifier, SenderSettings>(SenderSettingsNotifier.new);

class SenderSettingsNotifier extends Notifier<SenderSettings> {
  static const _key = 'sender_settings_v1';

  @override
  SenderSettings build() {
    final raw = ref.watch(preferencesProvider).getString(_key);
    if (raw == null) return const SenderSettings();
    try {
      return SenderSettings.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    } on Object {
      return const SenderSettings();
    }
  }

  void change(SenderSettings Function(SenderSettings current) update) {
    state = update(state);
    unawaited(ref.read(preferencesProvider).setString(_key, jsonEncode(state.toJson())));
  }
}

// ------------------------------------------------------------ trusted Macs

final trustedMacsProvider = NotifierProvider<TrustedMacsNotifier, List<TrustedMac>>(TrustedMacsNotifier.new);

class TrustedMacsNotifier extends Notifier<List<TrustedMac>> {
  static const _key = 'trusted_macs_v1';

  @override
  List<TrustedMac> build() {
    final raw = ref.watch(preferencesProvider).getString(_key);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map(TrustedMac.tryFromJson).whereType<TrustedMac>().toList();
    } on Object {
      return const [];
    }
  }

  TrustedMac? byFingerprint(String? fingerprint) {
    if (fingerprint == null) return null;
    for (final mac in state) {
      if (mac.fingerprint == fingerprint) return mac;
    }
    return null;
  }

  void addPaired(PairedReceiver paired) {
    final existing = byFingerprint(paired.fingerprint);
    final mac =
        existing?.copyWith(name: paired.receiverName, lastHost: paired.host, port: paired.port) ??
        TrustedMac(
          fingerprint: paired.fingerprint,
          name: paired.receiverName,
          lastHost: paired.host,
          port: paired.port,
          pairedAt: DateTime.now(),
        );
    _save([mac, ...state.where((m) => m.fingerprint != paired.fingerprint)]);
  }

  void markConnected(String fingerprint, {String? host, int? port}) {
    _save([
      for (final mac in state)
        if (mac.fingerprint == fingerprint)
          mac.copyWith(lastHost: host, port: port, lastConnectedAt: DateTime.now())
        else
          mac,
    ]);
  }

  void forget(String fingerprint) => _save(state.where((m) => m.fingerprint != fingerprint).toList());

  void _save(List<TrustedMac> macs) {
    state = macs;
    unawaited(ref.read(preferencesProvider).setString(_key, jsonEncode(macs.map((m) => m.toJson()).toList())));
  }
}

// --------------------------------------------------------------- discovery

final discoveryProvider = NotifierProvider<DiscoveryNotifier, Map<String, DiscoveredMac>>(DiscoveryNotifier.new);

/// Macs currently advertising on the network. Runs while the home screen is visible.
class DiscoveryNotifier extends Notifier<Map<String, DiscoveredMac>> {
  MacDiscovery? _discovery;

  @override
  Map<String, DiscoveredMac> build() {
    final discovery = MacDiscovery(
      onChanged: (macs) {
        if (ref.mounted) state = macs;
      },
    );
    _discovery = discovery;
    ref.onDispose(() => unawaited(discovery.stop()));
    unawaited(_start(discovery));
    return const {};
  }

  Future<void> _start(MacDiscovery discovery) async {
    try {
      await discovery.start();
    } on Object {
      // Discovery is a convenience; manual and USB connections still work.
    }
  }

  Future<void> refresh() async {
    final discovery = _discovery;
    if (discovery == null) return;
    state = const {};
    await _start(discovery);
  }
}

/// Discovered Macs split into "paired" and "new".
typedef NearbyMacs = ({Map<String, DiscoveredMac> paired, List<DiscoveredMac> unpaired});

final nearbyMacsProvider = Provider<NearbyMacs>((ref) {
  final discovered = ref.watch(discoveryProvider);
  final trusted = {for (final mac in ref.watch(trustedMacsProvider)) mac.fingerprint};
  final paired = <String, DiscoveredMac>{};
  final unpaired = <DiscoveredMac>[];
  for (final mac in discovered.values) {
    final fingerprint = mac.fingerprint;
    if (fingerprint != null && trusted.contains(fingerprint)) {
      paired[fingerprint] = mac;
    } else {
      unpaired.add(mac);
    }
  }
  unpaired.sort((a, b) => a.serviceName.compareTo(b.serviceName));
  return (paired: paired, unpaired: unpaired);
});
