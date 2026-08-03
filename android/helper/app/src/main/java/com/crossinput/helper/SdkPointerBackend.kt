package com.crossinput.helper

import android.content.Context
import android.hardware.input.InputManager
import android.view.Display
import android.view.InputDevice
import android.view.InputEvent
import android.view.MotionEvent
import java.lang.reflect.Method

/**
 * Input backend that injects pointer events via InputManager.injectInputEvent()
 * with display ID targeting (scrcpy-style SDK injection).
 * Works on Android 10+ with secondary display support.
 *
 * injectInputEvent and setDisplayId are hidden in the current public SDK
 * (android.jar), so they are invoked via reflection wrappers, exactly like
 * scrcpy's server does.
 */
class SdkPointerBackend(
    private val log: Logger,
    private val context: Context,
) {
    private val inputManager: InputManager = context.getSystemService(Context.INPUT_SERVICE) as InputManager
    private var selectedDisplayId: Int = -1
    private var selectedDisplay: Display? = null
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

    fun selectDisplay(display: Display) {
        selectedDisplayId = display.displayId
        selectedDisplay = display
        initialized = true

        val metrics = android.util.DisplayMetrics()
        display.getRealMetrics(metrics)
        currentX = metrics.widthPixels / 2f
        currentY = metrics.heightPixels / 2f

        log.info("SdkPointerBackend", "selected display $selectedDisplayId (${metrics.widthPixels}x${metrics.heightPixels})")
    }

    fun moveRelative(dx: Int, dy: Int) {
        if (!initialized || selectedDisplay == null) {
            log.warn("SdkPointerBackend", "moveRelative called before display selected")
            return
        }

        val display = selectedDisplay!!
        val metrics = android.util.DisplayMetrics()
        display.getRealMetrics(metrics)

        currentX = (currentX + dx).coerceIn(0f, metrics.widthPixels - 1f)
        currentY = (currentY + dy).coerceIn(0f, metrics.heightPixels - 1f)

        injectMoveEvent()
    }

    fun button(button: Int, down: Boolean) {
        if (!initialized || selectedDisplay == null) {
            log.warn("SdkPointerBackend", "button called before display selected")
            return
        }

        val btn = when (button) {
            0 -> MotionEvent.BUTTON_PRIMARY
            1 -> MotionEvent.BUTTON_SECONDARY
            2 -> MotionEvent.BUTTON_TERTIARY
            else -> return
        }

        // scrcpy-style: primary button uses ACTION_DOWN/UP (touch-like click),
        // other buttons use ACTION_BUTTON_PRESS/RELEASE (generic motion).
        val action = when (button) {
            0 -> if (down) MotionEvent.ACTION_DOWN else MotionEvent.ACTION_UP
            else -> if (down) MotionEvent.ACTION_BUTTON_PRESS else MotionEvent.ACTION_BUTTON_RELEASE
        }
        val newButtons = if (down) buttons or btn else buttons and btn.inv()
        val event = buildEvent(action, newButtons)
        setDisplayId(event)
        injectEvent(event)
        event.recycle()

        buttons = newButtons
    }

    fun scroll(horizontal: Float, vertical: Float) {
        if (!initialized || selectedDisplay == null) {
            log.warn("SdkPointerBackend", "scroll called before display selected")
            return
        }

        injectScrollEvent(horizontal, vertical)
    }

    private fun injectMoveEvent() {
        // ACTION_MOVE while a button is held, otherwise hover move (scrcpy-style)
        val action = if (buttons != 0) MotionEvent.ACTION_MOVE else MotionEvent.ACTION_HOVER_MOVE
        val event = buildEvent(action, buttons)
        setDisplayId(event)
        injectEvent(event)
        event.recycle()
    }

    private fun injectScrollEvent(horizontal: Float, vertical: Float) {
        val coords = MotionEvent.PointerCoords().apply {
            x = currentX
            y = currentY
            if (horizontal != 0f) setAxisValue(MotionEvent.AXIS_HSCROLL, horizontal)
            if (vertical != 0f) setAxisValue(MotionEvent.AXIS_VSCROLL, vertical)
        }
        val event = buildEvent(MotionEvent.ACTION_SCROLL, buttons, coords)
        setDisplayId(event)
        injectEvent(event)
        event.recycle()
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
        val now = System.currentTimeMillis()
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

    private fun setDisplayId(event: MotionEvent) {
        if (selectedDisplayId >= 0) {
            setDisplayIdMethod?.let { method ->
                try {
                    method.invoke(event, selectedDisplayId)
                } catch (e: Exception) {
                    log.warn("SdkPointerBackend", "setDisplayId failed: ${e.message}")
                }
            }
        }
    }

    private fun injectEvent(event: MotionEvent) {
        try {
            val method = injectInputEventMethod ?: run {
                log.error("SdkPointerBackend", "injectInputEvent method not available")
                return
            }
            val result = method.invoke(inputManager, event, INJECT_INPUT_EVENT_MODE_ASYNC) as Boolean
            if (!result) {
                log.warn("SdkPointerBackend", "injectInputEvent returned false")
            }
        } catch (e: SecurityException) {
            log.error("SdkPointerBackend", "injectInputEvent security exception: ${e.message}")
        } catch (e: Exception) {
            log.error("SdkPointerBackend", "injectInputEvent failed: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    fun close() {
        initialized = false
        selectedDisplayId = -1
        selectedDisplay = null
    }
}
