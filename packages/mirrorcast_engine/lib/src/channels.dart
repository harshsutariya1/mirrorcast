import 'package:flutter/services.dart';

/// The two platform channels shared by Android and macOS.
///
/// * [control] carries commands from Dart to native code.
/// * [events] carries small status maps from native code to Dart.
///
/// Video frames and audio samples never travel over these channels.
abstract final class EngineChannels {
  static const MethodChannel control = MethodChannel('com.mirrorcast/control');
  static const EventChannel events = EventChannel('com.mirrorcast/events');
}

/// An error reported by the native engine, with a stable [code] the UI can
/// switch on and a human-readable [message].
class EngineException implements Exception {
  const EngineException(this.code, this.message);

  factory EngineException.fromPlatform(PlatformException error) =>
      EngineException(error.code, error.message ?? 'Something went wrong.');

  final String code;
  final String message;

  /// True when the fix is to pair the devices (again).
  bool get needsPairing => const {'not_paired', 'untrusted_receiver'}.contains(code);

  @override
  String toString() => 'EngineException($code): $message';
}

/// Runs [action], converting [PlatformException]s into [EngineException]s.
Future<T> guardEngine<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on PlatformException catch (error) {
    throw EngineException.fromPlatform(error);
  } on MissingPluginException {
    throw const EngineException('unsupported', 'This feature is not available on this platform.');
  }
}

/// Small typed readers for maps coming from native code.
extension NativeMap on Map<Object?, Object?> {
  String str(String key, [String fallback = '']) {
    final value = this[key];
    return value is String ? value : fallback;
  }

  String? strOrNull(String key) {
    final value = this[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  int integer(String key, [int fallback = 0]) {
    final value = this[key];
    return value is num ? value.toInt() : fallback;
  }

  double? decimal(String key) {
    final value = this[key];
    return value is num ? value.toDouble() : null;
  }

  bool flag(String key, [bool fallback = false]) {
    final value = this[key];
    return value is bool ? value : fallback;
  }
}
