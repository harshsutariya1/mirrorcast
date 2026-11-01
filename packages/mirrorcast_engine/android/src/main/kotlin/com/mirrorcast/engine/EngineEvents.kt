package com.mirrorcast.engine

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * The one-way pipe from native code to Dart (`com.mirrorcast/events`).
 *
 * Events are small maps such as `{"type": "state", "state": "streaming"}`.
 * Anything can call [emit] from any thread; delivery happens on the main
 * thread as Flutter requires. The latest "state" event is replayed to new
 * listeners so the UI is correct after a hot restart or when the app returns
 * from the background.
 */
object EngineEvents : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var lastState: Map<String, Any?> = mapOf("type" to "state", "state" to "idle")

    fun emit(event: Map<String, Any?>) {
        mainHandler.post {
            if (event["type"] == "state") lastState = event
            sink?.success(event)
        }
    }

    fun state(state: String, extra: Map<String, Any?> = emptyMap()) {
        emit(mapOf("type" to "state", "state" to state) + extra)
    }

    fun error(error: EngineException) {
        state("error", mapOf("code" to error.code, "message" to error.message))
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        events?.success(lastState)
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }
}
