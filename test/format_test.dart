import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorcast/src/shared/format.dart';

void main() {
  test('shortFingerprint groups the first 16 hex digits', () {
    expect(Format.shortFingerprint('a1b2c3d4e5f60718${'0' * 48}'), 'A1B2 C3D4 E5F6 0718');
    expect(Format.shortFingerprint('ab:cd'), 'ABCD');
  });

  test('pin splits into two groups of three', () {
    expect(Format.pin('482913'), '482 913');
    expect(Format.pin('12'), '12');
  });

  test('bitrate and kbps are human friendly', () {
    expect(Format.bitrate(12000000), '12 Mbps');
    expect(Format.bitrate(2500000), '2.5 Mbps');
    expect(Format.kbps(850), '850 kbps');
    expect(Format.kbps(11800), '11.8 Mbps');
  });

  test('duration', () {
    expect(Format.duration(const Duration(seconds: 65)), '1:05');
    expect(Format.duration(const Duration(seconds: 3725)), '1:02:05');
  });

  test('relative time', () {
    final now = DateTime(2026, 1, 10, 12);
    expect(Format.relative(null), 'Never');
    expect(Format.relative(now.subtract(const Duration(seconds: 5)), now: now), 'Just now');
    expect(Format.relative(now.subtract(const Duration(minutes: 5)), now: now), '5 min ago');
    expect(Format.relative(now.subtract(const Duration(days: 2)), now: now), '2 d ago');
    expect(Format.relative(DateTime(2025, 3, 4), now: now), '2025-03-04');
  });

  test('codec and resolution labels', () {
    expect(Format.codec('hevc'), 'H.265');
    expect(Format.codec('avc'), 'H.264');
    expect(Format.codec(null), '—');
    expect(Format.resolution(0), 'Native');
    expect(Format.resolution(1920), '1080p');
  });
}
