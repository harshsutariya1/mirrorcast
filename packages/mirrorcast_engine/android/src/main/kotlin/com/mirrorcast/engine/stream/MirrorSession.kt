package com.mirrorcast.engine.stream

import android.content.Context
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.os.SystemClock
import android.util.Log
import android.view.Display
import com.mirrorcast.engine.EngineEvents
import com.mirrorcast.engine.EngineException
import com.mirrorcast.engine.protocol.PacketType
import com.mirrorcast.engine.protocol.ProtocolException
import com.mirrorcast.engine.protocol.RejectCode
import com.mirrorcast.engine.protocol.SessionIntent
import com.mirrorcast.engine.protocol.Wire
import com.mirrorcast.engine.security.DeviceIdentity
import com.mirrorcast.engine.security.SecureChannel
import com.mirrorcast.engine.security.TlsConnector
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * One mirroring session, from "connect" to "stopped".
 *
 * Threads:
 *  - **mc-network** connects, performs the handshake, reads control packets
 *    from the Mac, and reconnects if Wi-Fi drops for a moment.
 *  - **mc-session** (a Handler thread) owns the capture pipeline: encoder,
 *    VirtualDisplay, audio capture, rotation handling and stats. Everything
 *    that mutates the pipeline is posted here so it never races.
 *  - The encoder, audio and socket-writer threads are owned by their classes.
 */
