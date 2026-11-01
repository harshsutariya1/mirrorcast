package com.mirrorcast.engine

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaFormat
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.mirrorcast.engine.pairing.PairingClient
import com.mirrorcast.engine.pairing.PairingResult
import com.mirrorcast.engine.security.DeviceIdentity
import com.mirrorcast.engine.stream.CodecSupport
import com.mirrorcast.engine.stream.MirrorCaptureService
import com.mirrorcast.engine.stream.ScreenGeometry
import com.mirrorcast.engine.stream.StreamSettings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Entry point of the Android engine: the bridge between Dart (control plane)
 * and the native data plane.
 *
 * Method channel `com.mirrorcast/control`:
 *  - `getDeviceInfo()` -> name, model, fingerprint, codec support
 *  - `pairWithPin({host, port, pin, deviceName})` -> pairing result
 *  - `pairWithQr({hosts, port, fingerprint, secret, deviceName})` -> pairing result
 *  - `startMirroring({...StreamSettings})` -> asks for permissions, then starts the service
 *  - `stopMirroring()`
 *  - `setAudioRouting({audioMode: "mac"|"phone", mutePhoneSpeaker})`
 *
 * Event channel `com.mirrorcast/events`: see [EngineEvents].
 *
 * No video or audio bytes ever cross this bridge.
 */
class MirrorcastEnginePlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {

