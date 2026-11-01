# MirrorCast: the complete guide

This guide explains everything about MirrorCast: what it does, how to build and
use it, how every part works, why each technology was chosen, and how it keeps
your screen private. Each topic starts in plain language and then goes
deeper, so you can stop reading as soon as you have what you need.

---

## Contents

1. [What MirrorCast is](#1-what-mirrorcast-is)
2. [Quick start](#2-quick-start)
3. [Using the apps](#3-using-the-apps)
4. [The big picture](#4-the-big-picture)
5. [Project layout](#5-project-layout)
6. [The life of a video frame](#6-the-life-of-a-video-frame)
7. [The life of an audio sample](#7-the-life-of-an-audio-sample)
8. [Security: how your screen stays private](#8-security-how-your-screen-stays-private)
9. [Connecting: Wi-Fi, USB, address, hotspot](#9-connecting-wi-fi-usb-address-hotspot)
10. [Quality, codecs and keeping latency low](#10-quality-codecs-and-keeping-latency-low)
11. [The stats, and how latency is measured](#11-the-stats-and-how-latency-is-measured)
12. [The Flutter side: UI and state](#12-the-flutter-side-ui-and-state)
13. [Technology choices](#13-technology-choices)
14. [Code quality, testing and verification](#14-code-quality-testing-and-verification)
15. [Troubleshooting](#15-troubleshooting)
16. [Changes from the original spec](#16-changes-from-the-original-spec)
17. [Glossary](#17-glossary)

---

## 1. What MirrorCast is

MirrorCast shows your **Android phone's screen and sound on your Mac** with
very little delay, low enough for games and video.

- **One Flutter project, two apps.** On Android it is the *sender*; on macOS it is the *receiver*.
- **No accounts, no cloud, no stores.** The phone talks straight to the Mac over your
  network or a USB cable. Nothing is uploaded or stored anywhere else.
- **Encrypted end to end.** Every byte travels inside TLS 1.3, and the two devices only
  accept each other after a one-time pairing.
- **Fast.** Typical capture-to-screen latency is 20–40 ms on good 5 GHz Wi-Fi, and lower over USB.

What it deliberately does **not** do (version 1): control the phone from the
Mac, record the stream, or mirror several phones at once.

---

## 2. Quick start

### What you need

| | Requirement |
| --- | --- |
| Phone | Android **10 or newer** (needed to capture other apps' audio) |
| Mac | macOS **13 Ventura or newer**, Apple Silicon or Intel |
| Network | Both on the same Wi-Fi (5 GHz recommended), **or** a USB cable |
| Tools | Flutter (stable), Xcode, Android SDK. Optional: `adb` for USB mode |

### Build and run

```bash
flutter pub get
```

Run the receiver on the Mac:

```bash
flutter run -d macos
```

Run the sender on the phone (USB debugging enabled and the phone plugged in):

```bash
flutter run -d <your-phone-id>
```

Release builds:

```bash
flutter build macos --release
```

```bash
flutter build apk --release
```

The macOS app ends up in `build/macos/Build/Products/Release/MirrorCast.app`;
drag it to Applications. Install the APK with `adb install` or by copying it to the phone.

> **About signing.** This is a personal, side-loaded project, so the Android
> release build is signed with your local debug key and the Mac app is signed
> "to run locally". To use your own Android keystore, add a `signingConfigs`
> block in `android/app/build.gradle.kts`. Nothing else changes.

### First connection (about 30 seconds)

1. Open MirrorCast on the Mac. It says **Ready to mirror**.
2. Open MirrorCast on the phone. Your Mac appears under **Nearby**.
3. On the Mac click **Pair new phone** (⌘N). A 6-digit code and a QR code appear.
4. On the phone either tap the Mac and type the code, or tap **Scan pairing QR code**.
5. The Mac now appears under **Your Macs**. Tap **Mirror**, allow screen capture, and you're live.

From then on it's just step 5: one tap.

---

## 3. Using the apps

### Phone (sender)

| Screen | What's there |
| --- | --- |
| **Home** | *Your Macs* (paired, with a live "Available" dot), *Nearby* (unpaired Macs found on Wi-Fi), and *Other ways to connect* (QR, USB, address) |
| **Pair with code** | Six digit boxes. Pairing starts automatically after the sixth digit |
| **Scan pairing code** | Camera view; point it at the QR code on the Mac |
| **Mirroring** | Live status, timer, latency/FPS/bitrate/resolution/codec/round-trip, the **Sound plays on: Mac / Phone** switch, *Mute phone speaker*, and **Stop mirroring** |
| **Settings** | Quality presets, codec, default audio output, paired Macs (forget), this phone's fingerprint |

You can leave the app while mirroring. A notification stays visible with a
**Stop** button, as Android requires for screen capture.

### Mac (receiver)

| Screen | What's there |
| --- | --- |
| **Ready** | Status, *Pair new phone*, USB instructions with a copy button, connection details (IP addresses, port, fingerprint), and the **Trusted phones** list with **Remove** |
| **Pairing dialog** | Big PIN, QR code, countdown, and live feedback (wrong code, expired, paired) |
| **Viewer** | The phone's screen. Move the mouse to show the toolbar; double-click for full screen |

Keyboard shortcuts (also in the menu bar):

| Shortcut | Action |
| --- | --- |
| ⌘N | Pair new phone |
| ⌘I | Show or hide the stats overlay |
| ⇧⌘M | Mute or unmute the phone's audio on the Mac |
| ⌥⌘T | Keep the window on top of others |
| ⌥⌘P | Mini player: a small floating window in the corner, like picture-in-picture |
| ⌃⌘F | Full screen |
| Esc | Leave full screen or the mini player |
| ⇧⌘D | Disconnect the phone |

---

## 4. The big picture

MirrorCast is split into two layers. Keeping them apart is the main reason it is fast.

```text
            ANDROID (sender)                                  macOS (receiver)
 ┌─────────────────────────────────────┐          ┌─────────────────────────────────────┐
 │  Flutter UI (Dart)  — CONTROL PLANE │          │  Flutter UI (Dart)  — CONTROL PLANE │
 │  buttons, lists, settings, pairing  │          │  ready screen, pairing, viewer      │
 │  Bonjour discovery (bonsoir)        │          │  Bonjour advertising (bonsoir)      │
 └───────────────┬─────────────────────┘          └───────────────┬─────────────────────┘
       commands  │  ▲ small status events               commands  │  ▲ events   ▲ GPU texture
                 ▼  │                                             ▼  │           │
 ┌─────────────────────────────────────┐   TLS 1.3   ┌─────────────────────────────────────┐
 │  Kotlin engine — DATA PLANE         │ ══════════▶ │  Swift engine — DATA PLANE          │
 │  MediaProjection → VirtualDisplay   │  one socket │  Network.framework TLS server       │
 │  → MediaCodec (H.264/H.265, HW)     │  video +    │  → VideoToolbox (HW decode)         │
 │  AudioPlaybackCapture (PCM)         │  audio +    │  → CVPixelBuffer → Flutter Texture  │
 │  TLS client + pinning + pairing     │  control    │  AVAudioEngine (PCM playback)       │
 └─────────────────────────────────────┘             └─────────────────────────────────────┘
```

- The **control plane** (Dart/Flutter) is everything you see and click. It
  sends commands such as "start mirroring" and receives small updates such as
  "streaming at 60 fps".
- The **data plane** (Kotlin on Android, Swift on macOS) moves the actual
  pixels and sound. Video frames and audio samples **never** pass through
  Dart. Copying megabytes per second across the Flutter bridge would add
  latency and drain battery.
- On the Mac, decoded frames reach Flutter as a **GPU texture**. Flutter draws
  the frame the hardware decoder produced, with no CPU copy.

The two layers talk over two channels:

- `com.mirrorcast/control` (method channel): Dart → native commands.
- `com.mirrorcast/events` (event channel): native → Dart status maps.

---

## 5. Project layout

```text
mirrorcast/
├── lib/                              ← Flutter app (control plane)
│   ├── main.dart                     ← picks the sender (Android) or receiver (macOS) app
│   └── src/
│       ├── shared/                   ← theme, widgets, formatting, constants, preferences
│       ├── sender/                   ← Android app
│       │   ├── data/                 ← settings & presets, paired-Mac model, Bonjour discovery
│       │   ├── state/                ← Riverpod providers + MirrorController
│       │   └── ui/                   ← home, pairing (PIN/QR), USB/address sheets, streaming, settings
│       └── receiver/                 ← macOS app
│           ├── data/                 ← Bonjour advertiser, network addresses
│           ├── state/                ← ReceiverController, PairingController, trusted phones
│           └── ui/                   ← ready screen, pairing dialog, viewer + stats overlay
├── packages/mirrorcast_engine/       ← native data plane, packaged as a Flutter plugin
│   ├── lib/                          ← typed Dart API (SenderEngine, ReceiverEngine, PairingLink)
│   ├── android/src/main/kotlin/com/mirrorcast/engine/
│   │   ├── MirrorcastEnginePlugin.kt ← channel handler, permissions, screen-capture consent
│   │   ├── EngineEvents.kt           ← event channel (thread-safe, replays last state)
│   │   ├── EngineException.kt        ← stable error codes + friendly messages
│   │   ├── protocol/                 ← packet format (Wire.kt, PacketIO.kt)
│   │   ├── security/                 ← Keystore identity, TLS 1.3 client with pinning
│   │   ├── pairing/                  ← PIN & QR pairing (PairingCrypto.kt, PairingClient.kt)
│   │   └── stream/                   ← foreground service, session, encoder, audio, sender queue
│   └── macos/mirrorcast_engine/Sources/mirrorcast_engine/
│       ├── MirrorcastEnginePlugin.swift ← channel handler
│       ├── ReceiverController.swift  ← orchestrates everything below
│       ├── EventEmitter.swift        ← event channel
│       ├── Protocol/                 ← packet format (Wire.swift)
│       ├── Security/                 ← keychain identity, self-signed cert builder, trusted list
│       ├── Pairing/                  ← PIN/QR verification, pairing window
│       ├── Network/                  ← TLS server, per-phone session, packet framing
│       ├── Media/                    ← Annex-B parsing, VideoToolbox decoder, texture, audio, stats
│       └── Window/                   ← always-on-top, full screen, mini player
├── android/                          ← Android host app (manifest, Gradle)
├── macos/                            ← macOS host app (entitlements, Info.plist, window)
├── test/                             ← app tests
├── packages/mirrorcast_engine/test/  ← engine API tests
└── docs/                             ← this guide, PROTOCOL.md, original spec
```

**Why a plugin?** Native code inside a Flutter *plugin* is registered
automatically on both platforms, and the macOS sources are compiled through
Swift Package Manager without hand-editing the Xcode project. It also keeps the
"no media in Dart" rule visible: `packages/mirrorcast_engine` *is* the data plane.

---

## 6. The life of a video frame

From the moment a pixel changes on the phone to the moment it shows on the Mac:

| # | Where | What happens | Typical time |
| --- | --- | --- | --- |
| 1 | Phone GPU | Android composites the screen into a **VirtualDisplay** whose surface belongs to the encoder | ≤ 1 frame |
| 2 | Phone encoder | **MediaCodec** (hardware) compresses it to H.265 or H.264, with no B-frames and real-time priority | 3–8 ms |
| 3 | `PacketSender` | The frame is queued; one writer thread sends it on the TLS socket (`TCP_NODELAY`) | < 1 ms |
| 4 | Wi-Fi / USB | Network transfer (AES-GCM encryption is hardware-accelerated on both ends) | 2–10 ms (Wi-Fi), ~1 ms (USB) |
| 5 | Mac `PacketConnection` | Reads the 14-byte header, then exactly *N* payload bytes | < 1 ms |
| 6 | `VideoDecoder` | Annex-B → AVCC conversion, then **VideoToolbox** hardware decode into a BGRA `CVPixelBuffer` | 2–5 ms |
| 7 | `VideoTexture` | Keeps only the newest frame and tells Flutter a frame is available | < 1 ms |
| 8 | Flutter | Draws the GPU buffer directly on the next display refresh | ≤ 1 refresh |

Details that matter:

- **Annex-B vs AVCC.** Android writes NAL units separated by start codes
  (`00 00 01`); Apple wants each NAL prefixed by its 4-byte length. `AnnexB.swift`
  converts between them and validates the input.
- **Parameter sets.** The SPS/PPS (plus VPS for H.265) describe the stream. The
  phone sends them at start **and before every keyframe**, so the Mac can always
  resynchronise.
- **Rotation.** When you rotate the phone, the session resizes the
  VirtualDisplay and restarts the encoder at the new size, then sends a new
  `VIDEO_FORMAT`. The Mac rebuilds its decoder and the view adopts the new aspect ratio.
- **Single-app sharing (Android 14+).** If you share one app instead of the
  whole screen, MirrorCast follows that app's window size.
- **Static screens.** The encoder repeats the last frame every 100 ms when
  nothing changes, so the connection never looks dead and quality settles.

---

## 7. The life of an audio sample

1. **Capture.** `AudioPlaybackCapture` copies what apps are playing (media,
   games, "unknown" usage) as 48 kHz, 16-bit, stereo PCM in **10 ms chunks** on
   an urgent-priority thread. The microphone is never opened; Android only
   requires the *Record audio* permission to allow this kind of capture.
2. **Send.** Chunks go into the same TLS connection as video. If the link falls
   more than ~100 ms behind, new chunks are dropped rather than piling up.
3. **Play.** On the Mac, `AudioPlayer` converts each chunk to the format the
   output wants and schedules it on an `AVAudioPlayerNode`:
   - **Drift protection.** At most ~50 ms is kept queued; extra chunks are
     dropped, and a big backlog (after a Wi-Fi stall) is flushed at once, so
     sound snaps back in sync with the picture.
   - **Underrun cushion.** After the queue runs dry it waits for two chunks
     before resuming, which avoids crackles on a jittery link.
   - **Device changes.** Plugging in headphones or switching to AirPods
     restarts the audio engine automatically.

**Switching mid-stream.** *Sound plays on: Mac / Phone* starts or stops
capture instantly. With *Mac*, the phone speaker is muted (if the setting is
on) and restored exactly as it was when you switch back or stop. MirrorCast
only unmutes what it muted itself.

> Android rule: apps can opt out of being captured (some DRM video apps do),
> and calls and notifications are never captured. Their sound stays on the phone.

---

## 8. Security: how your screen stays private

### In plain words

- Each device creates its own **secret key** the first time it runs. The key
  never leaves the device: it lives in **Android Keystore** on the phone and in
  the **macOS keychain** on the Mac.
- **Pairing** is a one-time step in which the two devices learn each other's
  public identity (a "fingerprint"). It takes a 6-digit code or a QR code that
  only someone looking at your Mac can see.
- After that, every connection is **encrypted with TLS 1.3** (the same
  standard as HTTPS), and each device checks that the other is *exactly* the one
  it paired with. Someone else on your Wi-Fi can't watch the stream, pretend to
  be your Mac, or stream to it.
- The Mac keeps a **Trusted phones** list, and **Remove** revokes a phone
  instantly, disconnecting it if it is connected.

### Identities

| | Phone | Mac |
| --- | --- | --- |
| Key | ECDSA P-256 in Android Keystore (non-exportable, hardware-backed on most phones) | ECDSA P-256 in the login keychain |
| Certificate | Self-signed, created by Keystore | Self-signed, built by `SelfSignedCertificate.swift` |
| Identified by | SHA-256 of the certificate | SHA-256 of the certificate |
| Stored about the other side | Mac fingerprint, name, last address (`shared_preferences`) | Phone fingerprint, name, model, dates (`trusted-phones.json` in the sandbox container) |

No certificate authorities are involved; there are none on a home network.
Instead, each side **pins** the other's fingerprint. That is stronger than CA
trust for this purpose, because only the one device you paired is accepted.

### TLS 1.3 everywhere

- Both directions are authenticated (mutual TLS). The Mac *requires* a client certificate.
- The phone's `PinnedTrustManager` rejects any Mac whose fingerprint isn't one it paired with.
- The Mac accepts any certificate *at the TLS layer*, then `ClientSession` checks the
  fingerprint against the trusted list before anything else happens. An unknown phone
  can only reach the pairing flow, and only while you have the pairing window open.
- TLS 1.3 uses AES-GCM or ChaCha20-Poly1305 with forward secrecy. Recording the
  traffic today and stealing a key later still doesn't decrypt it.

### Pairing, explained

**QR code (strongest and fastest).** The QR code contains the Mac's
fingerprint and a fresh 128-bit secret. The phone connects with TLS pinned to
that fingerprint, so it can only be talking to *your* Mac, and proves it saw
the QR code by sending an HMAC of the secret. The secret is single-use.

**6-digit code.** The phone doesn't know the Mac's fingerprint yet, so the
code has to authenticate both sides. MirrorCast uses the method Bluetooth uses
for "enter the passkey" pairing:

- The code is checked **one bit at a time over 20 rounds**.
- In each round, both devices first send a sealed *commitment* to (a random
  nonce + one bit of the code + both TLS fingerprints), then open it.
- An attacker sitting in the middle would have to guess each bit *before*
  seeing it, and is caught with a 50% chance per round. Surviving all 20 rounds
  is a 1-in-a-million chance, and the Mac **changes the code after any failure**,
  so an attacker gets exactly one try.
- Because both fingerprints are sealed into every commitment, success proves
  the TLS connection itself is genuine, not just that someone knew the code.
- The code is never sent over the network, not even encrypted.

**Pairing window.** Pairing is only possible for 2 minutes after you click
*Pair new phone*, one attempt at a time. After 5 wrong attempts it closes.

Full byte-level detail is in [PROTOCOL.md](PROTOCOL.md).

### Other protections

- **Strict input validation.** Every packet's type and size is checked before
  anything is allocated (video ≤ 8 MiB, audio and control ≤ 64 KiB), and
  malformed data closes the connection.
- **Connection limits.** The Mac accepts at most 8 simultaneous connections,
  and streams from one phone at a time (others get "busy").
- **Timeouts.** Silent or slow connections are closed (see PROTOCOL.md).
- **App Sandbox** on the Mac: the receiver can only use the network and its own container.
- **No backups** on Android (`allowBackup=false` + data-extraction rules), so
  pairing data never ends up in a cloud backup.
- **No logging of content.** Logs never contain frames, audio, PINs or secrets.
- **Constant-time comparisons** for every secret check.

### What MirrorCast does *not* protect against

- Someone who can **see your Mac's screen** while the pairing code is shown
  could pair their phone. Only open the pairing window when you mean to.
- Someone with **unlocked access** to your phone or Mac can use the app like you can.
- Network observers can tell *that* two devices are streaming (packet sizes and
  timing), not *what* is on screen.

---

## 9. Connecting: Wi-Fi, USB, address, hotspot

| Path | How it works | When to use |
| --- | --- | --- |
| **Wi-Fi (automatic)** | The Mac advertises `_mirrorcast._tcp` over Bonjour; the phone lists it under Nearby or Your Macs | Everyday use |
| **USB cable** | `adb reverse tcp:47474 tcp:47474` makes the phone's `127.0.0.1:47474` reach the Mac. The phone connects to localhost and still pins the Mac's fingerprint | Lowest, most stable latency; no Wi-Fi needed |
| **Enter address** | Type the IP shown in the Mac's *Connection details* | Networks that block Bonjour (guest Wi-Fi, "AP isolation", some mesh routers) |
| **Phone hotspot** | Connect the Mac to the phone's hotspot, then use Wi-Fi or Enter address | Anywhere: trains, hotels |

**Why is USB a manual command?** The Mac app runs in Apple's App Sandbox,
which doesn't allow launching `adb`. That keeps the receiver locked down, at
the cost of running one command each time you plug in.

**Why port 47474 and not 5000?** On macOS 12 and later, port 5000 is used by
the built-in *AirPlay Receiver*. If 47474 is busy, MirrorCast tries the next
few ports and advertises whichever it got.

---

## 10. Quality, codecs and keeping latency low

### Presets (phone → Settings → Quality)

| Preset | Resolution (long side) | FPS | Bitrate | Best for |
| --- | --- | --- | --- | --- |
| Ultra-low latency | 1280 (720p) | 60 | 6 Mbps | Games, weaker Wi-Fi |
| **Balanced** (default) | 1920 (1080p) | 60 | 12 Mbps | Almost everything |
| Quality | Native | 60 | 24 Mbps | Reading small text, video, strong 5 GHz Wi-Fi |
| Custom | 720p…1440p or native | 30–120 | 2–40 Mbps | Experimenting |

If the phone's encoder can't handle a setting (some can't do 120 fps or native
resolution), MirrorCast picks the closest one it supports: it shrinks the size
in steps, lowers the frame rate and clamps the bitrate. It never just fails.

### Codec negotiation

The phone says which codecs it can **encode in hardware**; the Mac says which it
can **decode in hardware**. With *Automatic*, H.265/HEVC is used when both
support it (about 40% less data for the same picture, so fewer Wi-Fi hiccups);
otherwise H.264. *H.264 only* forces the universal option.

### How latency is kept low

- **No B-frames**, real-time encoder priority, low-latency hints, constant bitrate.
- **One connection** with `TCP_NODELAY` on both ends.
- **Backpressure.** TCP never loses data, but a slow link can build a queue,
  and a queue is delay. If more than 3 video frames are waiting, the phone drops
  frames, asks the encoder for a fresh **keyframe**, and resumes from it. You see
  a brief quality dip instead of a growing lag.
- **Keyframes on demand.** If the Mac's decoder ever loses sync, it asks for a
  keyframe (rate-limited) and skips broken frames until it arrives.
- **Latest frame wins.** The Mac only keeps the newest decoded frame for display.
- **Audio drift protection.** See section 7.
- **Auto-reconnect.** A Wi-Fi blip of up to 20 seconds is survived without
  restarting capture.

---

## 11. The stats, and how latency is measured

The phone's *Mirroring* screen and the Mac's overlay (⌘I) show:

| Stat | Meaning |
| --- | --- |
| **Latency** | Time from screen capture on the phone to decode on the Mac. Green ≤ 50 ms, amber ≤ 100 ms, red above |
| **FPS** | Frames decoded per second on the Mac |
| **Bitrate** | Data rate actually flowing |
| **Round trip** | Network ping time between the devices |
| **Video** | Resolution and codec |
| **Audio buffer** | How much audio is queued on the Mac (lower is snappier) |
| **Recovered errors** | Decoder resyncs (should stay 0 on a healthy link) |

**How can it measure latency across two clocks?** Like NTP. Every second the
Mac sends a ping with its clock time, and the phone answers with the echoed
time plus its own clock. From the round trip, the Mac estimates the offset
between the two clocks, using the sample with the smallest round trip as the
most accurate. Every frame carries the phone's capture timestamp, so the Mac
can convert it to its own clock and subtract. The figure is accurate to about
half the round-trip time, typically ±1–3 ms.

---

## 12. The Flutter side: UI and state

- **State management: Riverpod 3** (`Notifier` classes, no code generation).
  Every screen reads state from providers, and every action calls a method on a
  controller. Nothing important lives inside widgets.
  - Sender: `senderSettingsProvider`, `trustedMacsProvider`, `discoveryProvider`,
    `nearbyMacsProvider`, `deviceInfoProvider`, `mirrorControllerProvider`.
  - Receiver: `receiverControllerProvider`, `pairingControllerProvider`,
    `trustedPhonesProvider`, `showStatsProvider`.
- **Engine API.** Widgets never touch platform channels. They go through
  `SenderEngine` / `ReceiverEngine`, which turn channel maps into typed Dart
  objects (sealed event classes) and native errors into `EngineException` with
  stable codes such as `not_paired`, `busy` or `untrusted_receiver`.
- **Design.** Native-feeling and minimal: Material 3 with **Material You**
  colours on Android and your **accent colour** on macOS (via `dynamic_color`),
  light and dark following the system, flat outlined cards, compact density on
  the Mac, a real **macOS menu bar** with standard shortcuts, and haptic
  feedback on the phone.
- **Material package.** In this Flutter version, Material Design lives in the
  separate `material_ui` package, so widgets import `package:material_ui/material_ui.dart`.
- **Accessibility.** Semantic labels on the PIN field and QR code, tooltips on
  every icon button, text that scales with the system, sufficient contrast in both themes.

---

## 13. Technology choices

| Need | Choice | Why |
| --- | --- | --- |
| UI on both platforms | Flutter | One codebase for two very different apps |
| State | Riverpod 3 | Testable, explicit, no global singletons |
| Discovery | Bonjour via `bonsoir` | Native mDNS on both (Android NSD, Apple Bonjour) |
| Screen capture | MediaProjection + VirtualDisplay | The only supported way on Android; renders on the GPU straight into the encoder |
| Video encode | MediaCodec, hardware H.265/H.264 | Real-time, low power, hardware on every phone |
| Audio capture | AudioPlaybackCapture | Captures app audio without root (Android 10+) |
| Phone identity | Android Keystore | Keys can't be extracted, even by the app |
| Transport | TCP + TLS 1.3 | Encryption and authentication, reliable delivery, simple framing. Latency is handled by backpressure (see section 10) |
| Mac server | Network.framework | Apple's modern TLS stack, with TLS 1.3 and client-certificate support |
| Video decode | VideoToolbox | Hardware decode into IOSurface buffers that Flutter can draw without copying |
| Audio playback | AVAudioEngine | Low-latency, handles device changes |
| Mac identity | Keychain + self-signed cert | Private key protected by macOS; the certificate is public |
| Pairing | Passkey-entry commitments + QR secret | Proven designs, built only from HMAC-SHA-256 (no custom ciphers) |
| QR | `qr_flutter` (show), `mobile_scanner` (scan) | Offline, on-device |
| Settings storage | `shared_preferences` | Small, non-secret values only |

---

## 14. Code quality, testing and verification

- **Static analysis** is strict: `strict-casts`, `strict-inference`,
  `strict-raw-types`, unawaited futures are errors, plus extra lint rules
  (`analysis_options.yaml`). `flutter analyze` reports **no issues** for the app or the engine.
- **Formatting:** `dart format` with a page width of 120.
- **Dart tests**, run with `flutter test`:
  - `packages/mirrorcast_engine/test/pairing_link_test.dart`: QR link round-trip and rejection of malformed or malicious input.
  - `packages/mirrorcast_engine/test/events_test.dart`: parsing native events, including wrong types and missing fields.
  - `test/sender_data_test.dart`: settings and paired-Mac persistence, including corrupted storage.
  - `test/format_test.dart`: formatting helpers.
  - `test/pin_field_test.dart`: the PIN widget (digits only, six max, completion).
- **Cross-language checks:**
  - The Kotlin pairing crypto was run on the JVM and matches an independent
    reference byte for byte; the vectors are in PROTOCOL.md for checking the Swift side.
  - The Kotlin sources compile against the Android 16 framework classes with no warnings.
  - The Mac's certificate builder logic was checked with OpenSSL: valid X.509 v3,
    correct extensions, verifying self-signature.
- **Code style:** small classes with one job, comments that explain *why*, no
  magic numbers without a name, every error mapped to a clear message.

Verify locally:

```bash
flutter analyze
```

```bash
flutter test
```

```bash
cd packages/mirrorcast_engine && flutter test
```

---

## 15. Troubleshooting

| Symptom | Fix |
| --- | --- |
| **Mac doesn't appear on the phone** | Same Wi-Fi? Guest networks and "AP/client isolation" block Bonjour; use *Enter address* or USB. On macOS 15+, allow MirrorCast under *System Settings → Privacy & Security → Local Network* |
| **"This Mac's identity changed or it isn't paired"** | The Mac app was reinstalled or its keychain item was deleted, so it has a new identity. Forget it on the phone and pair again |
| **"This Mac doesn't trust this phone anymore"** | The phone was removed on the Mac. Pair again |
| **"The Mac is already mirroring another phone"** | Stop the other phone first (one stream at a time) |
| **Stutters or high latency** | Use 5 GHz Wi-Fi or USB, move closer to the router, or pick *Ultra-low latency* |
| **No sound on the Mac** | Check *Sound plays on: Mac*, and that the Mac isn't muted (⇧⌘M). Some apps block capture (DRM). If the phone speaker setting silences the stream on your phone model, turn off *Mute phone speaker* |
| **The Mac asks for keychain access** | Expected after rebuilding a debug build (the code signature changes). Click *Always Allow*. Release builds ask once |
| **USB mode can't connect** | Run `adb devices` (the phone must be listed and authorised), then run the `adb reverse` command again; it resets when you unplug |
| **"Port … unavailable"** | Another app uses 47474. MirrorCast picks the next free port automatically and shows it on the Ready screen |
| **Black screen on the Mac** | Some apps (banking, DRM video) mark their windows as secure, and Android shows them as black to every screen recorder |

---

## 16. Changes from the original spec

The original specification is kept in [original-spec.md](original-spec.md).
The implementation follows its architecture: no media in Dart, Kotlin and
Swift data planes, MethodChannel/EventChannel control, Bonjour, Texture
rendering, MediaCodec/VideoToolbox, AudioPlaybackCapture/AVAudioEngine. It
changes the following, for the reasons given:

| Original | Now | Why |
| --- | --- | --- |
| Plain TCP | **TLS 1.3 with mutual auth and pinning** | You chose full encryption; without it anyone on the Wi-Fi could watch |
| No pairing | **PIN + QR pairing, Mac-side revocation** | You chose both, with trust remembered |
| Port 5000 | **47474** (with fallback) | macOS 12+ AirPlay Receiver occupies 5000 |
| 13-byte header | **14-byte header with a flags byte** | Reliable keyframe detection and control messages |
| H.264 only | **H.265 when both support it, else H.264** | Your choice; better quality per bit |
| Native code in `Runner/` and `MainActivity` | **A local plugin** (`packages/mirrorcast_engine`) | Automatic registration on both platforms; no hand-edited Xcode project |
| `CHANNEL_OUT_STEREO` for capture | **`CHANNEL_IN_STEREO`** | `AudioRecord` takes an *input* channel mask |
| `KEY_LATENCY = 0` | Not set | 0 is not a valid value for that key (it is measured in frames) |
| `KEY_I_FRAME_INTERVAL = 1` | **2 s + keyframes on demand** | Fewer bitrate spikes; recovery doesn't wait for the timer |
| `REPEAT_PREVIOUS_FRAME_AFTER = 16.6 ms` | **100 ms** | Re-encoding a static screen 60 times a second wastes bandwidth for no visible gain |
| Constrained Baseline profile forced | Encoder default, B-frames disabled | Many encoders reject forced profile/level pairs; the fallback path keeps it working |
| — | Auto-reconnect, rotation and single-app resize, stats, presets, window modes | Requested features |

---

## 17. Glossary

| Term | Meaning |
| --- | --- |
| **Annex-B / AVCC** | Two ways of packaging H.264/H.265: start codes vs length prefixes |
| **Bonjour / mDNS** | How devices announce and find services on a local network without a server |
| **Codec** | The compression format (H.264/AVC, H.265/HEVC) |
| **Control plane / data plane** | The "steering" (UI and commands) vs the "cargo" (pixels and sound) |
| **Fingerprint** | SHA-256 hash of a device's certificate; its public ID |
| **Keyframe (IDR)** | A frame that can be decoded on its own; the others depend on earlier frames |
| **MediaProjection** | Android's screen-capture permission and API |
| **Pinning** | Accepting only one specific certificate instead of trusting authorities |
| **PTS** | Presentation timestamp: when a frame or sample was captured |
| **SPS / PPS / VPS** | Parameter sets that describe the video stream to the decoder |
| **TLS 1.3** | The modern standard for encrypting and authenticating connections |
| **VideoToolbox** | Apple's hardware video encoding/decoding framework |
