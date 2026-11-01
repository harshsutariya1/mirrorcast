package com.mirrorcast.engine.stream

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat

/** A video codec both devices agreed on, and the phone encoder that will produce it. */
data class CodecChoice(
    /** Wire name, shared with the Mac: "hevc" or "avc". */
    val wireName: String,
    val mime: String,
    val encoder: MediaCodecInfo,
) {
    val capabilities: MediaCodecInfo.VideoCapabilities?
        get() = try {
            encoder.getCapabilitiesForType(mime).videoCapabilities
        } catch (_: IllegalArgumentException) {
            null
        }

    val supportsCbr: Boolean
        get() = try {
            encoder.getCapabilitiesForType(mime).encoderCapabilities
                ?.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR) == true
        } catch (_: Exception) {
            false
        }
}

object CodecSupport {
    const val HEVC = "hevc"
    const val AVC = "avc"

    /** Finds a hardware encoder for [mime], or null. Software encoders are far too slow for 60 fps. */
    fun hardwareEncoder(mime: String): MediaCodecInfo? {
        val all = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
        return all.firstOrNull { info ->
            info.isEncoder &&
                info.isHardwareAccelerated &&
                !info.isAlias &&
                info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
        }
    }

    /** Codecs this phone can encode in hardware, best first. */
    fun localEncoders(): List<String> = buildList {
        if (hardwareEncoder(MediaFormat.MIMETYPE_VIDEO_HEVC) != null) add(HEVC)
        if (hardwareEncoder(MediaFormat.MIMETYPE_VIDEO_AVC) != null) add(AVC)
    }

    /**
     * Picks the best codec that the phone can encode and the Mac can decode.
     * H.265 needs roughly 40% less bandwidth than H.264 for the same picture,
     * which means fewer Wi-Fi stalls; H.264 is the universal fallback.
     *
     * @param preference "auto" (prefer H.265) or "avc" (force H.264).
     */
    fun choose(preference: String, receiverDecoders: List<String>): CodecChoice? {
        val order = if (preference == AVC) listOf(AVC) else listOf(HEVC, AVC)
        for (name in order) {
            if (name !in receiverDecoders) continue
            val mime = if (name == HEVC) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
            val encoder = hardwareEncoder(mime) ?: continue
            return CodecChoice(name, mime, encoder)
        }
        // Last resort: any AVC encoder at all (every Android phone has one).
        if (AVC in receiverDecoders) {
            val any = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { info ->
                info.isEncoder && info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true) }
            }
            if (any != null) return CodecChoice(AVC, MediaFormat.MIMETYPE_VIDEO_AVC, any)
        }
        return null
    }
}