    private class PendingStart(val settings: StreamSettings, val result: MethodChannel.Result)

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var appContext: Context
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingStart: PendingStart? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    // Pairing and identity work is blocking I/O: run it off the main thread, one at a time.
    private val background: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "mc-plugin-worker")
    }

    // --------------------------------------------------------- FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "com.mirrorcast/control")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "com.mirrorcast/events")
        eventChannel.setStreamHandler(EngineEvents)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        // Mirroring deliberately keeps running in its service; only the UI went away.
    }

    // ---------------------------------------------------------- ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
    }

    // ------------------------------------------------------- method handling

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val args = (call.arguments as? Map<*, *>) ?: emptyMap<Any, Any>()
        try {
            when (call.method) {
                "getDeviceInfo" -> runInBackground(result) { deviceInfo() }
                "pairWithPin" -> {
                    val host = args.string("host")
                    val port = args.port()
                    val pin = args.string("pin")
                    val name = args.deviceName()
                    runInBackground(result) { PairingClient(DeviceIdentity.get(), name).pairWithPin(host, port, pin).toMap() }
                }
                "pairWithQr" -> {
                    val hosts = (args["hosts"] as? List<*>)?.filterIsInstance<String>()?.take(16) ?: emptyList()
                    val port = args.port()
                    val fingerprint = args.string("fingerprint")
                    val secret = args["secret"] as? ByteArray ?: throw invalid("secret")
                    val name = args.deviceName()
                    runInBackground(result) {
                        PairingClient(DeviceIdentity.get(), name).pairWithQr(hosts, port, fingerprint, secret).toMap()
                    }
                }
                "startMirroring" -> startMirroring(StreamSettings.fromArguments(args), result)
                "stopMirroring" -> {
                    MirrorCaptureService.stop()
                    result.success(null)
                }
                "setAudioRouting" -> {
                    val toMac = args["audioMode"] == "mac"
                    val mute = args["mutePhoneSpeaker"] as? Boolean ?: true
                    MirrorCaptureService.activeSession?.setAudioRoute(toMac, mute)
                    result.success(null)
                }
                "isMirroring" -> result.success(MirrorCaptureService.isRunning)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            val error = EngineException.from(e)
            result.error(error.code, error.message, null)
        }
    }

    private fun deviceInfo(): Map<String, Any?> {
        val identity = DeviceIdentity.get()
        val display = ScreenGeometry.currentDisplay(appContext)
        val name = Settings.Global.getString(appContext.contentResolver, Settings.Global.DEVICE_NAME)
            ?.takeIf { it.isNotBlank() } ?: Build.MODEL
        return mapOf(
            "deviceName" to name,
            "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "sdkInt" to Build.VERSION.SDK_INT,
            "fingerprint" to identity.fingerprint,
            "hevcEncoder" to (CodecSupport.hardwareEncoder(MediaFormat.MIMETYPE_VIDEO_HEVC) != null),
            "screenWidth" to display.width,
            "screenHeight" to display.height,
            "isMirroring" to MirrorCaptureService.isRunning,
        )
    }

    // ------------------------------------------------------ start mirroring

    private fun startMirroring(settings: StreamSettings, result: MethodChannel.Result) {
        if (MirrorCaptureService.isRunning) {
            result.error("already_running", "Mirroring is already running.", null)
            return
        }
        if (pendingStart != null) {
            result.error("busy", "Already waiting for permission.", null)
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error("no_activity", "Open MirrorCast to start mirroring.", null)
            return
        }

        pendingStart = PendingStart(settings, result)
        val missing = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !granted(Manifest.permission.POST_NOTIFICATIONS)) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
            if (!granted(Manifest.permission.RECORD_AUDIO)) add(Manifest.permission.RECORD_AUDIO)
        }
        if (missing.isEmpty()) {
            requestProjection(activity)
        } else {
            // Either answer is fine: without these we still mirror, just without
            // the notification or without audio.
            activity.requestPermissions(missing.toTypedArray(), REQUEST_PERMISSIONS)
        }
    }

    private fun requestProjection(activity: Activity) {
        val manager = appContext.getSystemService(MediaProjectionManager::class.java)
        try {
            activity.startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_PROJECTION)
        } catch (e: Exception) {
            finishPending { it.result.error("projection_unavailable", "Screen capture isn't available: ${e.message}", null) }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_PERMISSIONS) return false
        val activity = activityBinding?.activity
        if (activity == null) {
            finishPending { it.result.error("no_activity", "MirrorCast was closed.", null) }
        } else {
            requestProjection(activity)
        }
        return true
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PROJECTION) return false
        finishPending { pending ->
            if (resultCode == Activity.RESULT_OK && data != null) {
                MirrorCaptureService.start(appContext, resultCode, data, pending.settings)
                pending.result.success(true)
            } else {
                pending.result.error("permission_denied", "Screen capture was not allowed.", null)
            }
        }
        return true
    }

    private fun finishPending(block: (PendingStart) -> Unit) {
        val pending = pendingStart ?: return
        pendingStart = null
        block(pending)
    }

    // --------------------------------------------------------------- helpers

    private fun runInBackground(result: MethodChannel.Result, work: () -> Any?) {
        background.execute {
            try {
                val value = work()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                val error = EngineException.from(e)
                mainHandler.post { result.error(error.code, error.message, null) }
            }
        }
    }

    private fun granted(permission: String) =
        appContext.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun PairingResult.toMap(): Map<String, Any> = mapOf(
        "receiverName" to receiverName,
        "fingerprint" to fingerprint,
        "host" to host,
        "port" to port,
    )

    private fun Map<*, *>.string(key: String): String =
        (this[key] as? String)?.trim()?.takeIf { it.isNotEmpty() && it.length <= 256 } ?: throw invalid(key)

    private fun Map<*, *>.port(): Int =
        (this["port"] as? Number)?.toInt()?.takeIf { it in 1..65535 } ?: throw invalid("port")

    private fun Map<*, *>.deviceName(): String =
        (this["deviceName"] as? String)?.trim()?.take(PairingClient.MAX_NAME_LENGTH)?.ifEmpty { null } ?: Build.MODEL

    private fun invalid(field: String) = EngineException("invalid_args", "Invalid or missing \"$field\".")

    private companion object {
        const val REQUEST_PROJECTION = 0x4D01
        const val REQUEST_PERMISSIONS = 0x4D02
    }
}
