package com.mirrorcast.engine.stream

import com.mirrorcast.engine.EngineException
import com.mirrorcast.engine.security.Fingerprint

/** Everything a mirroring session needs, validated once at the boundary with Dart. */
data class StreamSettings(
    /** Addresses to try, in order (a Mac can have several: Wi-Fi, Ethernet, USB loopback). */
    val hosts: List<String>,
    val port: Int,
    /** Fingerprints of Macs we trust. The connection fails unless the Mac matches one. */
    val trustedFingerprints: List<ByteArray>,
    /** Longest video side in pixels, or 0 for native resolution. */
    val maxSize: Int,
    val fps: Int,
    val bitrate: Int,
    /** "auto" (H.265 when possible) or "avc" (always H.264). */
    val codecPreference: String,
    val audioToMac: Boolean,
    val mutePhoneSpeaker: Boolean,
    val deviceName: String,
) {
    companion object {
        fun fromArguments(args: Map<*, *>): StreamSettings {
            val hosts = (args["hosts"] as? List<*>)?.mapNotNull { (it as? String)?.trim()?.takeIf(String::isNotEmpty) }
                ?: emptyList()
            if (hosts.isEmpty() || hosts.size > 16) throw invalid("hosts")
            val port = (args["port"] as? Number)?.toInt() ?: throw invalid("port")
            if (port !in 1..65535) throw invalid("port")

            val fingerprints = (args["trustedFingerprints"] as? List<*>)
                ?.mapNotNull { (it as? String)?.let(Fingerprint::parse) }
                ?: emptyList()
            if (fingerprints.isEmpty()) {
                throw EngineException("not_paired", "Pair with a Mac before mirroring.")
            }

            val maxSize = ((args["maxSize"] as? Number)?.toInt() ?: 1920).let { if (it <= 0) 0 else it.coerceIn(480, 4096) }
            val fps = ((args["fps"] as? Number)?.toInt() ?: 60).coerceIn(15, 120)
            val bitrate = ((args["bitrate"] as? Number)?.toInt() ?: 10_000_000).coerceIn(1_000_000, 80_000_000)
            val codec = (args["codec"] as? String).takeIf { it == "avc" } ?: "auto"
            val audioToMac = (args["audioMode"] as? String ?: "mac") == "mac"
            val mute = args["mutePhoneSpeaker"] as? Boolean ?: true
            val name = (args["deviceName"] as? String)?.trim()?.take(64)?.ifEmpty { null } ?: "Android phone"

            return StreamSettings(hosts, port, fingerprints, maxSize, fps, bitrate, codec, audioToMac, mute, name)
        }

        private fun invalid(field: String) = EngineException("invalid_args", "Invalid or missing \"$field\".")
    }
}
