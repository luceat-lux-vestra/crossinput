package com.crossinput.helper

import android.content.Context
import android.hardware.display.DisplayManager
import android.util.DisplayMetrics
import java.lang.reflect.InvocationTargetException

/**
 * Bounded capability probe for issue #145.
 *
 * The production bug cannot be fixed honestly from UHID's "report accepted"
 * result because that result does not expose the visible Android cursor's
 * actual display position. Android 16's input service exposes cursor-position
 * Binder methods guarded by INJECT_EVENTS. The helper already runs from the
 * adb-shell/app_process execution model used for input injection, so this
 * probe determines whether that capability is actually available on the
 * target device before any production protocol depends on it.
 *
 * Raw coordinates are never printed. The probe emits only coarse boundary
 * membership (left/right/top/bottom/interior) plus the reflected API variant.
 */
internal class CursorPositionProvider(
    private val inputServiceFactory: () -> Any? = { resolveInputService() },
) {
    data class Sample(
        val x: Float,
        val y: Float,
        val api: String,
    )

    fun query(displayId: Int): Result<Sample> = runCatching {
        val service = inputServiceFactory()
            ?: error("input-service-unavailable")

        val candidates = listOf(
            Candidate("getCursorPositionInLogicalDisplay", intArrayOf(displayId)),
            Candidate("getCursorPosition", intArrayOf(displayId)),
            Candidate("getCursorPosition", intArrayOf()),
        )

        var lastFailure: Throwable? = null
        for (candidate in candidates) {
            val method = try {
                if (candidate.args.isEmpty()) {
                    service.javaClass.getMethod(candidate.name)
                } else {
                    service.javaClass.getMethod(candidate.name, Int::class.javaPrimitiveType)
                }
            } catch (_: NoSuchMethodException) {
                continue
            }

            val point = try {
                if (candidate.args.isEmpty()) {
                    method.invoke(service)
                } else {
                    method.invoke(service, candidate.args[0])
                }
            } catch (t: Throwable) {
                lastFailure = unwrapInvocationTarget(t)
                continue
            } ?: error("cursor-position-unavailable")

            val pointClass = point.javaClass
            val x = pointClass.getField("x").getFloat(point)
            val y = pointClass.getField("y").getFloat(point)
            require(x.isFinite() && y.isFinite()) { "cursor-position-non-finite" }
            return@runCatching Sample(x, y, candidate.signature)
        }

        if (lastFailure != null) throw lastFailure
        error("cursor-position-api-unavailable")
    }

    private data class Candidate(val name: String, val args: IntArray) {
        val signature: String
            get() = if (args.isEmpty()) "$name()" else "$name(int)"
    }

    companion object {
        private fun resolveInputService(): Any? {
            val serviceManager = Class.forName("android.os.ServiceManager")
            val binder = serviceManager
                .getMethod("getService", String::class.java)
                .invoke(null, Context.INPUT_SERVICE)
                ?: return null

            val binderClass = Class.forName("android.os.IBinder")
            val stub = Class.forName("android.hardware.input.IInputManager\$Stub")
            return stub.getMethod("asInterface", binderClass).invoke(null, binder)
        }

        private fun unwrapInvocationTarget(t: Throwable): Throwable {
            return if (t is InvocationTargetException && t.targetException != null) {
                t.targetException
            } else {
                t
            }
        }
    }
}

internal enum class CursorBoundary(val token: String) {
    LEFT("left"),
    RIGHT("right"),
    TOP("top"),
    BOTTOM("bottom"),
}

internal object CursorBoundaryClassifier {
    fun classify(
        x: Float,
        y: Float,
        width: Int,
        height: Int,
        threshold: Float = 16f,
    ): Set<CursorBoundary> {
        require(width > 0 && height > 0)
        require(threshold >= 0f)
        require(x.isFinite() && y.isFinite())

        val maxX = (width - 1).toFloat()
        val maxY = (height - 1).toFloat()
        return buildSet {
            if (x <= threshold) add(CursorBoundary.LEFT)
            if (x >= maxX - threshold) add(CursorBoundary.RIGHT)
            if (y <= threshold) add(CursorBoundary.TOP)
            if (y >= maxY - threshold) add(CursorBoundary.BOTTOM)
        }
    }
}

/**
 * Standalone app_process entry point:
 *
 *   app_process -cp crossinput-helper.apk / \
 *     com.crossinput.helper.CursorPositionProbeMain <display-id>
 *
 * Exit 0 means the Binder capability returned a finite cursor position inside
 * the selected display. Raw x/y are deliberately never emitted.
 */
object CursorPositionProbeMain {
    @JvmStatic
    fun main(args: Array<String>) {
        val displayId = args.singleOrNull()?.toIntOrNull()
        if (displayId == null || displayId < 0) {
            System.err.println("CURSOR_POSITION_PROBE result=FAIL reason=invalid-display-id")
            System.exit(2)
            return
        }

        val context = systemContext()
        if (context == null) {
            System.err.println("CURSOR_POSITION_PROBE result=FAIL reason=system-context-unavailable")
            System.exit(3)
            return
        }

        val displayManager = context.getSystemService(DisplayManager::class.java)
        val display = displayManager?.getDisplay(displayId)
        if (display == null) {
            System.err.println("CURSOR_POSITION_PROBE result=FAIL reason=display-unavailable")
            System.exit(4)
            return
        }

        val metrics = DisplayMetrics()
        display.getRealMetrics(metrics)
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        if (width <= 0 || height <= 0) {
            System.err.println("CURSOR_POSITION_PROBE result=FAIL reason=invalid-display-metrics")
            System.exit(5)
            return
        }

        val result = CursorPositionProvider().query(displayId)
        val sample = result.getOrElse { failure ->
            val reason = when (failure) {
                is SecurityException -> "permission-denied"
                is NoSuchMethodException -> "api-unavailable"
                else -> failure.message?.takeIf { it.matches(Regex("[a-z0-9-]+")) }
                    ?: failure.javaClass.simpleName
            }
            System.err.println("CURSOR_POSITION_PROBE result=FAIL reason=$reason")
            System.exit(6)
            return
        }

        // A display-scoped API returning a point far outside the selected
        // display is not admissible evidence for #145.
        if (sample.x < 0f || sample.y < 0f ||
            sample.x > (width - 1).toFloat() ||
            sample.y > (height - 1).toFloat()
        ) {
            System.err.println(
                "CURSOR_POSITION_PROBE result=FAIL reason=out-of-display-bounds api=${sample.api}",
            )
            System.exit(7)
            return
        }

        val boundaries = CursorBoundaryClassifier.classify(
            sample.x,
            sample.y,
            width,
            height,
        )
        val region = if (boundaries.isEmpty()) {
            "interior"
        } else {
            CursorBoundary.entries
                .filter { it in boundaries }
                .joinToString("+") { it.token }
        }

        println(
            "CURSOR_POSITION_PROBE result=PASS display_id=$displayId " +
                "region=$region api=${sample.api} display=${width}x$height",
        )
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
