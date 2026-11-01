import 'dart:async';

import 'channels.dart';
import 'pairing_link.dart';

/// Where the phone's audio plays while mirroring.
enum AudioRoute {
  /// Captured and streamed to the Mac's speakers.
  mac,

  /// Stays on the phone (its speaker, wired or Bluetooth headphones).
  phone;

  static AudioRoute parse(String? value) => value == 'phone' ? AudioRoute.phone : AudioRoute.mac;
}

/// Video codec preference.
enum CodecPreference {
  /// H.265 when both devices support it in hardware, otherwise H.264.
  auto,

  /// Always H.264 (maximum compatibility).
  avc,
}

/// Facts about this phone, reported by the Android engine.
class SenderDeviceInfo {
  const SenderDeviceInfo({
    required this.deviceName,
    required this.model,
    required this.sdkInt,
    required this.fingerprint,
    required this.hevcEncoder,
    required this.screenWidth,
    required this.screenHeight,
    required this.isMirroring,
  });

  factory SenderDeviceInfo.fromMap(Map<Object?, Object?> map) => SenderDeviceInfo(
    deviceName: map.str('deviceName', 'Android phone'),
    model: map.str('model'),
    sdkInt: map.integer('sdkInt'),
    fingerprint: map.str('fingerprint'),
    hevcEncoder: map.flag('hevcEncoder'),
    screenWidth: map.integer('screenWidth'),
    screenHeight: map.integer('screenHeight'),
    isMirroring: map.flag('isMirroring'),
  );

  final String deviceName;
  final String model;
  final int sdkInt;

  /// SHA-256 of this phone's certificate (the Mac shows it in its device list).
  final String fingerprint;
  final bool hevcEncoder;
  final int screenWidth;
  final int screenHeight;
  final bool isMirroring;
}

/// Result of a successful pairing.
class PairedReceiver {
  const PairedReceiver({required this.receiverName, required this.fingerprint, required this.host, required this.port});

  factory PairedReceiver.fromMap(Map<Object?, Object?> map) => PairedReceiver(
    receiverName: map.str('receiverName', 'Mac'),
    fingerprint: map.str('fingerprint'),
    host: map.str('host'),
    port: map.integer('port'),
  );

  final String receiverName;
  final String fingerprint;
  final String host;
  final int port;
}

/// Everything needed to start mirroring.
class MirrorRequest {
  const MirrorRequest({
    required this.hosts,
    required this.port,
    required this.trustedFingerprints,
    required this.maxSize,
    required this.fps,
    required this.bitrate,
    required this.codec,
    required this.audioRoute,
    required this.mutePhoneSpeaker,
    required this.deviceName,
  });

  /// Addresses to try in order (for example every address a Mac advertises).
  final List<String> hosts;
  final int port;

  /// The connection only succeeds if the Mac presents one of these identities.
  final List<String> trustedFingerprints;

  /// Longest video side in pixels; 0 keeps the native resolution.
  final int maxSize;
  final int fps;
  final int bitrate;
  final CodecPreference codec;
  final AudioRoute audioRoute;
  final bool mutePhoneSpeaker;
  final String deviceName;

  Map<String, Object?> toMap() => {
    'hosts': hosts,
    'port': port,
    'trustedFingerprints': trustedFingerprints,
    'maxSize': maxSize,
    'fps': fps,
    'bitrate': bitrate,
    'codec': codec.name,
    'audioMode': audioRoute.name,
    'mutePhoneSpeaker': mutePhoneSpeaker,
    'deviceName': deviceName,
  };
}

/// Lifecycle of a mirroring session on the phone.
enum SenderPhase { idle, connecting, streaming, reconnecting, error }

/// Something the Android engine reported.
sealed class SenderEvent {
  const SenderEvent();

  static SenderEvent? fromMap(Map<Object?, Object?> map) => switch (map['type']) {
    'state' => SenderStateEvent.fromMap(map),
    'stats' => SenderStatsEvent.fromMap(map),
    'warning' => SenderWarningEvent(map.str('code'), map.str('message')),
    _ => null,
  };
}

class SenderStateEvent extends SenderEvent {
  const SenderStateEvent({
    required this.phase,
    this.receiverName,
    this.host,
    this.codec,
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.bitrate = 0,
    this.audioRoute = AudioRoute.phone,
    this.errorCode,
    this.message,
    this.reason,
  });

