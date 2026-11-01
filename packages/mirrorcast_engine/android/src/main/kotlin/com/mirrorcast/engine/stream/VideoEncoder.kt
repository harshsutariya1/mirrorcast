package com.mirrorcast.engine.stream

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.util.Log
import android.view.Surface

/** Receives encoded video. Called on the encoder thread; must not block. */
interface VideoSink {
    fun onVideoConfig(data: ByteArray, ptsUs: Long)
    fun onVideoFrame(data: ByteArray, ptsUs: Long, keyframe: Boolean)
    fun onEncoderError(error: Exception)
}

/**
 * Hardware H.264/H.265 encoder fed directly by a [Surface].
 *
 * The VirtualDisplay renders the screen into [start]'s returned surface on
 * the GPU, so pixels never pass through the CPU. A dedicated thread drains
 * encoded output and hands it to the [VideoSink].
 */
class VideoEncoder(
    private val codec: CodecChoice,
    private val sink: VideoSink,
) {
    private var mediaCodec: MediaCodec? = null
    private var surface: Surface? = null
    private var drainThread: Thread? = null

    @Volatile
    private var running = false

    /** Most recent codec-config buffer (SPS/PPS, +VPS for H.265). */
    @Volatile
    var codecConfig: ByteArray? = null
        private set

    /** Starts encoding at [size] and returns the surface to render into. */
    @Synchronized
    fun start(size: VideoSize, fps: Int, bitrate: Int): Surface {
        check(!running) { "Encoder already running" }
        codecConfig = null

        val created = configureWithFallback(size, fps, bitrate)
        mediaCodec = created
        val inputSurface = created.createInputSurface()
        surface = inputSurface
        created.start()
        running = true

        drainThread = Thread({ drain(created) }, "mc-video-encoder").apply { start() }
        Log.i(TAG, "Encoder started: ${codec.wireName} $size @ ${fps}fps ${bitrate / 1000} kbps (${codec.encoder.name})")
        return inputSurface
    }

    @Synchronized
    fun stop() {
        running = false
        drainThread?.let {
            try {
                it.join(1_000)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        drainThread = null
        mediaCodec?.let { codec ->
            try {
                codec.stop()
            } catch (_: Exception) {
            }
            codec.release()
        }
        mediaCodec = null
        surface?.release()
        surface = null
    }

    /** Asks the encoder for an IDR frame as soon as possible. */
    fun requestKeyframe() {
        val codec = mediaCodec ?: return
        try {
            codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (e: IllegalStateException) {
            Log.w(TAG, "Keyframe request ignored: ${e.message}")
        }
    }

    /** Changes the bitrate without restarting the encoder. */
    fun setBitrate(bitrate: Int) {
        val codec = mediaCodec ?: return
        try {
            codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrate) })
        } catch (_: IllegalStateException) {
        }
    }

    /**
     * Tries the full low-latency configuration first. Some vendor encoders
     * reject optional keys, so fall back to a minimal format if needed.
     */
    private fun configureWithFallback(size: VideoSize, fps: Int, bitrate: Int): MediaCodec {
        var lastError: Exception? = null
        for (lowLatency in listOf(true, false)) {
            val instance = MediaCodec.createByCodecName(codec.encoder.name)
            try {
                instance.configure(buildFormat(size, fps, bitrate, lowLatency), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                return instance
            } catch (e: Exception) {
                Log.w(TAG, "configure(lowLatency=$lowLatency) failed: ${e.message}")
                lastError = e
                instance.release()
            }
        }
        throw IllegalStateException("The video encoder refused every configuration", lastError)
    }

    private fun buildFormat(size: VideoSize, fps: Int, bitrate: Int, lowLatency: Boolean): MediaFormat =
        MediaFormat.createVideoFormat(codec.mime, size.width, size.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            // Keyframes are also produced on demand (reconnects, decoder
            // errors), so a periodic one every 2 s is only a safety net.
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            // When the screen is static, re-send the last frame every 100 ms so
            // the Mac keeps getting data and quality converges.
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000L)
            // B-frames reorder frames and therefore add latency. Never use them.
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            if (lowLatency) {
                setInteger(MediaFormat.KEY_PRIORITY, 0) // 0 = real-time
                // High-refresh screens (90/120 Hz) would otherwise feed more
                // frames than requested.
                setFloat(MediaFormat.KEY_MAX_FPS_TO_ENCODER, fps.toFloat())
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
                if (codec.supportsCbr) {
                    // Constant bitrate keeps frame sizes predictable on Wi-Fi.
                    setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                }
            }
        }

    private fun drain(codec: MediaCodec) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY)
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val index = codec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    // Some encoders never emit a CODEC_CONFIG buffer and only publish the
                    // parameter sets here (csd-0/csd-1). Forward them so the Mac can decode.
                    if (codecConfig == null) {
                        configFromFormat(codec.outputFormat)?.let { config ->
                            codecConfig = config
                            sink.onVideoConfig(config, 0L)
                        }
                    }
                    continue
                }
                if (index < 0) continue // INFO_TRY_AGAIN_LATER: nothing to send yet

                val buffer = codec.getOutputBuffer(index)
                if (buffer != null && info.size > 0) {
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    val data = ByteArray(info.size)
                    buffer.get(data)

                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        codecConfig = data
                        sink.onVideoConfig(data, info.presentationTimeUs)
                    } else {
                        val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                        sink.onVideoFrame(data, info.presentationTimeUs, key)
                    }
                }
                codec.releaseOutputBuffer(index, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
        } catch (e: Exception) {
            // IllegalStateException is expected while stop() tears the codec down.
            if (running) sink.onEncoderError(e)
        }
    }

    /** Joins csd-0/1/2 into one Annex-B buffer (adding start codes where missing). */
    private fun configFromFormat(format: MediaFormat): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        for (key in listOf("csd-0", "csd-1", "csd-2")) {
            val buffer = format.getByteBuffer(key) ?: continue
            val bytes = ByteArray(buffer.remaining())
            buffer.duplicate().get(bytes)
            if (bytes.isEmpty()) continue
            val hasStartCode = bytes.size > 4 &&
                bytes[0].toInt() == 0 && bytes[1].toInt() == 0 &&
                (bytes[2].toInt() == 1 || (bytes[2].toInt() == 0 && bytes[3].toInt() == 1))
            if (!hasStartCode) out.write(byteArrayOf(0, 0, 0, 1))
            out.write(bytes)
        }
        return out.toByteArray().takeIf { it.isNotEmpty() }
    }

    companion object {
        private const val TAG = "MirrorCast/Encoder"
        private const val DEQUEUE_TIMEOUT_US = 100_000L
    }
}
