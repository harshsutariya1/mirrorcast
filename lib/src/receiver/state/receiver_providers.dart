import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mirrorcast_engine/mirrorcast_engine.dart';

import '../../shared/preferences.dart';
import '../data/advertiser.dart';

final receiverEngineProvider = Provider<ReceiverEngine>((ref) => ReceiverEngine());

enum ReceiverStatus { starting, ready, failed }

/// The phone currently mirroring.
class ActiveStream {
  const ActiveStream({required this.deviceName, required this.model, required this.fingerprint, this.address});

  final String deviceName;
  final String model;
  final String fingerprint;
  final String? address;
}

class ReceiverState {
  const ReceiverState({
    this.status = ReceiverStatus.starting,
    this.info,
    this.error,
    this.stream,
    this.video,
    this.audio = const AudioEvent(enabled: false, muted: false),
    this.stats,
    this.window = const WindowEvent(alwaysOnTop: false, miniPlayer: false, fullScreen: false),
    this.addresses = const [],
  });

  final ReceiverStatus status;
  final ReceiverInfo? info;
  final String? error;
  final ActiveStream? stream;
  final VideoEvent? video;
  final AudioEvent audio;
  final ReceiverStatsEvent? stats;
  final WindowEvent window;
  final List<String> addresses;

  bool get isStreaming => stream != null;

  ReceiverState copyWith({
    ReceiverStatus? status,
    ReceiverInfo? info,
    String? error,
    ActiveStream? stream,
    bool clearStream = false,
    VideoEvent? video,
    bool clearVideo = false,
    AudioEvent? audio,
    ReceiverStatsEvent? stats,
    bool clearStats = false,
    WindowEvent? window,
    List<String>? addresses,
  }) => ReceiverState(
    status: status ?? this.status,
    info: info ?? this.info,
    error: error ?? this.error,
    stream: clearStream ? null : (stream ?? this.stream),
    video: clearVideo ? null : (video ?? this.video),
    audio: audio ?? this.audio,
    stats: clearStats ? null : (stats ?? this.stats),
    window: window ?? this.window,
    addresses: addresses ?? this.addresses,
  );
}

final receiverControllerProvider = NotifierProvider<ReceiverController, ReceiverState>(ReceiverController.new);

/// Starts the engine, advertises the Mac on Bonjour and keeps [ReceiverState]
/// in sync with native events.
class ReceiverController extends Notifier<ReceiverState> {
  final _advertiser = ReceiverAdvertiser();
  final _notices = StreamController<String>.broadcast();
  Timer? _addressTimer;

  /// One-off messages for a snackbar ("An unpaired phone tried to connect").
  Stream<String> get notices => _notices.stream;

  ReceiverEngine get _engine => ref.read(receiverEngineProvider);

  @override
  ReceiverState build() {
    final subscription = ref.watch(receiverEngineProvider).events.listen(_onEvent);
    ref.onDispose(() {
      unawaited(subscription.cancel());
      _addressTimer?.cancel();
      unawaited(_advertiser.stop());
      unawaited(_notices.close());
    });
    unawaited(_start());
    return const ReceiverState();
  }

  Future<void> retry() async {
    state = state.copyWith(status: ReceiverStatus.starting);
    await _start();
  }

  Future<void> _start() async {
    try {
      final info = await _engine.initialize();
      final addresses = await NetworkAddresses.current();
      if (!ref.mounted) return;
      state = state.copyWith(status: ReceiverStatus.ready, info: info, addresses: addresses);
      _addressTimer?.cancel();
      _addressTimer = Timer.periodic(const Duration(seconds: 15), (_) => unawaited(_refreshAddresses()));
      try {
        await _advertiser.start(name: info.receiverName, port: info.port, fingerprint: info.fingerprint);
      } on Object {
        _notices.add('Bonjour advertising failed. Phones can still connect by address or USB.');
      }
    } on EngineException catch (error) {
      if (ref.mounted) state = state.copyWith(status: ReceiverStatus.failed, error: error.message);
    }
  }

  Future<void> _refreshAddresses() async {
    final addresses = await NetworkAddresses.current();
    if (ref.mounted && addresses.join(',') != state.addresses.join(',')) {
      state = state.copyWith(addresses: addresses);
    }
  }

  void _onEvent(ReceiverEvent event) {
    switch (event) {
      case SessionEvent(state: 'streaming'):
        state = state.copyWith(
          stream: ActiveStream(
            deviceName: event.deviceName,
            model: event.model,
            fingerprint: event.fingerprint,
            address: event.address,
          ),
          clearStats: true,
        );
      case SessionEvent(state: 'rejected', :final deviceName):
        _notices.add('"$deviceName" tried to connect but isn\'t paired.');
      case SessionEvent():
        if (state.stream != null) _notices.add('${state.stream!.deviceName} disconnected.');
        state = state.copyWith(clearStream: true, clearVideo: true, clearStats: true);
      case VideoEvent(active: true):
        state = state.copyWith(video: event);
      case VideoEvent():
        state = state.copyWith(clearVideo: true);
      case AudioEvent():
        state = state.copyWith(audio: event);
      case ReceiverStatsEvent():
        if (state.isStreaming) state = state.copyWith(stats: event);
      case WindowEvent():
        state = state.copyWith(window: event);
      case ServerEvent(listening: false, :final message):
        state = state.copyWith(status: ReceiverStatus.failed, error: message ?? 'The server stopped.');
      case ServerEvent() || PairingEvent() || DevicesChangedEvent():
        break;
    }
  }

