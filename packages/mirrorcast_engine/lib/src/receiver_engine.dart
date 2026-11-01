import 'dart:async';

import 'channels.dart';

/// Facts about the running receiver.
class ReceiverInfo {
  const ReceiverInfo({
    required this.textureId,
    required this.port,
    required this.fingerprint,
    required this.receiverName,
    required this.decoders,
  });

  factory ReceiverInfo.fromMap(Map<Object?, Object?> map) => ReceiverInfo(
    textureId: map.integer('textureId', -1),
    port: map.integer('port'),
    fingerprint: map.str('fingerprint'),
    receiverName: map.str('receiverName', 'Mac'),
    decoders: (map['decoders'] as List?)?.whereType<String>().toList() ?? const ['avc'],
  );

  /// Id of the Flutter texture that shows the phone's screen.
  final int textureId;
  final int port;

  /// SHA-256 of this Mac's certificate (what phones pin).
  final String fingerprint;
  final String receiverName;
  final List<String> decoders;
}

/// The current pairing code (PIN + QR secret).
class PairingCredential {
  const PairingCredential({
    required this.pin,
    required this.secret,
    required this.expiresAt,
    required this.fingerprint,
    required this.port,
    required this.receiverName,
  });

  factory PairingCredential.fromMap(Map<Object?, Object?> map) => PairingCredential(
    pin: map.str('pin'),
    secret: map.str('secret'),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(map.integer('expiresAt')),
    fingerprint: map.str('fingerprint'),
    port: map.integer('port'),
    receiverName: map.str('receiverName', 'Mac'),
  );

  final String pin;

  /// Base64url (no padding) single-use secret embedded in the QR code.
  final String secret;
  final DateTime expiresAt;
  final String fingerprint;
  final int port;
  final String receiverName;
}

/// A phone the Mac trusts.
class TrustedPhone {
  const TrustedPhone({
    required this.fingerprint,
    required this.name,
    required this.model,
    required this.pairedAt,
    this.lastSeenAt,
  });

  factory TrustedPhone.fromMap(Map<Object?, Object?> map) => TrustedPhone(
    fingerprint: map.str('fingerprint'),
    name: map.str('name', 'Phone'),
    model: map.str('model'),
    pairedAt: DateTime.fromMillisecondsSinceEpoch(map.integer('pairedAt')),
    lastSeenAt: map['lastSeenAt'] is num ? DateTime.fromMillisecondsSinceEpoch(map.integer('lastSeenAt')) : null,
  );

  final String fingerprint;
  final String name;
  final String model;
  final DateTime pairedAt;
  final DateTime? lastSeenAt;
}

/// Something the macOS engine reported.
sealed class ReceiverEvent {
  const ReceiverEvent();

  static ReceiverEvent? fromMap(Map<Object?, Object?> map) => switch (map['type']) {
    'server' => ServerEvent(
      listening: map['state'] == 'listening',
      port: map.integer('port'),
      message: map.strOrNull('message'),
    ),
    'session' => SessionEvent(
      state: map.str('state', 'idle'),
      deviceName: map.str('deviceName', 'Phone'),
      model: map.str('model'),
      fingerprint: map.str('fingerprint'),
      address: map.strOrNull('address'),
      reason: map.strOrNull('reason'),
    ),
    'video' => VideoEvent(
      active: map.flag('active'),
      codec: map.str('codec', 'avc'),
      width: map.integer('width'),
      height: map.integer('height'),
      fps: map.integer('fps'),
      bitrate: map.integer('bitrate'),
    ),
    'audio' => AudioEvent(enabled: map.flag('enabled'), muted: map.flag('muted')),
    'stats' => ReceiverStatsEvent(
      fps: map.decimal('fps') ?? 0,
      bitrateKbps: map.decimal('bitrateKbps') ?? 0,
      latencyMs: map.decimal('latencyMs'),
      rttMs: map.decimal('rttMs'),
      decodeErrors: map.integer('decodeErrors'),
      audioBufferMs: map.integer('audioBufferMs'),
      audioDropped: map.integer('audioDropped'),
    ),
    'pairing' => PairingEvent(
      state: map.str('state'),
      credential: map['pin'] is String ? PairingCredential.fromMap(map) : null,
      deviceName: map.strOrNull('deviceName'),
      reason: map.strOrNull('reason'),
    ),
    'window' => WindowEvent(
      alwaysOnTop: map.flag('alwaysOnTop'),
      miniPlayer: map.flag('miniPlayer'),
      fullScreen: map.flag('fullScreen'),
    ),
    'devices' => const DevicesChangedEvent(),
    _ => null,
  };
}

