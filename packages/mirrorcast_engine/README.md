# mirrorcast_engine

The native **data plane** of MirrorCast, packaged as a Flutter plugin so it is
registered automatically on both platforms.

| Platform | What it does |
| --- | --- |
| Android (`android/src/main/kotlin/com/mirrorcast/engine`) | Screen capture, hardware H.264/H.265 encoding, internal-audio capture, TLS 1.3 client, pairing |
| macOS (`macos/mirrorcast_engine/Sources/mirrorcast_engine`) | TLS 1.3 server, pairing, trusted-phone list, VideoToolbox decoding to a Flutter texture, audio playback, window modes |
| Dart (`lib/`) | Typed API (`SenderEngine`, `ReceiverEngine`, `PairingLink`) over two platform channels |

Video and audio never cross into Dart. See `../../docs/GUIDE.md` for the full
explanation and `../../docs/PROTOCOL.md` for the wire format.
