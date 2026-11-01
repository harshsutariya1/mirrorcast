package com.mirrorcast.engine.stream

import android.content.Context
import android.media.AudioManager
import android.util.Log

/**
 * Mutes the phone's media stream while audio plays on the Mac, and restores
 * it afterwards. It only unmutes what it muted itself, so a phone you had
 * already muted stays muted.
 */
class PhoneSpeakerMuter(context: Context) {
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private var mutedByUs = false

    @Synchronized
    fun mute() {
        if (mutedByUs) return
        try {
            if (!audioManager.isStreamMute(AudioManager.STREAM_MUSIC)) {
                audioManager.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)
                mutedByUs = true
            }
        } catch (e: SecurityException) {
            // Do Not Disturb policies can forbid volume changes; not fatal.
            Log.w(TAG, "Could not mute phone speaker: ${e.message}")
        }
    }

    @Synchronized
    fun restore() {
        if (!mutedByUs) return
        try {
            audioManager.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)
        } catch (e: SecurityException) {
            Log.w(TAG, "Could not unmute phone speaker: ${e.message}")
        }
        mutedByUs = false
    }

    private companion object {
        const val TAG = "MirrorCast/Muter"
    }
}