class ServerEvent extends ReceiverEvent {
  const ServerEvent({required this.listening, required this.port, this.message});
  final bool listening;
  final int port;
  final String? message;
}

class SessionEvent extends ReceiverEvent {
  const SessionEvent({
    required this.state,
    required this.deviceName,
    required this.model,
    required this.fingerprint,
    this.address,
    this.reason,
  });

  /// "streaming", "idle" or "rejected".
  final String state;
  final String deviceName;
  final String model;
  final String fingerprint;
  final String? address;
  final String? reason;
}

class VideoEvent extends ReceiverEvent {
  const VideoEvent({
    required this.active,
    required this.codec,
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrate,
  });
  final bool active;
  final String codec;
  final int width;
  final int height;
  final int fps;
  final int bitrate;
}

class AudioEvent extends ReceiverEvent {
  const AudioEvent({required this.enabled, required this.muted});
  final bool enabled;
  final bool muted;
}

class ReceiverStatsEvent extends ReceiverEvent {
  const ReceiverStatsEvent({
    required this.fps,
    required this.bitrateKbps,
    required this.decodeErrors,
    required this.audioBufferMs,
    required this.audioDropped,
    this.latencyMs,
    this.rttMs,
  });
  final double fps;
  final double bitrateKbps;
  final double? latencyMs;
  final double? rttMs;
  final int decodeErrors;
  final int audioBufferMs;
  final int audioDropped;
}

class PairingEvent extends ReceiverEvent {
  const PairingEvent({required this.state, this.credential, this.deviceName, this.reason});

  /// "open" (new code), "paired", "failed" or "closed".
  final String state;
  final PairingCredential? credential;
  final String? deviceName;
  final String? reason;
}

class WindowEvent extends ReceiverEvent {
  const WindowEvent({required this.alwaysOnTop, required this.miniPlayer, required this.fullScreen});
  final bool alwaysOnTop;
  final bool miniPlayer;
  final bool fullScreen;
}

class DevicesChangedEvent extends ReceiverEvent {
  const DevicesChangedEvent();
}

/// Typed API over the macOS engine.
class ReceiverEngine {
  ReceiverEngine();

  Stream<ReceiverEvent>? _events;

  Stream<ReceiverEvent> get events => _events ??= EngineChannels.events
      .receiveBroadcastStream()
      .map((raw) => raw is Map ? ReceiverEvent.fromMap(raw) : null)
      .where((event) => event != null)
      .cast<ReceiverEvent>();

  /// Creates the secure identity (first launch), the video texture, and
  /// starts the TLS server.
  Future<ReceiverInfo> initialize() => guardEngine(() async {
    final map = await EngineChannels.control.invokeMapMethod<Object?, Object?>('initReceiver');
    return ReceiverInfo.fromMap(map ?? const {});
  });

  Future<void> dispose() => guardEngine(() => EngineChannels.control.invokeMethod<void>('disposeReceiver'));

  Future<PairingCredential> openPairing() => guardEngine(() async {
    final map = await EngineChannels.control.invokeMapMethod<Object?, Object?>('openPairing');
    return PairingCredential.fromMap(map ?? const {});
  });

  Future<void> closePairing() => guardEngine(() => EngineChannels.control.invokeMethod<void>('closePairing'));

  Future<List<TrustedPhone>> trustedPhones() => guardEngine(() async {
    final list = await EngineChannels.control.invokeListMethod<Object?>('listTrustedDevices');
    return (list ?? const []).whereType<Map<Object?, Object?>>().map(TrustedPhone.fromMap).toList();
  });

  /// Removes a phone from the trusted list and disconnects it if connected.
  Future<bool> revoke(String fingerprint) => guardEngine(() async {
    final removed = await EngineChannels.control.invokeMethod<bool>('revokeDevice', {'fingerprint': fingerprint});
    return removed ?? false;
  });

  Future<void> disconnect() => guardEngine(() => EngineChannels.control.invokeMethod<void>('disconnect'));

  Future<void> setAudioMuted(bool muted) =>
      guardEngine(() => EngineChannels.control.invokeMethod<void>('setAudioMuted', {'muted': muted}));

  Future<void> setAlwaysOnTop(bool enabled) =>
      guardEngine(() => EngineChannels.control.invokeMethod<void>('setAlwaysOnTop', {'enabled': enabled}));

  Future<void> toggleFullScreen() => guardEngine(() => EngineChannels.control.invokeMethod<void>('toggleFullScreen'));

  Future<void> setMiniPlayer(bool enabled) =>
      guardEngine(() => EngineChannels.control.invokeMethod<void>('setMiniPlayer', {'enabled': enabled}));
}
