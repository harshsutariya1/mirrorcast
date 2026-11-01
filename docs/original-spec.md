# MirrorCast — Ultra-Low-Latency Android-to-macOS Screen & Audio Mirroring

## 1. Project Overview & Core Philosophy
MirrorCast is a single-codebase Flutter application targeting **Android (Sender)** and **macOS (Receiver)** for ultra-low-latency (20ms–40ms) 60fps 1080p gaming and video streaming over local Wi-Fi (5GHz).

### CRITICAL ARCHITECTURAL RULE: ZERO DATA-PLANE IN DART
- **Flutter (Dart)** is strictly the **Control Plane & UI** (mDNS discovery via `bonsoir`, Riverpod state management, Start/Stop controls, Audio Routing toggle, and rendering the macOS `Texture` widget).
- **Native Kotlin (Android) & Native Swift (macOS)** form the **Data Plane**. 
- **NEVER** pass H.264 video NAL units or PCM audio byte arrays across Flutter `MethodChannel` or `EventChannel`. All encoding, socket transmission, decoding, and audio rendering happen 100% natively in Kotlin and Swift threads.

---

## 2. Directory & Module Structure
```text
mirror_cast/
├── CLAUDE.md
├── pubspec.yaml                  # flutter_riverpod, bonsoir
├── lib/
│   ├── main.dart                 # Platform-aware entry point (Android vs macOS UI)
│   ├── core/
│   │   ├── native_bridge.dart    # MethodChannel & EventChannel wrappers
│   │   └── mdns_service.dart     # Bonsoir broadcast (macOS) & discovery (Android)
│   └── ui/
│       ├── android_sender_screen.dart
│       └── macos_receiver_screen.dart
├── android/app/src/main/
│   ├── AndroidManifest.xml
│   └── kotlin/.../
│       ├── MainActivity.kt               # MethodChannel handler & MediaProjection intent launcher
│       ├── MirrorCaptureService.kt       # Foreground Service (mediaProjection)
│       ├── VideoEncoderPipeline.kt       # VirtualDisplay + MediaCodec H.264 HW Encoder
│       ├── AudioCapturePipeline.kt       # AudioPlaybackCapture + AudioRecord (Low-Latency PCM)
│       └── SocketStreamer.kt             # TCP Client (TCP_NODELAY) + 13-byte framing
└── macos/Runner/
    ├── DebugProfile.entitlements
    ├── Release.entitlements
    ├── MainFlutterWindow.swift           # MethodChannel & FlutterTexture registration
    ├── SocketReceiverServer.swift        # TCP Server listening on port 5000 (TCP_NODELAY)
    ├── H264HardwareDecoder.swift         # VideoToolbox VTDecompressionSession + FlutterTexture
    └── LowLatencyAudioPlayer.swift       # AVAudioEngine + AVAudioPlayerNode (48kHz Stereo PCM)
```

---

## 3. Binary Wire Protocol (TCP Port 5000, `TCP_NODELAY = true`)
All network packets sent from Android to macOS over the raw TCP socket use a strict **Big-Endian (Network Byte Order) 13-byte fixed header** followed immediately by the variable-length payload.

### Header Layout (13 Bytes)
| Byte Offset | Data Type | Field Name | Description |
| :--- | :--- | :--- | :--- |
| `0` | `UInt8` | `packetType` | `0x00` = H.264 Codec Config (SPS/PPS Annex-B)<br>`0x01` = H.264 Video Frame (Annex-B NAL unit)<br>`0x02` = Raw PCM Audio Chunk (48kHz, 16-bit Signed LE, Stereo) |
| `1..8` | `Int64` | `ptsUs` | Presentation Timestamp in microseconds (`Big-Endian`) |
| `9..12` | `UInt32` | `payloadSize` | Exact byte length of the following payload ($N$) (`Big-Endian`) |
| `13..(13+N)`| `UInt8[N]`| `payload` | Raw payload bytes |

### Synchronization & Threading Rules
1. **Single Socket Multiplexing:** Video (`0x00`, `0x01`) and Audio (`0x02`) share the same TCP connection. In `SocketStreamer.kt`, guard socket writes with a `ReentrantLock` or a dedicated single-threaded high-priority dispatch queue (`LinkedBlockingQueue` of byte buffers) so headers and payloads never interleave.
2. **SPS/PPS Caching:** When `MediaCodec` outputs `BUFFER_FLAG_CODEC_CONFIG`, send it immediately as `0x00` and cache the exact bytes in `VideoEncoderPipeline.kt`. Also prepend the cached SPS/PPS bytes to every subsequent Keyframe (`BUFFER_FLAG_KEY_FRAME`) or resend `0x00` right before any keyframe.

