package com.mirrorcast.engine.protocol

/**
 * The MirrorCast wire protocol (version 1).
 *
 * Every message on the TLS connection is a "packet":
 *
 * ```
 * offset  size  field
 * 0       1     type      (see [PacketType])
 * 1       1     flags     (bit 0 = keyframe)
 * 2       8     ptsUs     presentation timestamp, microseconds, big-endian
 * 10      4     length    payload length in bytes, big-endian
 * 14      N     payload
 * ```
 *
 * Media packets carry raw H.264/H.265 or PCM bytes. Control packets carry a
 * small UTF-8 JSON object. This file must stay in sync with `Wire.swift` on the
 * Mac and with `docs/PROTOCOL.md`.
 */
object Wire {
    const val PROTOCOL_VERSION = 1
    const val HEADER_SIZE = 14

    const val FLAG_KEYFRAME = 0x01

    /** Upper bounds that protect both sides from absurd allocations. */
    const val MAX_CONTROL_PAYLOAD = 64 * 1024
    const val MAX_AUDIO_PAYLOAD = 64 * 1024
    const val MAX_VIDEO_PAYLOAD = 8 * 1024 * 1024

    fun maxPayloadFor(type: Int): Int = when (type) {
        PacketType.VIDEO_CONFIG, PacketType.VIDEO_FRAME -> MAX_VIDEO_PAYLOAD
        PacketType.AUDIO_PCM -> MAX_AUDIO_PAYLOAD
        else -> MAX_CONTROL_PAYLOAD
    }
}

/** Packet type identifiers. Values 0x00-0x0F are media, 0x10+ are control. */
object PacketType {
    // Media (phone -> Mac)
    const val VIDEO_CONFIG = 0x00 // SPS/PPS (+VPS for HEVC), Annex-B
    const val VIDEO_FRAME = 0x01 // One encoded access unit, Annex-B
    const val AUDIO_PCM = 0x02 // 10 ms of 48 kHz, 16-bit LE, stereo PCM

    // Session control
    const val HELLO = 0x10 // phone -> Mac: who I am and what I want
    const val WELCOME = 0x11 // Mac -> phone: accepted
    const val REJECT = 0x12 // Mac -> phone: refused (code + message), then close
    const val VIDEO_FORMAT = 0x13 // phone -> Mac: codec + dimensions of upcoming video
    const val AUDIO_STATE = 0x14 // phone -> Mac: audio streaming on/off
    const val KEYFRAME_REQUEST = 0x15 // Mac -> phone: decoder needs a fresh keyframe
    const val PING = 0x16 // Mac -> phone: clock sync / RTT probe
    const val PONG = 0x17 // phone -> Mac: echo + phone clock
    const val RECEIVER_STATS = 0x18 // Mac -> phone: fps / latency seen on the Mac
    const val BYE = 0x19 // either way: graceful shutdown

    // Pairing
    const val PAIR_COMMIT = 0x20 // PIN pairing: commitment for one round
    const val PAIR_REVEAL = 0x21 // PIN pairing: nonce that opens the commitment
    const val PAIR_PROOF = 0x22 // QR pairing: HMAC proof of the QR secret
    const val PAIR_RESULT = 0x23 // Mac -> phone: pairing succeeded

    fun isKnown(type: Int): Boolean = type in 0x00..0x02 || type in 0x10..0x19 || type in 0x20..0x23
}

/** What the phone wants to do on a connection (sent in HELLO). */
object SessionIntent {
    const val STREAM = "stream"
    const val PAIR_PIN = "pair_pin"
    const val PAIR_QR = "pair_qr"
}

/** Reasons the Mac can give in a REJECT packet. */
object RejectCode {
    const val NOT_PAIRED = "not_paired"
    const val BUSY = "busy"
    const val PAIRING_CLOSED = "pairing_closed"
    const val CODE_MISMATCH = "code_mismatch"
    const val PROTOCOL = "protocol_error"
    const val VERSION = "unsupported_version"
}