  // Actions -------------------------------------------------------------

  Future<void> disconnect() => _engine.disconnect();

  Future<void> toggleMute() => _engine.setAudioMuted(!state.audio.muted);

  Future<void> toggleAlwaysOnTop() => _engine.setAlwaysOnTop(!state.window.alwaysOnTop);

  Future<void> toggleMiniPlayer() => _engine.setMiniPlayer(!state.window.miniPlayer);

  Future<void> toggleFullScreen() => _engine.toggleFullScreen();
}

// ------------------------------------------------------------------ pairing

enum PairingPhase { idle, open, paired, closed }

class PairingView {
  const PairingView({this.phase = PairingPhase.idle, this.credential, this.deviceName, this.message});

  final PairingPhase phase;
  final PairingCredential? credential;
  final String? deviceName;

  /// Feedback such as "That code didn't match".
  final String? message;
}

final pairingControllerProvider = NotifierProvider<PairingController, PairingView>(PairingController.new);

/// Drives the "Pair new phone" dialog.
class PairingController extends Notifier<PairingView> {
  ReceiverEngine get _engine => ref.read(receiverEngineProvider);

  @override
  PairingView build() {
    final subscription = ref
        .watch(receiverEngineProvider)
        .events
        .where((e) => e is PairingEvent)
        .cast<PairingEvent>()
        .listen(_onEvent);
    ref.onDispose(() => unawaited(subscription.cancel()));
    return const PairingView();
  }

  Future<void> open() async {
    state = const PairingView(phase: PairingPhase.open);
    try {
      final credential = await _engine.openPairing();
      if (ref.mounted && state.phase == PairingPhase.open) {
        state = PairingView(phase: PairingPhase.open, credential: credential);
      }
    } on EngineException catch (error) {
      if (ref.mounted) state = PairingView(phase: PairingPhase.closed, message: error.message);
    }
  }

  Future<void> close() async {
    final wasOpen = state.phase == PairingPhase.open;
    state = const PairingView();
    if (wasOpen) await _engine.closePairing();
  }

  void _onEvent(PairingEvent event) {
    if (state.phase == PairingPhase.idle) return; // dialog not visible
    switch (event.state) {
      case 'open':
        state = PairingView(phase: PairingPhase.open, credential: event.credential, message: state.message);
      case 'failed':
        final message = switch (event.reason) {
          'code_mismatch' => 'The code didn\'t match. Use the new code below.',
          'invalid_qr' => 'That QR code was out of date. Scan the new one.',
          'timeout' => 'Pairing took too long. Try again with the new code.',
          _ => 'Pairing failed. Try again with the new code.',
        };
        state = PairingView(phase: state.phase, credential: state.credential, message: message);
      case 'paired':
        state = PairingView(phase: PairingPhase.paired, deviceName: event.deviceName);
      case 'closed':
        if (event.reason == 'paired' || state.phase == PairingPhase.paired) return; // "paired" follows
        state = PairingView(
          phase: PairingPhase.closed,
          message: switch (event.reason) {
            'expired' => 'The code expired.',
            'too_many_attempts' => 'Too many wrong attempts. Pairing was stopped for safety.',
            _ => null,
          },
        );
    }
  }
}

// ------------------------------------------------------------ trusted phones

final trustedPhonesProvider = AsyncNotifierProvider<TrustedPhonesNotifier, List<TrustedPhone>>(
  TrustedPhonesNotifier.new,
);

class TrustedPhonesNotifier extends AsyncNotifier<List<TrustedPhone>> {
  @override
  Future<List<TrustedPhone>> build() async {
    final engine = ref.watch(receiverEngineProvider);
    final subscription = engine.events
        .where((e) => e is DevicesChangedEvent || (e is PairingEvent && e.state == 'paired'))
        .listen((_) => ref.invalidateSelf());
    ref.onDispose(() => unawaited(subscription.cancel()));
    // The engine must be initialized before it can answer; this rebuilds once it is.
    final ready = ref.watch(receiverControllerProvider.select((s) => s.status == ReceiverStatus.ready));
    if (!ready) return const [];
    return engine.trustedPhones();
  }

  Future<void> revoke(String fingerprint) async {
    await ref.read(receiverEngineProvider).revoke(fingerprint);
    ref.invalidateSelf();
  }
}

// --------------------------------------------------------------- preferences

final showStatsProvider = NotifierProvider<ShowStatsNotifier, bool>(ShowStatsNotifier.new);

/// Whether the stats overlay is visible (remembered between launches).
class ShowStatsNotifier extends Notifier<bool> {
  static const _key = 'receiver_show_stats';

  @override
  bool build() => ref.watch(preferencesProvider).getBool(_key) ?? false;

  void toggle() {
    state = !state;
    unawaited(ref.read(preferencesProvider).setBool(_key, state));
  }
}
