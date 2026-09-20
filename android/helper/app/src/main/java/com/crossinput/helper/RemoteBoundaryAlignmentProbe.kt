package com.crossinput.helper

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Looper
import android.util.DisplayMetrics
import com.crossinput.helper.protocol.FrameWriter
import java.io.ByteArrayOutputStream

internal enum class RemoteBoundary(val token: String) {
    LEFT("left"),
    RIGHT("right"),
    TOP("top"),
    BOTTOM("bottom");

    companion object {
        fun parse(token: String): RemoteBoundary? =
            entries.firstOrNull { it.token == token.lowercase() }
    }
}

internal object RemoteBoundaryAlignment {
    private const val MIN_RAW_DISTANCE = 8_192
    private const val MULTIPLIER = 16
    private const val MAX_RAW_DISTANCE = 120_000

    fun movement(boundary: RemoteBoundary, width: Int, height: Int): Pair<Int, Int> {
        require(width > 0 && height > 0)
        val axis = when (boundary) {
            RemoteBoundary.LEFT, RemoteBoundary.RIGHT -> width
            RemoteBoundary.TOP, RemoteBoundary.BOTTOM -> height
        }
        val magnitude = maxOf(MIN_RAW_DISTANCE, axis * MULTIPLIER)
            .coerceAtMost(MAX_RAW_DISTANCE)
        return when (boundary) {
            RemoteBoundary.LEFT -> -magnitude to 0
            RemoteBoundary.RIGHT -> magnitude to 0
            RemoteBoundary.TOP -> 0 to -magnitude
            RemoteBoundary.BOTTOM -> 0 to magnitude
        }
    }
}

/**
 * Bounded issue #145 probe using the exact production UHID pointer path.
 * Raw cursor coordinates and report payloads are never emitted.
 */
object RemoteBoundaryAlignmentProbeMain {
    @JvmStatic
    fun main(args: Array<String>) {
        if (Looper.myLooper() == null) Looper.prepare()

        val displayId = args.getOrNull(0)?.toIntOrNull()
        val boundary = args.getOrNull(1)?.let(RemoteBoundary::parse)
        if (displayId == null || displayId < 0 || boundary == null) {
            System.err.println("REMOTE_BOUNDARY_PROBE result=FAIL reason=invalid-arguments")
            System.exit(2)
            return
        }

        val context = systemContext()
        if (context == null) {
            System.err.println("REMOTE_BOUNDARY_PROBE result=FAIL reason=system-context-unavailable")
            System.exit(3)
            return
        }

        val display = context.getSystemService(DisplayManager::class.java)?.getDisplay(displayId)
        if (display == null) {
            System.err.println("REMOTE_BOUNDARY_PROBE result=FAIL reason=display-unavailable")
            System.exit(4)
            return
        }

        val metrics = DisplayMetrics()
        display.getRealMetrics(metrics)
        if (metrics.widthPixels <= 0 || metrics.heightPixels <= 0) {
            System.err.println("REMOTE_BOUNDARY_PROBE result=FAIL reason=invalid-display-metrics")
            System.exit(5)
            return
        }

        val sink = ByteArrayOutputStream()
        val logger = Logger(WriterLock(FrameWriter(sink)))
        val hid = HidDeviceManager(logger, context)
        val pointer = UhidPointerInjector(logger, hid)

        try {
            if (!pointer.selectSystemRoute()) {
                System.err.println("REMOTE_BOUNDARY_PROBE result=FAIL reason=uhid-unavailable")
                System.exit(6)
                return
            }

            val (dx, dy) = RemoteBoundaryAlignment.movement(
                boundary,
                metrics.widthPixels,
                metrics.heightPixels,
            )
            val result = pointer.moveRelative(dx, dy)
            if (result.status != PointerDelivery.Status.DELIVERED ||
                result.deliveredDx != dx ||
                result.deliveredDy != dy
            ) {
                System.err.println(
                    "REMOTE_BOUNDARY_PROBE result=FAIL reason=partial-or-failed-delivery " +
                        "edge=${boundary.token}",
                )
                System.exit(7)
                return
            }

            println(
                "REMOTE_BOUNDARY_PROBE result=PASS display_id=$displayId " +
                    "edge=${boundary.token} display=${metrics.widthPixels}x${metrics.heightPixels}",
            )
        } finally {
            pointer.close()
            hid.destroyAll()
        }
    }

    private fun systemContext(): Context? {
        return try {
            val klass = Class.forName("android.app.ActivityThread")
            val thread = klass.getMethod("systemMain").invoke(null)
            klass.getMethod("getSystemContext").invoke(thread) as Context
        } catch (_: Throwable) {
            null
        }
    }
}
