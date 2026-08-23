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
 * Applies [MotionEvent.setDisplayId] (hidden API 28+) so injected events are
 * targeted at the selected display. Production resolves the setter
 * reflectively once; when unavailable, targeting cannot be honored and the
 * backend reports itself unable to route explicitly. Injectable for host-JVM
 * unit tests.
 */
fun interface DisplayIdSetter {
    /** Returns false when display targeting is unavailable on this build. */
    fun set(event: MotionEvent, displayId: Int): Boolean

    companion object {
        /** Sentinel: display targeting unavailable on this build. */
        val UNAVAILABLE: DisplayIdSetter = DisplayIdSetter { _, _ -> false }

        fun reflection(): DisplayIdSetter {
            val method = try {
                MotionEvent::class.java.getMethod("setDisplayId", Int::class.java)
            } catch (_: Throwable) {
                null
            }
            return if (method == null) {
                UNAVAILABLE
            } else {
                DisplayIdSetter { event, displayId ->
                    try {
                        method.invoke(event, displayId)
                        true
                    } catch (_: Throwable) {
                        false
                    }
                }
            }
        }
    }
}

/**
 * Applies [MotionEvent.setActionButton] (@hide, runtime API 23+) so
 * press/release events carry the button that changed; Samsung's DeX pipeline
 * rejects them otherwise (issue #57). Reports success explicitly: when the
 * hidden API is unavailable or the invocation fails, the caller must refuse
 * to inject a press/release event whose actionButton disagrees with its
 * buttonState — that malformed event is exactly what the device rejected.
 * Injectable for host-JVM unit tests.
 */
fun interface ActionButtonSetter {
    /** Returns false when actionButton could not be applied. */
    fun set(event: MotionEvent, button: Int): Boolean

    companion object {
        fun reflection(): ActionButtonSetter {
            val method = try {
                MotionEvent::class.java.getMethod("setActionButton", Int::class.java)
            } catch (_: Throwable) {
                null
            }
            return ActionButtonSetter { event, button ->
                try {
                    method?.invoke(event, button)
                    method != null
                } catch (_: Throwable) {
                    false
                }
            }
        }
    }
}

/**
 * Injects a built [MotionEvent] through the hidden
 * [InputManager.injectInputEvent] (async mode) and reports acceptance.
 * Production resolves the method reflectively once; when unavailable every
 * injection fails, which keeps routing/failover decisions honest. Injectable
 * for host-JVM unit tests.
 */
fun interface MotionEventInjector {
    fun inject(event: MotionEvent): Boolean

    companion object {
        /** Same value as the hidden InputManager.INJECT_INPUT_EVENT_MODE_ASYNC. */
        private const val INJECT_MODE = 0

        fun reflection(context: Context): MotionEventInjector? {
            val inputManager =
                context.getSystemService(Context.INPUT_SERVICE) as InputManager
            val method = try {
                InputManager::class.java.getMethod(
                    "injectInputEvent",
                    InputEvent::class.java,
                    Int::class.java,
                )
            } catch (_: Throwable) {
                return null
            }
            return MotionEventInjector { event ->
                try {
                    method.invoke(inputManager, event, INJECT_MODE) == true
                } catch (_: Throwable) {
                    false
                }
            }
        }
    }
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
    context: Context,
    private val actionButtonSetter: ActionButtonSetter = ActionButtonSetter.reflection(),
    private val displayIdSetter: DisplayIdSetter = DisplayIdSetter.reflection(),
    private val eventInjector: MotionEventInjector? = MotionEventInjector.reflection(context),
) : PointerInjector {
    override val routing: PointerRouting
        get() = if (displayIdSetter != DisplayIdSetter.UNAVAILABLE) {
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

    /**
     * Starts a new selection epoch. Invariant: every successful
     * [selectDisplay] begins with no buttons logically held by this injector
     * — the instance is long-lived under Main/PointerDispatcher, and a stale
     * mask would emit ACTION_MOVE (instead of ACTION_HOVER_MOVE) with stale
     * buttonState on the first move of the new epoch.
     */
    override fun selectDisplay(display: Display): Boolean {
        if (displayIdSetter == DisplayIdSetter.UNAVAILABLE) {
            log.error("InputManagerPointerInjector", "explicit display routing API unavailable")
            initialized = false
            return false
        }
        buttons = 0
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
        // ACTION_BUTTON_PRESS/RELEASE events must carry the matching
        // actionButton; MotionEvent.obtain leaves it 0 (= BUTTON_PRIMARY),
        // producing an event whose action says "secondary/tertiary changed"
        // while its metadata claims the primary button did it. Samsung's DeX
        // input pipeline rejects that inconsistent event outright, so a
        // press/release whose actionButton cannot be applied must fail
        // closed: injecting it anyway would reproduce the exact device
        // defect. The tracked mask is only committed on full success.
        val needsActionButton =
            action == MotionEvent.ACTION_BUTTON_PRESS ||
                action == MotionEvent.ACTION_BUTTON_RELEASE
        val newButtons = if (down) buttons or btn else buttons and btn.inv()
        val event = buildEvent(
            action,
            newButtons,
            actionButton = if (needsActionButton) btn else 0,
        )
        val applied = if (needsActionButton) {
            try {
                actionButtonSetter.set(event, btn)
            } catch (_: Throwable) {
                false
            }
        } else {
            true
        }
        if (!applied) {
            event.recycle()
            log.warn(
                "InputManagerPointerInjector",
                "actionButton metadata unavailable; rejecting secondary/tertiary " +
                    "${if (down) "press" else "release"} to avoid a malformed event",
            )
            return PointerDelivery.FAILED
        }
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
            // CXI wire contract: positive horizontal = LEFT (mirrors macOS).
            // AXIS_HSCROLL positive means RIGHT on Android, so negate here;
            // passing the wire value through verbatim inverted the direction.
            if (horizontal != 0f) setAxisValue(MotionEvent.AXIS_HSCROLL, -horizontal)
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

    private fun buildEvent(
        action: Int,
        buttonState: Int,
        coords: MotionEvent.PointerCoords? = null,
        actionButton: Int = 0,
    ): MotionEvent {
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
        val event = MotionEvent.obtain(
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
        return event
    }

    private fun injectEvent(event: MotionEvent): Boolean {
        val injector = eventInjector
        if (injector != null) {
            return try {
                injector.inject(event)
            } catch (_: Throwable) {
                false
            }
        }
        log.error("InputManagerPointerInjector", "injectInputEvent method not available")
        return false
    }

    private fun setDisplayId(event: MotionEvent): Boolean {
        if (selectedDisplayId < 0) return false
        val ok = displayIdSetter.set(event, selectedDisplayId)
        if (!ok) {
            log.warn("InputManagerPointerInjector", "target routing metadata update failed")
        }
        return ok
    }

    override fun close() {
        // InputManager owns no virtual HID device, so teardown is a local
        // state reset; no synthetic release events are required. Resetting
        // the mask here guarantees a reused instance never resurrects held
        // buttons even if callers skip selectDisplay.
        initialized = false
        selectedDisplayId = -1
        selectedDisplay = null
        buttons = 0
    }
}

/** Compatibility name for the pre-rebaseline implementation. */
@Deprecated("Use InputManagerPointerInjector")
typealias SdkPointerBackend = InputManagerPointerInjector
