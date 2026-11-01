/// Small, pure formatting helpers (unit-tested in `test/format_test.dart`).
abstract final class Format {
  /// `a1b2c3...` -> `A1B2 C3D4 E5F6 7788` (first 16 hex digits, grouped).
  ///
  /// Enough to compare two devices by eye; the full value is always used
  /// for the actual security checks.
  static String shortFingerprint(String hex) {
    final clean = hex.replaceAll(RegExp('[^0-9a-fA-F]'), '').toUpperCase();
    final short = clean.length > 16 ? clean.substring(0, 16) : clean;
    final groups = <String>[];
    for (var i = 0; i < short.length; i += 4) {
      groups.add(short.substring(i, (i + 4).clamp(0, short.length)));
    }
    return groups.join(' ');
  }

  /// `482913` -> `482 913`.
  static String pin(String pin) => pin.length == 6 ? '${pin.substring(0, 3)} ${pin.substring(3)}' : pin;

  /// `12_000_000` -> `12 Mbps`, `2_500_000` -> `2.5 Mbps`.
  static String bitrate(int bitsPerSecond) {
    final mbps = bitsPerSecond / 1e6;
    return mbps == mbps.roundToDouble() ? '${mbps.toStringAsFixed(0)} Mbps' : '${mbps.toStringAsFixed(1)} Mbps';
  }

  /// Kilobits per second to a short label.
  static String kbps(double kbps) =>
      kbps >= 1000 ? '${(kbps / 1000).toStringAsFixed(1)} Mbps' : '${kbps.toStringAsFixed(0)} kbps';

  /// `0` -> `Native`, `1920` -> `1080p` style labels for a max-size value.
  static String resolution(int maxSize) => switch (maxSize) {
    0 => 'Native',
    1280 => '720p',
    1600 => '900p',
    1920 => '1080p',
    2560 => '1440p',
    _ => '${maxSize}px',
  };

  /// `65` seconds -> `1:05`, `3725` -> `1:02:05`.
  static String duration(Duration value) {
    final h = value.inHours;
    final m = value.inMinutes.remainder(60);
    final s = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }

  static String codec(String? codec) => switch (codec) {
    'hevc' => 'H.265',
    'avc' => 'H.264',
    _ => '—',
  };

  static String relative(DateTime? time, {DateTime? now}) {
    if (time == null) return 'Never';
    final diff = (now ?? DateTime.now()).difference(time);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    if (diff.inDays < 30) return '${diff.inDays} d ago';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }
}
