package com.mirrorcast.engine.stream

import android.content.Context
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.media.MediaCodecInfo
import android.util.DisplayMetrics
import android.view.Display
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

data class VideoSize(val width: Int, val height: Int) {
    override fun toString() = "${width}x$height"
}

/** The phone screen as it is right now (rotation included). */
data class DisplayInfo(val width: Int, val height: Int, val densityDpi: Int)

object ScreenGeometry {

    @Suppress("DEPRECATION") // getRealSize/getRealMetrics are the only APIs usable from a Service.
    fun currentDisplay(context: Context): DisplayInfo {
        val display = context.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
        val size = Point()
        display.getRealSize(size)
        val metrics = DisplayMetrics()
        display.getRealMetrics(metrics)
        return DisplayInfo(size.x, size.y, metrics.densityDpi)
    }

    /**
     * Scales the source so its longer side is at most [maxSize] (0 = native),
     * keeps the aspect ratio, rounds both sides down to a multiple of 16 (what
     * hardware encoders like best) and shrinks further if the encoder can't
     * handle the result.
     */
    fun fit(sourceWidth: Int, sourceHeight: Int, maxSize: Int, caps: MediaCodecInfo.VideoCapabilities?): VideoSize {
        val longSide = max(sourceWidth, sourceHeight)
        var limit = if (maxSize <= 0) longSide else min(maxSize, longSide)
        repeat(10) {
            val size = scale(sourceWidth, sourceHeight, limit)
            if (caps == null || caps.isSizeSupported(size.width, size.height)) return size
            limit = (limit * 0.85).roundToInt()
        }
        return scale(sourceWidth, sourceHeight, min(longSide, 1280))
    }

    /** Highest frame rate <= [requested] that the encoder supports at [size]. */
    fun fitFrameRate(size: VideoSize, requested: Int, caps: MediaCodecInfo.VideoCapabilities?): Int {
        if (caps == null) return requested
        for (fps in listOf(requested, 60, 30).distinct().filter { it <= requested }) {
            try {
                if (caps.areSizeAndRateSupported(size.width, size.height, fps.toDouble())) return fps
            } catch (_: IllegalArgumentException) {
            }
        }
        return min(requested, 30)
    }

    fun fitBitrate(requested: Int, caps: MediaCodecInfo.VideoCapabilities?): Int {
        val range = caps?.bitrateRange ?: return requested
        return requested.coerceIn(range.lower, range.upper)
    }

    private fun scale(width: Int, height: Int, limit: Int): VideoSize {
        val longSide = max(width, height).toDouble()
        val factor = min(1.0, limit / longSide)
        return VideoSize(align(width * factor), align(height * factor))
    }

    private fun align(value: Double): Int = max(16, (value.toInt() / 16) * 16)
}
