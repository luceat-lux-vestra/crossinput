package com.crossinput.helper

import android.content.Context
import android.hardware.input.InputManager
import android.view.Display
import android.view.InputDevice
import android.view.InputEvent
import android.view.MotionEvent
import java.lang.reflect.Method

/** Semantic pointer boundary consumed by the CXI dispatcher. */
data class PointerDelivery(
    val status: Status,
    val deliveredDx: Int = 0,
    val deliveredDy: Int = 0,
) {
    enum class Status {
        DELIVERED,
        FAILED,
        PARTIALLY_DELIVERED,
    }

    companion object {
        /** The complete semantic event was accepted by the selected backend. */
        val DELIVERED = PointerDelivery(Status.DELIVERED)

        /** No part of the event was accepted; a dispatcher may retry. */
        val FAILED = PointerDelivery(Status.FAILED)

        /** A multi-report event was partly accepted; retrying would duplicate movement. */
        val PARTIALLY_DELIVERED = PointerDelivery(Status.PARTIALLY_DELIVERED)

        fun deliveredMovement(dx: Int, dy: Int): PointerDelivery =
            PointerDelivery(Status.DELIVERED, deliveredDx = dx, deliveredDy = dy)

        fun partiallyDeliveredMovement(dx: Int, dy: Int): PointerDelivery =
            PointerDelivery(Status.PARTIALLY_DELIVERED, deliveredDx = dx, deliveredDy = dy)
    }
}

interface PointerInjector {
    /** Whether this backend can honor the selected display explicitly. */
    val routing: PointerRouting
        get() = PointerRouting.SYSTEM_ROUTED

    val supportsExplicitDisplayRouting: Boolean
        get() = routing == PointerRouting.EXPLICIT_DISPLAY

    fun selectDisplay(display: Display): Boolean
    fun refreshMetrics(displayId: Int)
    fun moveRelative(dx: Int, dy: Int): PointerDelivery
    fun button(button: Int, down: Boolean): PointerDelivery
    fun scroll(horizontal: Float, vertical: Float): PointerDelivery
    fun close()
}

enum class PointerRouting {
    SYSTEM_ROUTED,
    EXPLICIT_DISPLAY,
    UNAVAILABLE,
}

/**
 * Input backend that injects pointer events via InputManager.injectInputEvent()
 * with display ID targeting (scrcpy-style SDK injection).
 * Works on Android 10+ with secondary display support.
 *
 * injectInputEvent and setDisplayId are hidden in the current public SDK
 * (android.jar), so they are invoked via reflection wrappers, exactly like
 * scrcpy's server does.
 */
