# MirrorCast wire protocol (version 1)

This is the exact format spoken between the Android sender and the macOS
receiver. The implementations are:

- Android: `packages/mirrorcast_engine/android/src/main/kotlin/com/mirrorcast/engine/protocol/`
- macOS: `packages/mirrorcast_engine/macos/mirrorcast_engine/Sources/mirrorcast_engine/Protocol/`

If you change anything here, change both implementations and this file together.

## 1. Transport

- **TCP** on port **47474** by default. If that port is taken, the Mac tries the next nine
  (47475–47483) and advertises the one it got over Bonjour.
- **TLS 1.3 only**, with mutual authentication:
  - The Mac presents a self-signed ECDSA P-256 certificate. Its private key is in the Mac keychain.
  - The phone presents a self-signed ECDSA P-256 certificate. Its private key is in Android Keystore.
  - Neither side checks certificate authorities. Each side identifies the other by the
    **SHA-256 fingerprint of the DER certificate**, recorded during pairing.
- `TCP_NODELAY` is enabled on both ends, so small packets are never held back.
- There is one connection per session, and video, audio and control share it.

## 2. Packet framing

Every message is a packet with a 14-byte header. All integers are big-endian.

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 1 | `type` | See the table below |
| 1 | 1 | `flags` | bit 0 = keyframe (video only); other bits are 0 |
| 2 | 8 | `ptsUs` | Presentation timestamp in microseconds (phone's monotonic clock), or 0 |
| 10 | 4 | `length` | Payload length N |
| 14 | N | `payload` | Raw media bytes, or UTF-8 JSON for control packets |

Maximum payload sizes (a larger `length` closes the connection at once):

| Packet kind | Limit |
| --- | --- |
| Video (0x00, 0x01) | 8 MiB |
| Audio (0x02) | 64 KiB |
| Control (0x10+) | 64 KiB |

An unknown `type` also closes the connection.

> The original spec used a 13-byte header with no `flags`. The flags byte was
> added so the Mac can tell a keyframe without parsing the bitstream. That
> matters for recovering cleanly after dropped frames.

## 3. Packet types

### Media (phone → Mac)

| Type | Name | Payload |
| --- | --- | --- |
| `0x00` | `VIDEO_CONFIG` | Parameter sets in Annex-B (H.264: SPS+PPS, H.265: VPS+SPS+PPS). Sent at stream start and before **every** keyframe |
| `0x01` | `VIDEO_FRAME` | One encoded access unit in Annex-B. `flags & 1` = keyframe |
| `0x02` | `AUDIO_PCM` | 10 ms of 48 kHz, signed 16-bit little-endian, interleaved stereo PCM (1,920 bytes) |

### Control

| Type | Name | Direction | JSON body |
| --- | --- | --- | --- |
| `0x10` | `HELLO` | phone → Mac | `{"protocol":1,"intent":"stream"\|"pair_pin"\|"pair_qr","deviceName":"Pixel 8","model":"Google Pixel 8","codecs":["hevc","avc"]}` |
| `0x11` | `WELCOME` | Mac → phone | `{"protocol":1,"receiverName":"Studio Mac","decoders":["hevc","avc"]}` |
| `0x12` | `REJECT` | Mac → phone | `{"code":"not_paired"\|"busy"\|"pairing_closed"\|"code_mismatch"\|"protocol_error"\|"unsupported_version","message":"…"}`, then the Mac closes the connection |
| `0x13` | `VIDEO_FORMAT` | phone → Mac | `{"codec":"hevc"\|"avc","width":1080,"height":2400,"fps":60,"bitrate":12000000}`, sent before the first config and again after every resize (rotation) |
| `0x14` | `AUDIO_STATE` | phone → Mac | `{"enabled":true}` |
| `0x15` | `KEYFRAME_REQUEST` | Mac → phone | `{}` (the decoder lost sync) |
| `0x16` | `PING` | Mac → phone | `{"t":<Mac monotonic µs>}`, sent every second |
| `0x17` | `PONG` | phone → Mac | `{"t":<echoed>,"p":<phone monotonic µs>}`, sent ahead of any queued video |
| `0x18` | `RECEIVER_STATS` | Mac → phone | `{"fps":59.8,"latencyMs":28.4,"rttMs":3.1}`, every second |
| `0x19` | `BYE` | either | `{"reason":"user"\|"receiver"}` (graceful end; the phone does not reconnect) |
| `0x20` | `PAIR_COMMIT` | both | `{"round":0..19,"value":"<base64 32 bytes>"}` |
| `0x21` | `PAIR_REVEAL` | both | `{"round":0..19,"value":"<base64 16 bytes>"}` |
| `0x22` | `PAIR_PROOF` | phone → Mac | `{"proof":"<base64 32 bytes>"}` |
| `0x23` | `PAIR_RESULT` | Mac → phone | `{"ok":true,"receiverName":"Studio Mac"}` |

Both sides ignore unknown JSON fields, which leaves room for later additions.

## 4. Session flows

### Streaming

```text
phone                                   Mac
  |--- TLS 1.3 handshake (mutual) -------->|  phone pins the Mac's fingerprint
  |--- HELLO {intent:"stream"} ----------->|  Mac checks the phone's fingerprint is trusted
  |<-- WELCOME {decoders} -----------------|  (otherwise REJECT not_paired / busy)
  |--- VIDEO_FORMAT ---------------------->|
  |--- AUDIO_STATE ----------------------->|
  |--- VIDEO_CONFIG, VIDEO_FRAME(key) ---->|
  |--- VIDEO_FRAME ... AUDIO_PCM ... ----->|
  |<-- PING / RECEIVER_STATS (1 Hz) -------|
  |--- PONG ------------------------------>|
  |<-- KEYFRAME_REQUEST (on decode error) -|
  |--- BYE / <-- BYE ----------------------|
```

**Ordering rule:** `WELCOME` (or `REJECT`) is always the first packet the Mac
sends on a connection. The phone treats anything else before it as a protocol
error, so the Mac starts its `PING`s only after `WELCOME` has been sent.

If the connection drops without a `BYE`, the phone retries every second for up
to 20 seconds while capture keeps running. On reconnect it sends `VIDEO_FORMAT`
and `AUDIO_STATE` again and requests a keyframe.

Timeouts: the Mac closes a connection that sends no `HELLO` within 10 s, a
pairing that takes longer than 60 s, or a stream that is silent for 10 s. The
phone treats 15 s without data as a dead connection.

### PIN pairing (`intent: "pair_pin"`)

The phone does **not** pin the Mac's certificate here (it doesn't know it yet).
The PIN rounds below authenticate both certificates instead.

