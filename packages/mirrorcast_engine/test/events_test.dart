import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorcast_engine/mirrorcast_engine.dart';

void main() {
  group('SenderEvent.fromMap', () {
    test('parses a streaming state', () {
      final event = SenderEvent.fromMap({
        'type': 'state',
        'state': 'streaming',
        'receiverName': 'Studio Mac',
        'codec': 'hevc',
        'width': 1080,
        'height': 2400,
        'fps': 60,
        'audioMode': 'mac',
      });
      expect(event, isA<SenderStateEvent>());
      final state = event! as SenderStateEvent;
      expect(state.phase, SenderPhase.streaming);
      expect(state.receiverName, 'Studio Mac');
      expect(state.codec, 'hevc');
      expect(state.width, 1080);
      expect(state.audioRoute, AudioRoute.mac);
    });

    test('parses errors and unknown states safely', () {
      final error =
          SenderEvent.fromMap({'type': 'state', 'state': 'error', 'code': 'busy', 'message': 'Busy'})!
              as SenderStateEvent;
      expect(error.phase, SenderPhase.error);
      expect(error.errorCode, 'busy');
      final unknown = SenderEvent.fromMap({'type': 'state', 'state': 'from-the-future'});
      expect((unknown! as SenderStateEvent).phase, SenderPhase.idle);
      expect(SenderEvent.fromMap({'type': 'nope'}), isNull);
    });

    test('parses stats with missing optional values', () {
      final stats =
          SenderEvent.fromMap({'type': 'stats', 'sentFps': 59.5, 'bitrateKbps': 11800, 'uptimeSec': 65})!
              as SenderStatsEvent;
      expect(stats.sentFps, 59.5);
      expect(stats.latencyMs, isNull);
      expect(stats.uptime, const Duration(seconds: 65));
    });

    test('ignores values of the wrong type', () {
      final state =
          SenderEvent.fromMap({'type': 'state', 'state': 'streaming', 'width': 'wide', 'fps': null})!
              as SenderStateEvent;
      expect(state.width, 0);
      expect(state.fps, 0);
    });
  });

  group('ReceiverEvent.fromMap', () {
    test('parses session, video and stats events', () {
      final session = ReceiverEvent.fromMap({'type': 'session', 'state': 'streaming', 'deviceName': 'Pixel'});
      expect(session, isA<SessionEvent>());
      expect((session! as SessionEvent).deviceName, 'Pixel');

      final video =
          ReceiverEvent.fromMap({'type': 'video', 'active': true, 'codec': 'avc', 'width': 1920})! as VideoEvent;
      expect(video.active, isTrue);
      expect(video.width, 1920);

      final stats = ReceiverEvent.fromMap({'type': 'stats', 'fps': 60, 'latencyMs': 31.2})! as ReceiverStatsEvent;
      expect(stats.fps, 60);
      expect(stats.latencyMs, 31.2);
    });

    test('pairing events carry a credential only when a PIN is present', () {
      final open =
          ReceiverEvent.fromMap({
                'type': 'pairing',
                'state': 'open',
                'pin': '012345',
                'secret': 'AAAAAAAAAAAAAAAAAAAAAA',
                'expiresAt': 1700000000000,
                'fingerprint': 'ab' * 32,
                'port': 47474,
              })!
              as PairingEvent;
      expect(open.credential?.pin, '012345');
      final closed =
          ReceiverEvent.fromMap({'type': 'pairing', 'state': 'closed', 'reason': 'expired'})! as PairingEvent;
      expect(closed.credential, isNull);
      expect(closed.reason, 'expired');
    });
  });
}
