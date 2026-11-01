import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorcast_engine/mirrorcast_engine.dart';

void main() {
  final fingerprint = 'ab' * 32;
  final secret = Uint8List.fromList(List.generate(16, (i) => i * 7));

  PairingLink link({List<String> addresses = const ['192.168.1.20', '10.0.0.5']}) => PairingLink(
    receiverName: "Harsh's MacBook Pro",
    fingerprint: fingerprint,
    secret: secret,
    port: 47474,
    addresses: addresses,
  );

  group('PairingLink', () {
    test('round-trips through its URI', () {
      final parsed = PairingLink.tryParse(link().toUri());
      expect(parsed, isNotNull);
      expect(parsed!.receiverName, "Harsh's MacBook Pro");
      expect(parsed.fingerprint, fingerprint);
      expect(parsed.secret, secret);
      expect(parsed.port, 47474);
      expect(parsed.addresses, ['192.168.1.20', '10.0.0.5']);
    });

    test('encodes the secret as unpadded base64url', () {
      final uri = Uri.parse(link().toUri());
      expect(uri.queryParameters['s'], isNot(contains('=')));
    });

    test('rejects other schemes and versions', () {
      expect(PairingLink.tryParse('https://example.com'), isNull);
      expect(PairingLink.tryParse(link().toUri().replaceFirst('v=1', 'v=2')), isNull);
      expect(PairingLink.tryParse('not a uri at all ::::'), isNull);
    });

    test('rejects a bad fingerprint, port or secret', () {
      final good = Uri.parse(link().toUri());
      String withParam(String key, String value) =>
          good.replace(queryParameters: {...good.queryParameters, key: value}).toString();

      expect(PairingLink.tryParse(withParam('fp', 'zz' * 32)), isNull);
      expect(PairingLink.tryParse(withParam('fp', 'ab' * 31)), isNull);
      expect(PairingLink.tryParse(withParam('p', '0')), isNull);
      expect(PairingLink.tryParse(withParam('p', '70000')), isNull);
      expect(PairingLink.tryParse(withParam('s', 'AAAA')), isNull, reason: 'secret shorter than 16 bytes');
      expect(PairingLink.tryParse(withParam('s', '!!!')), isNull);
    });

    test('drops suspicious addresses and requires at least one', () {
      final parsed = PairingLink.tryParse(link(addresses: ['192.168.1.20', 'evil host/path']).toUri());
      expect(parsed!.addresses, ['192.168.1.20']);
      expect(PairingLink.tryParse(link(addresses: ['<script>']).toUri()), isNull);
    });

    test('accepts IPv6 addresses with a zone', () {
      final parsed = PairingLink.tryParse(link(addresses: ['fe80::1%en0']).toUri());
      expect(parsed!.addresses, ['fe80::1%en0']);
    });
  });
}