Notation:

- `Pp`, `Pm`: SHA-256 fingerprints (32 bytes) of the phone's and Mac's TLS certificates, as each side saw them.
- `r_i`: bit *i* of the 6-digit PIN read as an integer (PIN < 2²⁰, so 20 bits).
- `HMAC(k, m)`: HMAC-SHA-256.
- `‖`: concatenation.

```text
Cp_i = HMAC(Np_i, "MirrorCast-PIN-v1/sender"   ‖ Pp ‖ Pm ‖ (0x80 | r_i))
Cm_i = HMAC(Nm_i, "MirrorCast-PIN-v1/receiver" ‖ Pm ‖ Pp ‖ (0x80 | r_i))
```

For each round *i* = 0 … 19:

1. phone → `PAIR_COMMIT {round:i, value:Cp_i}` (with a fresh random 16-byte `Np_i`)
2. Mac → `PAIR_COMMIT {round:i, value:Cm_i}` (with a fresh random 16-byte `Nm_i`)
3. phone → `PAIR_REVEAL {round:i, value:Np_i}`. The Mac recomputes `Cp_i` with its own `r_i`; on mismatch it sends `REJECT code_mismatch`.
4. Mac → `PAIR_REVEAL {round:i, value:Nm_i}`. The phone recomputes `Cm_i`; on mismatch it aborts.

After round 19 the Mac stores `Pp` as trusted and sends `PAIR_RESULT`. The
phone stores `Pm`.

**Why this is safe.** This is the passkey-entry method from Bluetooth LE
Secure Connections. Each side commits before it sees the other's nonce, so a
man in the middle has to guess every bit in advance. It is caught with
probability ½ per round: 20 rounds give a 1 in 1,048,576 chance of going
unnoticed. The Mac replaces the PIN after **any** failed or abandoned attempt,
so an attacker gets one try per code. Because `Pp` and `Pm` go into every
commitment, success also proves both sides saw the same two certificates, so
the TLS session is authenticated. The PIN itself is never sent.

### QR pairing (`intent: "pair_qr"`)

The QR code contains:

```text
mirrorcast://pair?v=1&n=<name>&fp=<Mac fingerprint, 64 hex>&s=<base64url secret>&p=<port>&a=<ip>,<ip>
```

1. The phone connects with TLS pinned to `fp`, so it cannot be talking to anyone else.
2. phone → `HELLO {intent:"pair_qr"}`, Mac → `WELCOME`.
3. phone → `PAIR_PROOF {proof: HMAC(secret, "MirrorCast-QR-v1" ‖ Pp ‖ Pm)}`.
4. The Mac compares in constant time, trusts `Pp` and sends `PAIR_RESULT`.

The secret is 128 bits and single-use. It travels only inside the
already-authenticated TLS channel, as an HMAC rather than in the clear.

### Pairing window rules (Mac)

- Opens when you click **Pair new phone** and lasts 2 minutes.
- One attempt at a time; a second phone gets `busy`.
- The PIN and QR secret rotate after every failure, abandonment or timeout.
- After 5 failures the window closes.

## 5. Known-answer test vectors

Inputs:

```text
Pp     = 00 01 02 … 1f              (bytes 0..31)
Pm     = 20 21 22 … 3f              (bytes 32..63)
nonce  = a5 × 16
secret = 64 65 66 … 73              (bytes 100..115)
PIN    = 482913
```

Expected outputs (the Android implementation is verified against these):

```text
senderCommit   bit=0  1c4773912058c863661b6146c4375c1c8438907bbd99048f12b64bdc25232003
senderCommit   bit=1  418083a4073b7c18aa4035ff6f397c1d9d517d322ba4b1720976ce45073ad84c
receiverCommit bit=0  fad540b6620b15d851fe599ccda45f04985d5002be0d4cb79a16bc7ddafa2694
receiverCommit bit=1  188bdf13a83208c464fed1c7bec671fe938f67ef3d9f93c4fb50a73bcbf39c0c
qrProof               bfd155eb4743d4725a648e2c07045d88b0f21c20f84dec7c690fc1aa36bb6135
PIN bits r_0..r_19    1 0 0 0 0 1 1 0 0 1 1 1 1 0 1 0 1 1 1 0
```

## 6. Bonjour advertisement

- Service type `_mirrorcast._tcp`, service name = the Mac's computer name.
- TXT record: `v=1` (protocol version) and `fp=<64 hex>` (certificate fingerprint).

`fp` is only a hint that lets the phone show "Available" next to a paired Mac.
Security never depends on it: the TLS handshake pins the fingerprint the phone
stored at pairing time.