---

## 4. MethodChannel & EventChannel Contracts

### Channel Names
- **MethodChannel:** `com.mirrorcast/control`
- **EventChannel:** `com.mirrorcast/events` (Streams state maps: `{"state": "connected" | "disconnected" | "error", "message": "...", "fps": 60, "width": 1920, "height": 1080}`)

### Android Methods (`Dart -> Kotlin`)
1. `startMirroring(Map<String, dynamic> args)`
   - **Arguments:**
     ```json
     {
       "host": "192.168.1.50",
       "port": 5000,
       "width": 1920,
       "height": 1080,
       "fps": 60,
       "bitrate": 8000000,
       "audioMode": "phone" // "phone" or "mac"
     }
     ```
   - **Action:** Triggers `MediaProjectionManager.createScreenCaptureIntent()`. On `RESULT_OK`, starts `MirrorCaptureService` as a foreground service and connects `SocketStreamer`.
2. `stopMirroring()`
   - **Action:** Closes socket, stops `MediaCodec`, stops `AudioRecord`, restores phone volume if muted, releases `VirtualDisplay` and `MediaProjection`, stops foreground service.
3. `setAudioRouting(Map<String, dynamic> args)`
   - **Arguments:** `{"audioMode": "phone" | "mac"}`
   - **Action (Can be called mid-stream!):**
     - If `"phone"`: Stops `AudioCapturePipeline` immediately and unmutes phone `STREAM_MUSIC` so audio plays natively through phone speakers or Bluetooth earbuds paired to the phone.
     - If `"mac"`: Starts `AudioCapturePipeline` using the active `MediaProjection` token and streams `0x02` packets to macOS. If no Bluetooth A2DP/LE-Audio headset is active, optionally mute local phone speaker (`AudioManager.adjustStreamVolume(STREAM_MUSIC, ADJUST_MUTE, 0)`).

### macOS Methods (`Dart -> Swift`)
1. `initReceiver() -> Map<String, dynamic>`
   - **Action:** Registers `FlutterTexture` with `FlutterTextureRegistry`, initializes `H264HardwareDecoder` and `LowLatencyAudioPlayer`, and starts `SocketReceiverServer` on port `5000`.
   - **Returns:** `{"textureId": Int64, "port": 5000}`
2. `disposeReceiver()`
   - **Action:** Stops TCP server, invalidates `VTDecompressionSession`, stops `AVAudioEngine`, unregisters texture.

---

## 5. Android Sender Implementation Specs (Kotlin)

### Required Permissions (`AndroidManifest.xml`)
```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

<service
    android:name=".MirrorCaptureService"
    android:enabled="true"
    android:exported="false"
    android:foregroundServiceType="mediaProjection" />
```

### Hardware H.264 `MediaCodec` Configuration (`VideoEncoderPipeline.kt`)
Configure `MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)` with these exact flags for zero B-frame buffering:
```kotlin
val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
    setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
    setInteger(MediaFormat.KEY_BIT_RATE, bitrate) // Default: 8_000_000 (8 Mbps)
    setInteger(MediaFormat.KEY_FRAME_RATE, 60)
    setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // Keyframe every 1 second
    setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileConstrainedBaseline)
    setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel41)
    setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
    // Critical low-latency flags (Android 10+ / API 29+)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
    }
    setInteger(MediaFormat.KEY_LATENCY, 0)
    setInteger(MediaFormat.KEY_PRIORITY, 0) // Realtime priority
    setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 16_666L) // Repeat frame after ~16.6ms if screen is static
}
```
- **Dynamic Orientation / Aspect Ratio:** Detect display orientation or cap the longer dimension to `1920` and scale the shorter dimension proportionally (aligned to a multiple of 16, e.g., `1920x1080` in landscape or `1080x1920` in portrait) so `MediaCodec` hardware encoders never reject odd resolutions.

### Internal Audio Capture (`AudioCapturePipeline.kt`)
```kotlin
val config = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
    .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
    .addMatchingUsage(AudioAttributes.USAGE_GAME)
    .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
    .build()

val audioFormat = AudioFormat.Builder()
    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
    .setSampleRate(48000)
    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
    .build()

// Use a small chunk size (e.g., 1920 bytes = 10ms of 48kHz 16-bit Stereo audio)
val minBufferSize = AudioRecord.getMinBufferSize(48000, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
val audioRecord = AudioRecord.Builder()
    .setAudioFormat(audioFormat)
    .setBufferSizeInBytes(maxOf(minBufferSize, 3840))
    .setAudioPlaybackCaptureConfig(config)
    .build()
```
- Read in chunks of **1920 bytes** (exactly 10ms of 48kHz stereo 16-bit PCM) on a dedicated `Process.THREAD_PRIORITY_URGENT_AUDIO` thread and send immediately as `0x02` packets.

