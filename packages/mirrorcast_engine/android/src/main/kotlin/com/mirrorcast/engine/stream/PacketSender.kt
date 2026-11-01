package com.mirrorcast.engine.stream

import android.os.Process
import com.mirrorcast.engine.protocol.PacketType
import com.mirrorcast.engine.protocol.PacketWriter
import com.mirrorcast.engine.protocol.Wire
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * The single writer for a streaming connection (the spec's "SocketStreamer").
 *
 * Encoder and audio threads drop packets into a queue; one high-priority
 * thread writes them to the TLS socket, so a header and its payload are never
 * interleaved.
 *
 * **Latency control.** TCP never loses data, but on a congested Wi-Fi link it
 * can fall behind. Instead of letting a backlog grow (which would show up as
 * seconds of delay), we drop video once more than [MAX_QUEUED_VIDEO] frames
 * are waiting, ask the encoder for a keyframe, and skip everything until it
 * arrives, because a P-frame is useless without the frames before it. Audio
 * is capped at [MAX_QUEUED_AUDIO] chunks (about 100 ms) for the same reason.
 */
class PacketSender(
    private val writer: PacketWriter,
    private val onFailure: (IOException) -> Unit,
    private val onKeyframeNeeded: () -> Unit,
) {
    private class Outgoing(val type: Int, val payload: ByteArray, val ptsUs: Long, val flags: Int)

    private val queue = LinkedBlockingDeque<Outgoing>()
    private val queuedVideo = AtomicInteger()
    private val queuedAudio = AtomicInteger()

    @Volatile
    private var running = false

    @Volatile
    private var waitingForKeyframe = true

    @Volatile
    private var latestConfig: ByteArray? = null
    private var thread: Thread? = null

    // Counters read by the stats timer.
    val bytesSent = AtomicLong()
    val videoFramesSent = AtomicLong()
    val videoFramesDropped = AtomicLong()

    fun start() {
        running = true
        thread = Thread({ writeLoop() }, "mc-socket-writer").apply { start() }
    }

    fun stop() {
        running = false
        thread?.interrupt()
        thread = null
        queue.clear()
    }

    /** Remembers the codec config so it can be re-sent before every keyframe. */
    fun setCodecConfig(config: ByteArray?) {
        latestConfig = config
    }

    /** Drop video until the next keyframe (used after a format change). */
    fun waitForKeyframe() {
        waitingForKeyframe = true
    }

    fun sendVideoConfig(config: ByteArray, ptsUs: Long) {
        latestConfig = config
        enqueue(Outgoing(PacketType.VIDEO_CONFIG, config, ptsUs, 0))
    }

    fun sendVideoFrame(frame: ByteArray, ptsUs: Long, keyframe: Boolean) {
        if (!running) return
        if (!keyframe) {
            if (waitingForKeyframe) {
                videoFramesDropped.incrementAndGet()
                return
            }
            if (queuedVideo.get() >= MAX_QUEUED_VIDEO) {
                // The link can't keep up: drop until a fresh keyframe.
                waitingForKeyframe = true
                videoFramesDropped.incrementAndGet()
                onKeyframeNeeded()
                return
            }
        } else {
            waitingForKeyframe = false
            // Re-send parameter sets first so the Mac can (re)start decoding
            // from this keyframe no matter what it saw before.
            latestConfig?.let { enqueue(Outgoing(PacketType.VIDEO_CONFIG, it, ptsUs, 0)) }
        }
        queuedVideo.incrementAndGet()
        enqueue(Outgoing(PacketType.VIDEO_FRAME, frame, ptsUs, if (keyframe) Wire.FLAG_KEYFRAME else 0))
    }

    fun sendAudio(pcm: ByteArray, ptsUs: Long) {
        if (!running) return
        if (queuedAudio.get() >= MAX_QUEUED_AUDIO) return // ~100 ms behind: drop rather than lag
        queuedAudio.incrementAndGet()
        enqueue(Outgoing(PacketType.AUDIO_PCM, pcm, ptsUs, 0))
    }

    fun sendControl(type: Int, body: JSONObject = JSONObject()) {
        enqueue(Outgoing(type, body.toString().toByteArray(Charsets.UTF_8), 0, 0))
    }

    /** Jumps the queue. Used for PONG so clock-sync measurements aren't skewed by video backlog. */
    fun sendControlUrgent(type: Int, body: JSONObject) {
        if (!running) return
        queue.offerFirst(Outgoing(type, body.toString().toByteArray(Charsets.UTF_8), 0, 0))
    }

    private fun enqueue(packet: Outgoing) {
        if (running) queue.offerLast(packet)
    }

    private fun writeLoop() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY)
        try {
            while (running) {
                val packet = queue.pollFirst(250, TimeUnit.MILLISECONDS) ?: continue
                when (packet.type) {
                    PacketType.VIDEO_FRAME -> queuedVideo.decrementAndGet()
                    PacketType.AUDIO_PCM -> queuedAudio.decrementAndGet()
                }
                // Batch small packets: only flush when nothing else is waiting.
                writer.write(packet.type, packet.payload, packet.ptsUs, packet.flags, flush = queue.isEmpty())
                bytesSent.addAndGet((Wire.HEADER_SIZE + packet.payload.size).toLong())
                if (packet.type == PacketType.VIDEO_FRAME) videoFramesSent.incrementAndGet()
            }
        } catch (_: InterruptedException) {
            // stop() was called
        } catch (e: IOException) {
            if (running) {
                running = false
                onFailure(e)
            }
        }
    }

    companion object {
        const val MAX_QUEUED_VIDEO = 3
        const val MAX_QUEUED_AUDIO = 10
    }
}