class MirrorSession(
    private val context: Context,
    private val projection: MediaProjection,
    private val settings: StreamSettings,
    private val onReceiverName: (String) -> Unit,
    private val onEnded: () -> Unit,
) : VideoSink {

    private val connector = TlsConnector(DeviceIdentity.get())
    private val workerThread = HandlerThread("mc-session", Process.THREAD_PRIORITY_DISPLAY).apply { start() }
    private val worker = Handler(workerThread.looper)
    private val muter = PhoneSpeakerMuter(context)

    @Volatile private var stopped = false
    @Volatile private var endedByReceiver = false
    @Volatile private var fatalError: EngineException? = null
    @Volatile private var channel: SecureChannel? = null
    @Volatile private var sender: PacketSender? = null
    @Volatile private var codec: CodecChoice? = null
    @Volatile private var encoder: VideoEncoder? = null
    @Volatile private var receiverStats: JSONObject? = null
    @Volatile private var mutePhoneSpeaker = settings.mutePhoneSpeaker
    @Volatile private var receiverName = "Mac"
    @Volatile private var connectedHost = ""

    // Owned by the mc-session thread.
    private var virtualDisplay: VirtualDisplay? = null
    private var audio: AudioCapture? = null
    private var videoSize: VideoSize? = null
    private var capturedContentSize: VideoSize? = null
    private var fps = settings.fps
    private var bitrate = settings.bitrate
    private var startedAtMs = 0L
    private var statsSender: PacketSender? = null
    private var lastBytes = 0L
    private var lastFrames = 0L

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            // The user tapped "Stop sharing" in the system UI, or another app took over.
            Log.i(TAG, "MediaProjection stopped by the system")
            stop()
        }

        override fun onCapturedContentResize(width: Int, height: Int) {
            // Android 14+: user chose to share a single app whose window changed size.
            worker.post {
                capturedContentSize = if (width > 0 && height > 0) VideoSize(width, height) else null
                reconfigureIfNeeded()
            }
        }
    }

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = Unit
        override fun onDisplayRemoved(displayId: Int) = Unit
        override fun onDisplayChanged(displayId: Int) {
            if (displayId == Display.DEFAULT_DISPLAY) reconfigureIfNeeded() // rotation
        }
    }

    private val statsTick = object : Runnable {
        override fun run() {
            emitStats()
            worker.postDelayed(this, STATS_INTERVAL_MS)
        }
    }

    // ---------------------------------------------------------------- public

    fun start() {
        projection.registerCallback(projectionCallback, worker)
        EngineEvents.state("connecting")
        Thread({ runNetwork() }, "mc-network").start()
    }

    /** Stops everything. Safe to call more than once and from any thread. */
    fun stop() {
        if (stopped) return
        stopped = true
        val open = channel
        // Network I/O is not allowed on the main thread, so say goodbye on a helper thread.
        Thread({
            try {
                open?.writer?.writeControl(PacketType.BYE, JSONObject().put("reason", "user"))
            } catch (_: Exception) {
            }
            open?.close() // unblocks the reader on mc-network
        }, "mc-bye").start()
    }

    /** Switches audio between the phone speaker / earbuds and the Mac, mid-stream. */
    fun setAudioRoute(toMac: Boolean, mutePhone: Boolean) {
        worker.post {
            mutePhoneSpeaker = mutePhone
            applyAudioRoute(toMac)
        }
    }

    // ------------------------------------------------------------ networking

    private fun runNetwork() {
        var error: EngineException? = null
        var current: SecureChannel? = null
        try {
            var active = connect()
            current = active
            var first = true
            while (!stopped) {
                attach(active, first)
                first = false
                try {
                    readLoop(active)
                } catch (e: EngineException) {
                    throw e // a REJECT from the Mac (for example: this phone was revoked)
                } catch (e: IOException) {
                    if (!stopped && !endedByReceiver) Log.w(TAG, "Connection lost: ${e.message}")
                }
                detach(active)
                if (stopped || endedByReceiver) break
                active = reconnect() ?: throw EngineException("disconnected", "Lost the connection to the Mac.")
                current = active
            }
        } catch (e: Exception) {
            if (!stopped) error = EngineException.from(e)
        } finally {
            current?.close() // covers stop() arriving while we were still connecting
            shutdown(fatalError ?: error)
        }
    }

    private fun connect(): SecureChannel {
        var lastError: Exception? = null
        for (host in settings.hosts) {
            if (stopped) break
            val opened = try {
                connector.connect(host, settings.port, settings.trustedFingerprints)
            } catch (e: Exception) {
                val mapped = EngineException.from(e)
                if (mapped.code == "untrusted_receiver") throw mapped
                lastError = e
                continue
            }
            try {
                handshake(opened)
                connectedHost = host
                return opened
            } catch (e: Exception) {
                opened.close()
                throw e
            }
        }
        throw lastError ?: EngineException("unreachable", "Couldn't reach the Mac.")
    }

    private fun handshake(open: SecureChannel) {
        open.readTimeoutMs = TlsConnector.HANDSHAKE_TIMEOUT_MS
        val hello = JSONObject()
            .put("protocol", Wire.PROTOCOL_VERSION)
            .put("intent", SessionIntent.STREAM)
            .put("deviceName", settings.deviceName)
            .put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
            .put("codecs", JSONArray(CodecSupport.localEncoders()))
        open.writer.writeControl(PacketType.HELLO, hello)

        val reply = open.reader.read()
        if (reply.type == PacketType.REJECT) throw EngineException.fromReject(reply.json())
        if (reply.type != PacketType.WELCOME) throw ProtocolException("Expected WELCOME")
        val body = reply.json()
        receiverName = body.optString("receiverName", "Mac").take(64)
        val decoders = body.optJSONArray("decoders")?.let { array ->
            (0 until array.length()).map { array.optString(it) }
        } ?: listOf(CodecSupport.AVC)
        if (codec == null) {
            codec = CodecSupport.choose(settings.codecPreference, decoders)
                ?: throw EngineException("no_codec", "No video codec is supported by both devices.")
        }
        // The Mac pings every second, so a silent socket for this long is dead.
        open.readTimeoutMs = READ_TIMEOUT_MS
    }

    /** Retries for a short while after Wi-Fi hiccups. The capture keeps running meanwhile. */
    private fun reconnect(): SecureChannel? {
        EngineEvents.state("reconnecting", mapOf("receiverName" to receiverName))
        val deadline = SystemClock.elapsedRealtime() + RECONNECT_WINDOW_MS
        while (!stopped && SystemClock.elapsedRealtime() < deadline) {
            try {
                Thread.sleep(RECONNECT_DELAY_MS)
            } catch (_: InterruptedException) {
                return null
            }
            try {
                return connect()
            } catch (e: EngineException) {
                if (e.code in FINAL_ERRORS) throw e
            } catch (_: Exception) {
            }
        }
        return null
    }

    private fun attach(open: SecureChannel, first: Boolean) {
        channel = open
        val packetSender = PacketSender(
            writer = open.writer,
            onFailure = { open.close() }, // the reader then fails and triggers reconnect
            onKeyframeNeeded = { worker.post { encoder?.requestKeyframe() } },
        )
        packetSender.setCodecConfig(encoder?.codecConfig)
        packetSender.start()
        sender = packetSender
        onReceiverName(receiverName)

        worker.post {
            try {
                if (first) {
                    startPipelines()
                    worker.postDelayed(statsTick, STATS_INTERVAL_MS)
                } else {
                    sendVideoFormat()
                    sendAudioState()
                    encoder?.requestKeyframe()
                }
                emitStreaming()
            } catch (e: Exception) {
                Log.e(TAG, "Pipeline failed to start", e)
                fatalError = EngineException("capture_failed", "Couldn't start screen capture: ${e.message}", e)
                stop()
            }
        }
    }

    private fun detach(open: SecureChannel) {
        sender?.stop()
        sender = null
        open.close()
        channel = null
    }

    private fun readLoop(open: SecureChannel) {
        while (!stopped) {
            val packet = open.reader.read()
            when (packet.type) {
                PacketType.PING -> {
                    // Echo the Mac's timestamp together with our monotonic clock.
                    // The Mac uses this to estimate RTT and the clock offset.
                    val pong = JSONObject()
                        .put("t", packet.json().optLong("t"))
                        .put("p", System.nanoTime() / 1_000)
                    sender?.sendControlUrgent(PacketType.PONG, pong)
                }
                PacketType.KEYFRAME_REQUEST -> worker.post { encoder?.requestKeyframe() }
                PacketType.RECEIVER_STATS -> receiverStats = packet.json()
                PacketType.BYE -> {
                    endedByReceiver = true
                    return
                }
                PacketType.REJECT -> throw EngineException.fromReject(packet.json())
                else -> Unit // ignore anything else; the Mac is trusted but we stay strict
            }
        }
    }

    private fun shutdown(error: EngineException?) {
        sender?.stop()
        sender = null
        channel?.close()
        channel = null

        val done = CountDownLatch(1)
        worker.post {
            teardownPipelines()
            done.countDown()
        }
        try {
            done.await(3, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
        }
        workerThread.quitSafely()
        try {
            projection.unregisterCallback(projectionCallback)
        } catch (_: Exception) {
        }
        stopped = true
        projection.stop()

        when {
            error != null -> EngineEvents.error(error)
            endedByReceiver -> EngineEvents.state("idle", mapOf("reason" to "receiver_closed"))
            else -> EngineEvents.state("idle", mapOf("reason" to "stopped"))
        }
        onEnded()
    }

    // -------------------------------------------------------------- pipeline

    private fun startPipelines() {
        val chosen = codec ?: throw IllegalStateException("No codec")
        val display = ScreenGeometry.currentDisplay(context)
        val caps = chosen.capabilities
        val size = computeSize(display)
        fps = ScreenGeometry.fitFrameRate(size, settings.fps, caps)
        bitrate = ScreenGeometry.fitBitrate(settings.bitrate, caps)

        val videoEncoder = VideoEncoder(chosen, this)
        videoSize = size
        sendVideoFormat()
        val surface = videoEncoder.start(size, fps, bitrate)
        encoder = videoEncoder

        virtualDisplay = projection.createVirtualDisplay(
            "MirrorCast",
            size.width,
            size.height,
            display.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            surface,
            null,
            worker,
        )
        context.getSystemService(DisplayManager::class.java).registerDisplayListener(displayListener, worker)
        startedAtMs = SystemClock.elapsedRealtime()

        if (settings.audioToMac) applyAudioRoute(true) else sendAudioState()
    }

    private fun computeSize(display: DisplayInfo): VideoSize {
        val source = capturedContentSize ?: VideoSize(display.width, display.height)
        return ScreenGeometry.fit(source.width, source.height, settings.maxSize, codec?.capabilities)
    }

    /** Restarts the encoder at a new size after rotation (or an app-window resize). */
    private fun reconfigureIfNeeded() {
        val videoEncoder = encoder ?: return
        val display = virtualDisplay ?: return
        val chosen = codec ?: return
        val info = ScreenGeometry.currentDisplay(context)
        val newSize = computeSize(info)
        if (newSize == videoSize) return

        Log.i(TAG, "Resizing stream $videoSize -> $newSize")
        try {
            display.surface = null
            videoEncoder.stop()
            videoSize = newSize
            fps = ScreenGeometry.fitFrameRate(newSize, settings.fps, chosen.capabilities)
            sender?.waitForKeyframe()
            sendVideoFormat()
            val surface = videoEncoder.start(newSize, fps, bitrate)
            display.resize(newSize.width, newSize.height, info.densityDpi)
            display.surface = surface
            emitStreaming()
        } catch (e: Exception) {
            Log.e(TAG, "Resize failed", e)
            fatalError = EngineException("capture_failed", "Couldn't resize the stream: ${e.message}", e)
            stop()
        }
    }

    private fun applyAudioRoute(toMac: Boolean) {
        if (toMac) {
            if (audio?.isRunning != true) {
                val capture = AudioCapture(
                    context,
                    projection,
                    onChunk = { pcm, pts -> sender?.sendAudio(pcm, pts) },
                    onError = { e -> worker.post { audioFailed(e) } },
                )
                try {
                    capture.start()
                } catch (e: Exception) {
                    audioFailed(e)
                    return
                }
                audio = capture
            }
            if (mutePhoneSpeaker) muter.mute() else muter.restore()
        } else {
            audio?.stop()
            audio = null
            muter.restore()
        }
        sendAudioState()
        emitStreaming()
    }

    private fun audioFailed(error: Exception) {
        Log.w(TAG, "Audio capture unavailable: ${error.message}")
        audio?.stop()
        audio = null
        muter.restore()
        EngineEvents.emit(
            mapOf(
                "type" to "warning",
                "code" to "audio_unavailable",
                "message" to (error.message ?: "Audio capture isn't available. Audio stays on the phone."),
            ),
        )
        sendAudioState()
        emitStreaming()
    }

    private fun teardownPipelines() {
        worker.removeCallbacks(statsTick)
        try {
            context.getSystemService(DisplayManager::class.java).unregisterDisplayListener(displayListener)
        } catch (_: Exception) {
        }
        virtualDisplay?.release()
        virtualDisplay = null
        encoder?.stop()
        encoder = null
        audio?.stop()
        audio = null
        muter.restore()
    }

    private fun sendVideoFormat() {
        val size = videoSize ?: return
        val chosen = codec ?: return
        sender?.sendControl(
            PacketType.VIDEO_FORMAT,
            JSONObject()
                .put("codec", chosen.wireName)
                .put("width", size.width)
                .put("height", size.height)
                .put("fps", fps)
                .put("bitrate", bitrate),
        )
    }

    private fun sendAudioState() {
        sender?.sendControl(PacketType.AUDIO_STATE, JSONObject().put("enabled", audio?.isRunning == true))
    }

    // ---------------------------------------------------------------- events

    private fun emitStreaming() {
        val size = videoSize
        EngineEvents.state(
            "streaming",
            mapOf(
                "receiverName" to receiverName,
                "host" to connectedHost,
                "codec" to codec?.wireName,
                "width" to size?.width,
                "height" to size?.height,
                "fps" to fps,
                "bitrate" to bitrate,
                "audioMode" to if (audio?.isRunning == true) "mac" else "phone",
                "mutePhoneSpeaker" to mutePhoneSpeaker,
            ),
        )
    }

    private fun emitStats() {
        val current = sender
        if (current !== statsSender) {
            statsSender = current
            lastBytes = 0
            lastFrames = 0
        }
        val bytes = current?.bytesSent?.get() ?: 0L
        val frames = current?.videoFramesSent?.get() ?: 0L
        val bitrateKbps = (bytes - lastBytes) * 8 / 1000.0 * (1000.0 / STATS_INTERVAL_MS)
        val sentFps = (frames - lastFrames) * (1000.0 / STATS_INTERVAL_MS)
        lastBytes = bytes
        lastFrames = frames

        val remote = receiverStats
        EngineEvents.emit(
            mapOf(
                "type" to "stats",
                "sentFps" to sentFps,
                "bitrateKbps" to bitrateKbps,
                "droppedFrames" to (current?.videoFramesDropped?.get() ?: 0L),
                "latencyMs" to remote.number("latencyMs"),
                "receiverFps" to remote.number("fps"),
                "rttMs" to remote.number("rttMs"),
                "uptimeSec" to if (startedAtMs == 0L) 0 else (SystemClock.elapsedRealtime() - startedAtMs) / 1000,
            ),
        )
    }

    private fun JSONObject?.number(key: String): Double? {
        val value = this?.optDouble(key, Double.NaN) ?: return null
        return if (value.isNaN()) null else value
    }

    // --------------------------------------------------------- VideoSink impl

    override fun onVideoConfig(data: ByteArray, ptsUs: Long) {
        sender?.sendVideoConfig(data, ptsUs)
    }

    override fun onVideoFrame(data: ByteArray, ptsUs: Long, keyframe: Boolean) {
        sender?.sendVideoFrame(data, ptsUs, keyframe)
    }

    override fun onEncoderError(error: Exception) {
        Log.e(TAG, "Encoder failed", error)
        fatalError = EngineException("encoder_failed", "The video encoder stopped unexpectedly.", error)
        stop()
    }

    private companion object {
        const val TAG = "MirrorCast/Session"
        const val READ_TIMEOUT_MS = 15_000
        const val RECONNECT_WINDOW_MS = 20_000L
        const val RECONNECT_DELAY_MS = 1_000L
        const val STATS_INTERVAL_MS = 1_000L
        val FINAL_ERRORS = setOf("untrusted_receiver", RejectCode.NOT_PAIRED, RejectCode.BUSY, RejectCode.VERSION)
    }
}
