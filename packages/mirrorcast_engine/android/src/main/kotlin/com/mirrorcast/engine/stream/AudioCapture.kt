package com.mirrorcast.engine.stream

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.os.Process
import android.util.Log

/**
 * Captures what other apps are playing (media, games, unknown) through
 * AudioPlaybackCapture: 48 kHz, 16-bit, stereo PCM in 10 ms chunks.
 *
 * Calls and notifications are not captured, and apps that opt out of capture
 * (some DRM video apps do) stay silent. This is an Android rule.
 */
class AudioCapture(
    private val context: Context,
    private val projection: MediaProjection,
    private val onChunk: (pcm: ByteArray, ptsUs: Long) -> Unit,
    private val onError: (Exception) -> Unit,
) {
    private var record: AudioRecord? = null
    private var thread: Thread? = null

    @Volatile
    private var running = false

    val isRunning: Boolean get() = running

    @SuppressLint("MissingPermission") // checked in hasPermission()
    @Synchronized
    fun start() {
        if (running) return
        if (!hasPermission(context)) throw SecurityException("Audio capture needs the \"Music and audio\" / microphone permission.")

        val config = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        val created = AudioRecord.Builder()
            .setAudioFormat(format)
            .setBufferSizeInBytes(maxOf(minBuffer, CHUNK_BYTES * 4))
            .setAudioPlaybackCaptureConfig(config)
            .build()
        if (created.state != AudioRecord.STATE_INITIALIZED) {
            created.release()
            throw IllegalStateException("Audio capture could not be initialised on this device.")
        }
        created.startRecording()
        record = created
        running = true
        thread = Thread({ readLoop(created) }, "mc-audio-capture").apply { start() }
        Log.i(TAG, "Audio capture started")
    }

    @Synchronized
    fun stop() {
        if (!running && record == null) return
        running = false
        record?.let {
            try {
                it.stop() // unblocks read()
            } catch (_: IllegalStateException) {
            }
        }
        thread?.let {
            try {
                it.join(500)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        thread = null
        record?.release()
        record = null
        Log.i(TAG, "Audio capture stopped")
    }

    private fun readLoop(record: AudioRecord) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val buffer = ByteArray(CHUNK_BYTES)
        try {
            while (running) {
                val read = record.read(buffer, 0, CHUNK_BYTES)
                when {
                    read > 0 -> onChunk(buffer.copyOf(read), System.nanoTime() / 1_000)
                    read == 0 -> continue
                    else -> {
                        if (running) onError(IllegalStateException("AudioRecord.read failed: $read"))
                        return
                    }
                }
            }
        } catch (e: Exception) {
            if (running) onError(e)
        }
    }

    companion object {
        private const val TAG = "MirrorCast/Audio"
        const val SAMPLE_RATE = 48_000

        /** 10 ms of 48 kHz * 2 channels * 2 bytes. */
        const val CHUNK_BYTES = 1_920

        fun hasPermission(context: Context): Boolean =
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    }
}