  factory SenderStateEvent.fromMap(Map<Object?, Object?> map) {
    final phase = switch (map['state']) {
      'connecting' => SenderPhase.connecting,
      'streaming' => SenderPhase.streaming,
      'reconnecting' => SenderPhase.reconnecting,
      'error' => SenderPhase.error,
      _ => SenderPhase.idle,
    };
    return SenderStateEvent(
      phase: phase,
      receiverName: map.strOrNull('receiverName'),
      host: map.strOrNull('host'),
      codec: map.strOrNull('codec'),
      width: map.integer('width'),
      height: map.integer('height'),
      fps: map.integer('fps'),
      bitrate: map.integer('bitrate'),
      audioRoute: AudioRoute.parse(map.strOrNull('audioMode')),
      errorCode: map.strOrNull('code'),
      message: map.strOrNull('message'),
      reason: map.strOrNull('reason'),
    );
  }

  final SenderPhase phase;
  final String? receiverName;
  final String? host;
  final String? codec;
  final int width;
  final int height;
  final int fps;
  final int bitrate;
  final AudioRoute audioRoute;
  final String? errorCode;
  final String? message;

  /// Why the session ended ("stopped", "receiver_closed").
  final String? reason;
}

class SenderStatsEvent extends SenderEvent {
  const SenderStatsEvent({
    required this.sentFps,
    required this.bitrateKbps,
    required this.droppedFrames,
    required this.uptime,
    this.latencyMs,
    this.receiverFps,
    this.rttMs,
  });

  factory SenderStatsEvent.fromMap(Map<Object?, Object?> map) => SenderStatsEvent(
    sentFps: map.decimal('sentFps') ?? 0,
    bitrateKbps: map.decimal('bitrateKbps') ?? 0,
    droppedFrames: map.integer('droppedFrames'),
    uptime: Duration(seconds: map.integer('uptimeSec')),
    latencyMs: map.decimal('latencyMs'),
    receiverFps: map.decimal('receiverFps'),
    rttMs: map.decimal('rttMs'),
  );

  final double sentFps;
  final double bitrateKbps;
  final int droppedFrames;
  final Duration uptime;

  /// Capture-to-decode latency measured by the Mac.
  final double? latencyMs;
  final double? receiverFps;
  final double? rttMs;
}

class SenderWarningEvent extends SenderEvent {
  const SenderWarningEvent(this.code, this.message);

  final String code;
  final String message;
}

/// Typed API over the Android engine. One instance is enough for the app.
class SenderEngine {
  SenderEngine();

  Stream<SenderEvent>? _events;

  /// Native events. The current state is replayed to every new listener.
  Stream<SenderEvent> get events => _events ??= EngineChannels.events
      .receiveBroadcastStream()
      .map((raw) => raw is Map ? SenderEvent.fromMap(raw) : null)
      .where((event) => event != null)
      .cast<SenderEvent>();

  Future<SenderDeviceInfo> deviceInfo() => guardEngine(() async {
    final map = await EngineChannels.control.invokeMapMethod<Object?, Object?>('getDeviceInfo');
    return SenderDeviceInfo.fromMap(map ?? const {});
  });

  /// Pairs by typing the 6-digit code the Mac shows.
  Future<PairedReceiver> pairWithPin({
    required String host,
    required int port,
    required String pin,
    required String deviceName,
  }) => guardEngine(() async {
    final map = await EngineChannels.control.invokeMapMethod<Object?, Object?>('pairWithPin', {
      'host': host,
      'port': port,
      'pin': pin,
      'deviceName': deviceName,
    });
    return PairedReceiver.fromMap(map ?? const {});
  });

  /// Pairs using a scanned QR code.
  Future<PairedReceiver> pairWithQr(PairingLink link, {required String deviceName}) => guardEngine(() async {
    final map = await EngineChannels.control.invokeMapMethod<Object?, Object?>('pairWithQr', {
      'hosts': link.addresses,
      'port': link.port,
      'fingerprint': link.fingerprint,
      'secret': link.secret,
      'deviceName': deviceName,
    });
    return PairedReceiver.fromMap(map ?? const {});
  });

  /// Asks for the needed permissions and the screen-capture consent, then
  /// starts mirroring in a foreground service. Progress arrives on [events].
  Future<void> startMirroring(MirrorRequest request) =>
      guardEngine(() => EngineChannels.control.invokeMethod<void>('startMirroring', request.toMap()));

  Future<void> stopMirroring() => guardEngine(() => EngineChannels.control.invokeMethod<void>('stopMirroring'));

  /// Moves audio between the phone and the Mac while streaming.
  Future<void> setAudioRoute(AudioRoute route, {required bool mutePhoneSpeaker}) => guardEngine(
    () => EngineChannels.control.invokeMethod<void>('setAudioRouting', {
      'audioMode': route.name,
      'mutePhoneSpeaker': mutePhoneSpeaker,
    }),
  );
}
