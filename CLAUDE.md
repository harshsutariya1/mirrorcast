# CLAUDE.md: working on MirrorCast

Android (sender) → macOS (receiver) screen and audio mirroring. One Flutter
project; the native data plane is the local plugin `packages/mirrorcast_engine`.
Read `docs/GUIDE.md` for the architecture and `docs/PROTOCOL.md` for the wire format.

## Non-negotiable rules

1. **No media in Dart.** Video frames and audio samples never cross a platform
   channel. Dart sends commands on `com.mirrorcast/control` and receives small
   maps on `com.mirrorcast/events`. Video reaches Flutter only as a texture.
2. **Security is not optional.** Every connection is TLS 1.3 with mutual
   authentication. The phone pins the Mac's certificate fingerprint; the Mac
   checks the phone's fingerprint against `TrustedDeviceStore` before
   streaming. Never add a plaintext path, a "skip pairing" flag, or logging of
   PINs, secrets or media.
3. **Protocol changes are three-way.** `Wire.kt`, `Wire.swift` and
   `docs/PROTOCOL.md` must always agree. The same goes for `PairingCrypto.kt` and
   `PairingCrypto.swift`; recheck them against the test vectors in PROTOCOL.md.
4. **Validate everything from the network.** Check sizes before allocating,
   reject unknown types, and close on anything malformed.

## Layout

- `lib/src/sender/`: Android UI and state (Riverpod `Notifier`s)
- `lib/src/receiver/`: macOS UI and state
- `lib/src/shared/`: theme, widgets, formatting, constants
- `packages/mirrorcast_engine/lib/`: typed Dart API over the channels
- `packages/mirrorcast_engine/android/src/main/kotlin/com/mirrorcast/engine/`: capture, encode, TLS client, pairing
- `packages/mirrorcast_engine/macos/mirrorcast_engine/Sources/mirrorcast_engine/`: TLS server, pairing, decode, audio, window

## Conventions

- Material widgets come from `package:material_ui/material_ui.dart`, not
  `package:flutter/material.dart` (Material was moved out of the SDK).
- Riverpod 3 `Notifier`/`AsyncNotifier`, no code generation. Check `ref.mounted` after `await`.
- Wrap fire-and-forget futures in `unawaited(...)`; analysis treats unawaited futures as errors.
- `dart format` with page width 120.
- Kotlin: blocking I/O on dedicated threads, never on the main thread. The
  session thread (`mc-session`) owns the capture pipeline.
- Swift: everything on `ReceiverController.queue` except Flutter entry points
  (main thread) and VideoToolbox output callbacks.
- User-facing errors use stable codes (`EngineException.code`) plus a friendly message.

## Commands

```bash
flutter analyze
```

```bash
flutter test
```

```bash
cd packages/mirrorcast_engine && flutter test
```

```bash
flutter run -d macos
```

```bash
flutter build apk --release
```