---

## 6. macOS Receiver Implementation Specs (Swift)

### Entitlements (`DebugProfile.entitlements` & `Release.entitlements`)
Both entitlement files MUST include:
```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

### Hardware VideoToolbox Decoder (`H264HardwareDecoder.swift`)
1. **Annex-B to AVCC Conversion:**
   - Incoming packets from Android `MediaCodec` are in **Annex-B format** (start codes `0x00 0x00 0x00 0x01` or `0x00 0x00 0x01`).
   - Apple's `CMVideoFormatDescriptionCreateFromH264ParameterSets` requires raw SPS and PPS pointers **stripped of start codes**.
   - Apple's `VTDecompressionSessionDecodeFrame` requires **AVCC format** where each 4-byte start code is replaced with a 4-byte Big-Endian length header.
2. **Creating the Format Description (on `0x00` packet):**
   - Split the `0x00` payload by Annex-B start codes to extract the SPS (`nalType == 7`) and PPS (`nalType == 8`) NAL units.
   - Call `CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ..., parameterSetSizes: ..., nalUnitHeaderLength: 4, formatDescriptionOut: &formatDesc)`.
3. **Creating `VTDecompressionSession`:**
   ```swift
   let decoderSpecification: [CFString: Any] = [
       kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: kCFBooleanTrue!
   ]
   let destinationPixelBufferAttributes: [CFString: Any] = [
       kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
       kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
       kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
   ]
   ```
   - **CRITICAL:** Pixel format MUST be `kCVPixelFormatType_32BGRA` and include `kCVPixelBufferIOSurfacePropertiesKey` and `kCVPixelBufferMetalCompatibilityKey` so Flutter's macOS engine can render the `CVPixelBuffer` directly onto the GPU texture with zero CPU memory copy.
   - Decode flags: Pass `0` (synchronous / immediate emission) or handle the decompression output callback by storing the latest `CVPixelBuffer` in a thread-safe lock (`os_unfair_lock`) and calling `textureRegistry.textureFrameAvailable(textureId)` on the main/engine thread.

### Low-Latency Audio Output (`LowLatencyAudioPlayer.swift`)
1. Initialize an `AVAudioEngine` and `AVAudioPlayerNode`.
2. Create an input format matching Android's output:
   ```swift
   let pcmFormat = AVAudioFormat(
       commonFormat: .pcmFormatInt16,
       sampleRate: 48000,
       channels: 2,
       interleaved: true
   )!
   ```
3. Connect `playerNode` to `engine.mainMixerNode` using `engine.mainMixerNode.outputFormat(forBus: 0)` and convert incoming 16-bit interleaved PCM packets (`0x02`) into `AVAudioPCMBuffer` (Float32 non-interleaved via `AVAudioConverter` or by scheduling directly onto a node configured for interleaved Int16/Float32).
4. **Drift Protection:** Maintain a maximum queue depth of 4 audio buffers (~40ms). If more than 5 buffers are queued in flight (due to a Wi-Fi spike), drop the oldest buffer to immediately snap audio back to real-time sync with video.

---

## 7. Phased Implementation Plan for Claude Code
When executing this build, proceed in these exact 4 phases and verify compilation at each step:

- **Phase 1:** Update `pubspec.yaml`, Android manifest, and macOS entitlements. Implement `bonsoir` mDNS advertisement on macOS (`_mirrorcast._tcp` on port 5000) and discovery on Android. Build the Flutter UI for both platforms.
- **Phase 2:** Implement the macOS Swift native layer (`SocketReceiverServer`, `H264HardwareDecoder` with `FlutterTexture`, and `LowLatencyAudioPlayer`) and wire it to `MainFlutterWindow.swift`. Verify `flutter build macos` succeeds with zero warnings.
- **Phase 3:** Implement the Android Kotlin native layer (`MirrorCaptureService`, `VideoEncoderPipeline`, `AudioCapturePipeline`, `SocketStreamer`) and wire it to `MainActivity.kt`. Verify `flutter build apk --debug` succeeds.
- **Phase 4:** End-to-end integration check, portrait/landscape aspect-ratio signaling via the EventChannel, and runtime audio routing switch (`Phone / BT` <-> `Mac Speakers`).