# MirrorCast

Ultra-low-latency, end-to-end encrypted **screen and audio mirroring from an
Android phone to a Mac**: one Flutter codebase, with native Kotlin and Swift doing the heavy lifting.

- 20–40 ms typical latency at 1080p60 on 5 GHz Wi-Fi; lower over USB
- Hardware H.265 / H.264 encoding and decoding
- Internal audio, switchable between Mac speakers and the phone or earbuds while streaming
- TLS 1.3 with mutual authentication, PIN or QR pairing, revocation on the Mac
- Wi-Fi (Bonjour), USB (`adb reverse`), manual IP and phone hotspot
- Live stats, quality presets, always-on-top, full screen and mini player on the Mac
- No accounts, no cloud, no data stored anywhere but your two devices

## Quick start

```bash
flutter pub get
```

```bash
flutter run -d macos
```

```bash
flutter run -d <android-device-id>
```

On the Mac click **Pair new phone**. On the phone, tap the Mac and enter the
code (or scan the QR code), then tap **Mirror**.

Requirements: Android 10+, macOS 13+ (Apple Silicon or Intel), **Flutter 3.47 or newer** (run `flutter upgrade`), Xcode, Android SDK.

## Documentation

- **[docs/GUIDE.md](docs/GUIDE.md)**: the complete guide. How to use it, how
  everything works, the security model, technology choices, troubleshooting.
- **[docs/PROTOCOL.md](docs/PROTOCOL.md)**: the exact wire protocol and pairing
  cryptography, with test vectors.
- [docs/original-spec.md](docs/original-spec.md): the starting specification.

## Layout

| Path | What |
| --- | --- |
| `lib/` | Flutter UI and state (control plane) for both apps |
| `packages/mirrorcast_engine/` | Native data plane (Kotlin + Swift) and its typed Dart API |
| `android/`, `macos/` | Host app configuration (permissions, entitlements, window) |
| `test/`, `packages/mirrorcast_engine/test/` | Tests |

## Checks

```bash
flutter analyze
```

```bash
flutter test
```

```bash
cd packages/mirrorcast_engine && flutter test
```
