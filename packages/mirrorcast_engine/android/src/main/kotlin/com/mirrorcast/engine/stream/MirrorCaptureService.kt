package com.mirrorcast.engine.stream

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import com.mirrorcast.engine.EngineEvents
import com.mirrorcast.engine.EngineException
import com.mirrorcast.engine.R

/**
 * Foreground service that owns the MediaProjection while mirroring.
 *
 * Android requires screen capture to run in a foreground service with a
 * visible notification, so capture keeps working while you use other apps and
 * you can always see (and stop) it from the notification shade.
 */
class MirrorCaptureService : Service() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var session: MirrorSession? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> handleStart(intent)
            ACTION_STOP -> session?.stop() ?: shutdown()
            else -> shutdown() // restarted by the system without a projection: nothing to do
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        session?.stop()
        session = null
        activeSession = null
        super.onDestroy()
    }

    private fun handleStart(intent: Intent) {
        val settings = pendingSettings
        pendingSettings = null
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        val resultData = intent.resultData()

        // startForeground must come before getMediaProjection (Android 14 rule).
        try {
            startForegroundCompat(buildNotification(null))
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed", e)
            EngineEvents.error(EngineException("service_failed", "Android refused to start screen capture: ${e.message}", e))
            shutdown()
            return
        }

        if (settings == null || resultData == null || session != null) {
            shutdown()
            return
        }
        val projection = try {
            getSystemService(MediaProjectionManager::class.java).getMediaProjection(resultCode, resultData)
        } catch (e: Exception) {
            null
        }
        if (projection == null) {
            EngineEvents.error(EngineException("permission_denied", "Screen capture permission is no longer valid. Try again."))
            shutdown()
            return
        }

        val newSession = MirrorSession(
            context = this,
            projection = projection,
            settings = settings,
            onReceiverName = { name -> mainHandler.post { updateNotification(name) } },
            onEnded = { mainHandler.post { shutdown() } },
        )
        session = newSession
        activeSession = newSession
        newSession.start()
    }

    private fun shutdown() {
        session = null
        activeSession = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startForegroundCompat(notification: Notification) {
        var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && AudioCapture.hasPermission(this)) {
            // Lets audio capture keep running while MirrorCast is in the background.
            type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        startForeground(NOTIFICATION_ID, notification, type)
    }

    private fun updateNotification(receiverName: String) {
        if (session == null) return
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification(receiverName))
    }

    private fun buildNotification(receiverName: String?): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Screen mirroring", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while your screen is being mirrored to a Mac"
                    setShowBadge(false)
                },
            )
        }

        val stopIntent = PendingIntent.getService(
            this,
            0,
            Intent(this, MirrorCaptureService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 1, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }

        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.mirrorcast_ic_notification)
            .setContentTitle(if (receiverName == null) "Starting MirrorCast…" else "Mirroring to $receiverName")
            .setContentText("Your screen and audio are being shared securely.")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(openIntent)
            .addAction(Notification.Action.Builder(null, "Stop", stopIntent).build())
            .build()
    }

    @Suppress("DEPRECATION")
    private fun Intent.resultData(): Intent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            getParcelableExtra(EXTRA_RESULT_DATA)
        }

    companion object {
        private const val TAG = "MirrorCast/Service"
        private const val ACTION_START = "com.mirrorcast.engine.action.START"
        private const val ACTION_STOP = "com.mirrorcast.engine.action.STOP"
        private const val EXTRA_RESULT_CODE = "resultCode"
        private const val EXTRA_RESULT_DATA = "resultData"
        private const val CHANNEL_ID = "mirrorcast_mirroring"
        private const val NOTIFICATION_ID = 0x4D43 // "MC"

        /** Settings handed over from the plugin (kept in memory, never in the Intent). */
        @Volatile
        private var pendingSettings: StreamSettings? = null

        @Volatile
        var activeSession: MirrorSession? = null
            private set

        val isRunning: Boolean get() = activeSession != null

        fun start(context: Context, resultCode: Int, resultData: Intent, settings: StreamSettings) {
            pendingSettings = settings
            val intent = Intent(context, MirrorCaptureService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_RESULT_CODE, resultCode)
                .putExtra(EXTRA_RESULT_DATA, resultData)
            context.startForegroundService(intent)
        }

        /** Stops the active session; the service then shuts itself down. */
        fun stop() {
            activeSession?.stop()
        }
    }
}
