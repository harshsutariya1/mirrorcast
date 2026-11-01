import 'package:mirrorcast_engine/mirrorcast_engine.dart';

/// Resolution / frame-rate / bitrate for the video stream.
class VideoProfile {
  const VideoProfile({required this.maxSize, required this.fps, required this.bitrate});

  /// Longest side in pixels; 0 = the phone's native resolution.
  final int maxSize;
  final int fps;

  /// Bits per second.
  final int bitrate;
}

/// One-tap quality choices. Each trades latency, sharpness and Wi-Fi load.
enum QualityPreset {
  lowLatency(
    'Ultra-low latency',
    'Best for games. 720p, 60 fps, 6 Mbps.',
    VideoProfile(maxSize: 1280, fps: 60, bitrate: 6000000),
  ),
  balanced(
    'Balanced',
    'Sharp and smooth for most things. 1080p, 60 fps, 12 Mbps.',
    VideoProfile(maxSize: 1920, fps: 60, bitrate: 12000000),
  ),
  quality(
    'Quality',
    'Native resolution for reading and video. Needs strong 5 GHz Wi-Fi.',
    VideoProfile(maxSize: 0, fps: 60, bitrate: 24000000),
  ),
  custom('Custom', 'Pick resolution, frame rate and bitrate yourself.', null);

  const QualityPreset(this.label, this.description, this.profile);

  final String label;
  final String description;
  final VideoProfile? profile;

  static QualityPreset parse(String? name) =>
      QualityPreset.values.firstWhere((p) => p.name == name, orElse: () => QualityPreset.balanced);
}

/// User preferences on the phone. Immutable; change with [copyWith].
class SenderSettings {
  /// Tolerant of missing or corrupted values: anything odd falls back to defaults.
  factory SenderSettings.fromJson(Map<String, Object?> json) {
    const defaults = SenderSettings();
    int pick(String key, List<int> allowed, int fallback) {
      final value = json[key];
      return value is int && allowed.contains(value) ? value : fallback;
    }

    final bitrate = json['customBitrateMbps'];
    return SenderSettings(
      preset: QualityPreset.parse(json['preset'] as String?),
      customMaxSize: pick('customMaxSize', maxSizeChoices, defaults.customMaxSize),
      customFps: pick('customFps', fpsChoices, defaults.customFps),
      customBitrateMbps: bitrate is int && bitrate >= minBitrateMbps && bitrate <= maxBitrateMbps
          ? bitrate
          : defaults.customBitrateMbps,
      codec: json['codec'] == 'avc' ? CodecPreference.avc : CodecPreference.auto,
      defaultAudioRoute: AudioRoute.parse(json['defaultAudioRoute'] as String?),
      mutePhoneSpeaker: json['mutePhoneSpeaker'] is bool
          ? json['mutePhoneSpeaker']! as bool
          : defaults.mutePhoneSpeaker,
    );
  }
  const SenderSettings({
    this.preset = QualityPreset.balanced,
    this.customMaxSize = 1920,
    this.customFps = 60,
    this.customBitrateMbps = 12,
    this.codec = CodecPreference.auto,
    this.defaultAudioRoute = AudioRoute.mac,
    this.mutePhoneSpeaker = true,
  });

  final QualityPreset preset;
  final int customMaxSize;
  final int customFps;
  final int customBitrateMbps;
  final CodecPreference codec;
  final AudioRoute defaultAudioRoute;
  final bool mutePhoneSpeaker;

  static const maxSizeChoices = [1280, 1600, 1920, 2560, 0];
  static const fpsChoices = [30, 60, 90, 120];
  static const minBitrateMbps = 2;
  static const maxBitrateMbps = 40;

  VideoProfile get profile =>
      preset.profile ?? VideoProfile(maxSize: customMaxSize, fps: customFps, bitrate: customBitrateMbps * 1000000);

  SenderSettings copyWith({
    QualityPreset? preset,
    int? customMaxSize,
    int? customFps,
    int? customBitrateMbps,
    CodecPreference? codec,
    AudioRoute? defaultAudioRoute,
    bool? mutePhoneSpeaker,
  }) => SenderSettings(
    preset: preset ?? this.preset,
    customMaxSize: customMaxSize ?? this.customMaxSize,
    customFps: customFps ?? this.customFps,
    customBitrateMbps: customBitrateMbps ?? this.customBitrateMbps,
    codec: codec ?? this.codec,
    defaultAudioRoute: defaultAudioRoute ?? this.defaultAudioRoute,
    mutePhoneSpeaker: mutePhoneSpeaker ?? this.mutePhoneSpeaker,
  );

  Map<String, Object> toJson() => {
    'preset': preset.name,
    'customMaxSize': customMaxSize,
    'customFps': customFps,
    'customBitrateMbps': customBitrateMbps,
    'codec': codec.name,
    'defaultAudioRoute': defaultAudioRoute.name,
    'mutePhoneSpeaker': mutePhoneSpeaker,
  };
}
