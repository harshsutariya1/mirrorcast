import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorcast/src/sender/data/sender_settings.dart';
import 'package:mirrorcast/src/sender/data/trusted_mac.dart';
import 'package:mirrorcast_engine/mirrorcast_engine.dart';

void main() {
  group('SenderSettings', () {
    test('defaults to Balanced, automatic codec, audio on the Mac', () {
      const settings = SenderSettings();
      expect(settings.preset, QualityPreset.balanced);
      expect(settings.codec, CodecPreference.auto);
      expect(settings.defaultAudioRoute, AudioRoute.mac);
      expect(settings.profile.maxSize, 1920);
      expect(settings.profile.fps, 60);
    });

    test('round-trips through JSON', () {
      const original = SenderSettings(
        preset: QualityPreset.custom,
        customMaxSize: 2560,
        customFps: 120,
        customBitrateMbps: 30,
        codec: CodecPreference.avc,
        defaultAudioRoute: AudioRoute.phone,
        mutePhoneSpeaker: false,
      );
      final copy = SenderSettings.fromJson(original.toJson());
      expect(copy.toJson(), original.toJson());
      expect(copy.profile.bitrate, 30000000);
    });

    test('falls back to defaults for corrupted values', () {
      final settings = SenderSettings.fromJson({
        'preset': 'turbo',
        'customMaxSize': 1234,
        'customFps': -1,
        'customBitrateMbps': 999,
        'mutePhoneSpeaker': 'yes',
      });
      const defaults = SenderSettings();
      expect(settings.preset, QualityPreset.balanced);
      expect(settings.customMaxSize, defaults.customMaxSize);
      expect(settings.customFps, defaults.customFps);
      expect(settings.customBitrateMbps, defaults.customBitrateMbps);
      expect(settings.mutePhoneSpeaker, defaults.mutePhoneSpeaker);
    });
  });

  group('TrustedMac', () {
    final valid = {
      'fingerprint': 'cd' * 32,
      'name': 'Studio',
      'lastHost': '192.168.1.2',
      'port': 47474,
      'pairedAt': 1700000000000,
    };

    test('round-trips through JSON', () {
      final mac = TrustedMac.tryFromJson(valid)!;
      expect(TrustedMac.tryFromJson(mac.toJson())!.toJson(), mac.toJson());
      expect(mac.lastConnectedAt, isNull);
    });

    test('rejects entries that could break pinning', () {
      expect(TrustedMac.tryFromJson({...valid, 'fingerprint': 'CD' * 32}), isNull, reason: 'must be lowercase hex');
      expect(TrustedMac.tryFromJson({...valid, 'fingerprint': 'cd'}), isNull);
      expect(TrustedMac.tryFromJson({...valid, 'port': 0}), isNull);
      expect(TrustedMac.tryFromJson('garbage'), isNull);
    });
  });
}
