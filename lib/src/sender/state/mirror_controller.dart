import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mirrorcast_engine/mirrorcast_engine.dart';

import '../../shared/protocol.dart';
import 'sender_providers.dart';

/// Where to mirror to.
class MirrorTarget {
  /// USB mode: `adb reverse` forwards the phone's localhost to the Mac.
  factory MirrorTarget.usb({required int port, required List<String> fingerprints}) =>
      MirrorTarget(label: 'Mac (USB)', hosts: const [MirrorProtocol.usbHost], port: port, fingerprints: fingerprints);
  const MirrorTarget({required this.label, required this.hosts, required this.port, required this.fingerprints});

  final String label;
  final List<String> hosts;
  final int port;

  /// The Mac must present one of these identities (TLS pinning).
  final List<String> fingerprints;
}

/// Everything the UI needs to show about mirroring.
class MirrorState {
  const MirrorState({
    this.phase = SenderPhase.idle,
    this.requesting = false,
    this.receiverName,
    this.codec,
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.bitrate = 0,
    this.audioRoute = AudioRoute.mac,
    this.stats,
    this.error,
  });

  final SenderPhase phase;

  /// True while Android's permission / screen-capture dialogs are open.
  final bool requesting;
  final String? receiverName;
  final String? codec;
  final int width;
  final int height;
  final int fps;
  final int bitrate;
  final AudioRoute audioRoute;
  final SenderStatsEvent? stats;
  final EngineException? error;

  bool get isActive =>
      phase == SenderPhase.connecting || phase == SenderPhase.streaming || phase == SenderPhase.reconnecting;

  MirrorState copyWith({
    SenderPhase? phase,
    bool? requesting,
    String? receiverName,
    String? codec,
    int? width,
    int? height,
    int? fps,
    int? bitrate,
    AudioRoute? audioRoute,
    SenderStatsEvent? stats,
    EngineException? error,
    bool clearError = false,
    bool clearStats = false,
  }) => MirrorState(
    phase: phase ?? this.phase,
    requesting: requesting ?? this.requesting,
    receiverName: receiverName ?? this.receiverName,
    codec: codec ?? this.codec,
    width: width ?? this.width,
    height: height ?? this.height,
    fps: fps ?? this.fps,
    bitrate: bitrate ?? this.bitrate,
    audioRoute: audioRoute ?? this.audioRoute,
    stats: clearStats ? null : (stats ?? this.stats),
    error: clearError ? null : (error ?? this.error),
  );
}

final mirrorControllerProvider = NotifierProvider<MirrorController, MirrorState>(MirrorController.new);

/// Starts/stops mirroring and mirrors the engine's events into [MirrorState].
class MirrorController extends Notifier<MirrorState> {
  String? _targetFingerprint;
  final _warnings = StreamController<String>.broadcast();

  /// One-off messages (for example "audio capture unavailable") for a snackbar.
  Stream<String> get warnings => _warnings.stream;

  @override
  MirrorState build() {
    final subscription = ref.watch(senderEngineProvider).events.listen(_onEvent);
    ref.onDispose(() {
      unawaited(subscription.cancel());
      unawaited(_warnings.close());
    });
    return const MirrorState();
  }

  Future<void> start(MirrorTarget target) async {
    if (state.isActive || state.requesting) return;
    final settings = ref.read(senderSettingsProvider);
    final device = await ref.read(deviceInfoProvider.future);
    final profile = settings.profile;
    _targetFingerprint = target.fingerprints.length == 1 ? target.fingerprints.single : null;

    state = MirrorState(requesting: true, receiverName: target.label, audioRoute: settings.defaultAudioRoute);
    try {
      await ref
          .read(senderEngineProvider)
          .startMirroring(
            MirrorRequest(
              hosts: target.hosts,
              port: target.port,
              trustedFingerprints: target.fingerprints,
              maxSize: profile.maxSize,
              fps: profile.fps,
              bitrate: profile.bitrate,
              codec: settings.codec,
              audioRoute: settings.defaultAudioRoute,
              mutePhoneSpeaker: settings.mutePhoneSpeaker,
              deviceName: device.deviceName,
            ),
          );
      if (ref.mounted) state = state.copyWith(requesting: false);
    } on EngineException catch (error) {
      if (ref.mounted) state = MirrorState(phase: SenderPhase.error, error: error);
    }
  }

  Future<void> stop() => ref.read(senderEngineProvider).stopMirroring();

  Future<void> setAudioRoute(AudioRoute route) async {
    final mute = ref.read(senderSettingsProvider).mutePhoneSpeaker;
    state = state.copyWith(audioRoute: route); // optimistic; confirmed by the next state event
    await ref.read(senderEngineProvider).setAudioRoute(route, mutePhoneSpeaker: mute);
  }

  void dismissError() {
    if (state.phase == SenderPhase.error) state = const MirrorState();
  }

  void _onEvent(SenderEvent event) {
    switch (event) {
      case SenderStateEvent():
        _onState(event);
      case SenderStatsEvent():
        if (state.isActive) state = state.copyWith(stats: event);
      case SenderWarningEvent(:final message):
        _warnings.add(message);
    }
  }

  void _onState(SenderStateEvent event) {
    switch (event.phase) {
      case SenderPhase.idle:
        // Keep a visible error until the user dismisses it.
        if (state.phase != SenderPhase.error && !state.requesting) state = const MirrorState();
        if (event.reason == 'receiver_closed') _warnings.add('The Mac ended the session.');
      case SenderPhase.error:
        final code = event.errorCode ?? 'error';
        if (code == 'not_paired' || code == 'untrusted_receiver') {
          // The Mac revoked us (or its identity changed): forget it so the UI offers pairing.
          final fingerprint = _targetFingerprint;
          if (fingerprint != null) ref.read(trustedMacsProvider.notifier).forget(fingerprint);
        }
        state = MirrorState(
          phase: SenderPhase.error,
          error: EngineException(code, event.message ?? 'Mirroring stopped.'),
        );
      case SenderPhase.connecting:
        state = state.copyWith(phase: SenderPhase.connecting, requesting: false, clearError: true);
      case SenderPhase.reconnecting:
        state = state.copyWith(phase: SenderPhase.reconnecting);
      case SenderPhase.streaming:
        final fingerprint = _targetFingerprint;
        if (state.phase != SenderPhase.streaming && fingerprint != null) {
          ref.read(trustedMacsProvider.notifier).markConnected(fingerprint, host: event.host);
        }
        state = state.copyWith(
          phase: SenderPhase.streaming,
          requesting: false,
          receiverName: event.receiverName,
          codec: event.codec,
          width: event.width,
          height: event.height,
          fps: event.fps,
          bitrate: event.bitrate,
          audioRoute: event.audioRoute,
          clearError: true,
        );
    }
  }
}