class InputManagerPointerInjector(
    private val log: Logger,
    private val context: Context,
) : PointerInjector {
    override val routing: PointerRouting
        get() = if (setDisplayIdMethod != null) {
            PointerRouting.EXPLICIT_DISPLAY
        } else {
            PointerRouting.UNAVAILABLE
        }
    private val inputManager: InputManager = context.getSystemService(Context.INPUT_SERVICE) as InputManager
    private var selectedDisplayId: Int = -1
    private var selectedDisplay: Display? = null
    private var displayWidth: Int = 0
    private var displayHeight: Int = 0
    private var currentX: Float = 0f
    private var currentY: Float = 0f
    private var initialized = false

    // Current pressed-button mask (MotionEvent.BUTTON_*), scrcpy-style
    private var buttons: Int = 0

    private companion object {
        // Same value as the hidden InputManager.INJECT_INPUT_EVENT_MODE_ASYNC
        private const val INJECT_INPUT_EVENT_MODE_ASYNC = 0

        private val injectInputEventMethod: Method? = try {
            InputManager::class.java.getMethod("injectInputEvent", InputEvent::class.java, Int::class.java)
        } catch (_: Throwable) {
            null
        }

        // Reflection for MotionEvent.setDisplayId (added in API 28)
        private val setDisplayIdMethod: Method? = try {
            MotionEvent::class.java.getMethod("setDisplayId", Int::class.java)
        } catch (_: Throwable) {
            null
        }
    }

    override fun selectDisplay(display: Display): Boolean {
        if (setDisplayIdMethod == null) {
            log.error("InputManagerPointerInjector", "explicit display routing API unavailable")
            initialized = false
            return false
        }
        selectedDisplayId = display.displayId
        selectedDisplay = display
        initialized = true

        val metrics = android.util.DisplayMetrics()
        display.getRealMetrics(metrics)
        displayWidth = metrics.widthPixels
        displayHeight = metrics.heightPixels
        currentX = displayWidth / 2f
        currentY = displayHeight / 2f

        // Display.state is unreliable on Samsung DeX (reports OFF while the
        // external screen is rendering), so an OFF state only logs a warning.
        if (display.state != Display.STATE_ON) {
            log.warn(
                "InputManagerPointerInjector",
                "display $selectedDisplayId state=${display.state} is not ON; " +
                    "still selecting it (DeX reports stale OFF states)",
            )
        }
        log.info("InputManagerPointerInjector", "selected target $selectedDisplayId (${displayWidth}x$displayHeight)")
        return true
    }

    /**
     * Re-reads the display size when the selected display reports a change
     * (e.g. the external monitor resolution changed mid-session). Keeps the
     * clamp bounds in sync so pointer coordinates stay inside the new size.
     */
    override fun refreshMetrics(displayId: Int) {
        if (displayId != selectedDisplayId || !initialized) return
        val display = selectedDisplay ?: return
        val metrics = android.util.DisplayMetrics()
        display.getRealMetrics(metrics)
        if (metrics.widthPixels == displayWidth && metrics.heightPixels == displayHeight) return
        displayWidth = metrics.widthPixels
        displayHeight = metrics.heightPixels
        currentX = currentX.coerceIn(0f, displayWidth - 1f)
        currentY = currentY.coerceIn(0f, displayHeight - 1f)
        log.info(
            "InputManagerPointerInjector",
            "display $displayId size changed to ${displayWidth}x$displayHeight; re-clamped cursor",
        )
    }

    override fun moveRelative(dx: Int, dy: Int): PointerDelivery {
        if (!initialized || displayWidth == 0) {
            log.warn("InputManagerPointerInjector", "moveRelative called before target selected")
            return PointerDelivery.FAILED
        }

        val nextX = (currentX + dx).coerceIn(0f, displayWidth - 1f)
        val nextY = (currentY + dy).coerceIn(0f, displayHeight - 1f)

        if (!injectMoveEvent(nextX, nextY)) return PointerDelivery.FAILED
        val deliveredDx = (nextX - currentX).toInt()
        val deliveredDy = (nextY - currentY).toInt()
        currentX = nextX
        currentY = nextY
        return PointerDelivery.deliveredMovement(deliveredDx, deliveredDy)
    }

    override fun button(button: Int, down: Boolean): PointerDelivery {
        if (!initialized || selectedDisplay == null) {
            log.warn("InputManagerPointerInjector", "button called before target selected")
            return PointerDelivery.FAILED
        }

        val btn = when (button) {
            0 -> MotionEvent.BUTTON_PRIMARY
            1 -> MotionEvent.BUTTON_SECONDARY
            2 -> MotionEvent.BUTTON_TERTIARY
            else -> return PointerDelivery.FAILED
        }

        // scrcpy-style: primary button uses ACTION_DOWN/UP (touch-like click),
        // other buttons use ACTION_BUTTON_PRESS/RELEASE (generic motion).
        val action = when (button) {
            0 -> if (down) MotionEvent.ACTION_DOWN else MotionEvent.ACTION_UP
            else -> if (down) MotionEvent.ACTION_BUTTON_PRESS else MotionEvent.ACTION_BUTTON_RELEASE
        }
        val newButtons = if (down) buttons or btn else buttons and btn.inv()
        val event = buildEvent(action, newButtons)
        if (!setDisplayId(event)) {
            event.recycle()
            return PointerDelivery.FAILED
        }
        val accepted = injectEvent(event)
        event.recycle()

        if (accepted) buttons = newButtons
        return if (accepted) PointerDelivery.DELIVERED else PointerDelivery.FAILED
    }

    override fun scroll(horizontal: Float, vertical: Float): PointerDelivery {
        if (!initialized || selectedDisplay == null) {
            log.warn("InputManagerPointerInjector", "scroll called before target selected")
            return PointerDelivery.FAILED
        }

        return if (injectScrollEvent(horizontal, vertical)) {
            PointerDelivery.DELIVERED
        } else {
            PointerDelivery.FAILED
        }
    }

    private fun injectMoveEvent(x: Float, y: Float): Boolean {
        // ACTION_MOVE while a button is held, otherwise hover move (scrcpy-style)
        val action = if (buttons != 0) MotionEvent.ACTION_MOVE else MotionEvent.ACTION_HOVER_MOVE
        val event = buildEvent(action, buttons, MotionEvent.PointerCoords().apply {
            this.x = x
            this.y = y
        })
        if (!setDisplayId(event)) {
            event.recycle()
            return false
        }
        val accepted = injectEvent(event)
        event.recycle()
        return accepted
    }

    private fun injectScrollEvent(horizontal: Float, vertical: Float): Boolean {
        val coords = MotionEvent.PointerCoords().apply {
            x = currentX
            y = currentY
            if (horizontal != 0f) setAxisValue(MotionEvent.AXIS_HSCROLL, horizontal)
            if (vertical != 0f) setAxisValue(MotionEvent.AXIS_VSCROLL, vertical)
        }
        val event = buildEvent(MotionEvent.ACTION_SCROLL, buttons, coords)
        if (!setDisplayId(event)) {
            event.recycle()
            return false
        }
        val accepted = injectEvent(event)
        event.recycle()
        return accepted
    }

    private fun buildEvent(action: Int, buttonState: Int, coords: MotionEvent.PointerCoords? = null): MotionEvent {
        val pointerCoords = coords ?: MotionEvent.PointerCoords().apply {
            x = currentX
            y = currentY
        }
        val pointerProperties = MotionEvent.PointerProperties().apply {
            id = 0
            toolType = MotionEvent.TOOL_TYPE_MOUSE
        }
        // uptimeMillis, not currentTimeMillis: injected events must use the
        // same clock domain as real input (scrcpy does the same). Epoch-based
        // eventTime breaks app-side gesture/timer comparisons and caused input
        // ANRs in Samsung's DeX launcher on device.
        val now = android.os.SystemClock.uptimeMillis()
        return MotionEvent.obtain(
            now,
            now,
            action,
            1,
            arrayOf(pointerProperties),
            arrayOf(pointerCoords),
            0,
            buttonState,
            1f,
            1f,
            0,
            0,
            InputDevice.SOURCE_MOUSE,
            0,
        )
    }

    private fun setDisplayId(event: MotionEvent): Boolean {
        val method = setDisplayIdMethod ?: return false
        if (selectedDisplayId < 0) return false
        return try {
            method.invoke(event, selectedDisplayId)
            true
        } catch (e: Exception) {
            log.warn("InputManagerPointerInjector", "target routing metadata update failed: ${e.message}")
            false
        }
    }

    private fun injectEvent(event: MotionEvent): Boolean {
        try {
            val method = injectInputEventMethod ?: run {
                log.error("InputManagerPointerInjector", "injectInputEvent method not available")
                return false
            }
            val result = method.invoke(inputManager, event, INJECT_INPUT_EVENT_MODE_ASYNC) as Boolean
            if (!result) {
                log.warn("InputManagerPointerInjector", "injectInputEvent returned false")
            }
            return result
        } catch (e: SecurityException) {
            log.error("InputManagerPointerInjector", "injectInputEvent security exception: ${e.message}")
            return false
        } catch (e: Exception) {
            log.error("InputManagerPointerInjector", "injectInputEvent failed: ${e.javaClass.simpleName}: ${e.message}")
            return false
        }
    }

    override fun close() {
        initialized = false
        selectedDisplayId = -1
        selectedDisplay = null
    }
}

/** Compatibility name for the pre-rebaseline implementation. */
@Deprecated("Use InputManagerPointerInjector")
typealias SdkPointerBackend = InputManagerPointerInjector
