package com.crossinput.helper

import android.content.Context
import android.hardware.input.InputManager
import android.os.SystemClock
import android.view.InputEvent
import android.view.KeyEvent
import com.crossinput.helper.protocol.Messages
import java.lang.reflect.Method

/**
 * Keyboard delivery backend (ADR-0007): KEY_EVENT → UHID keyboard (preferred)
 * with automatic fallback to virtual KeyEvent injection via the internal
 * InputManager.injectInputEvent API (no AccessibilityService).
 *
 * The UHID keyboard is created eagerly with the standard boot keyboard
 * descriptor (protocol.md). If creation fails, or a report write fails, the
 * backend switches to virtual injection for the rest of the session and logs
 * the switch (metadata only — no key payloads, AGENTS.md rule 4).
 *
 * Test-only deterministic override via KeyboardBackendMode:
 * - AUTO: UHID preferred, fallback to InputManager on failure (production default)
 * - UHID: Force UHID; failure is logged and reported, no silent fallback
 * - INPUT_MANAGER: Force InputManager virtual injection; failure is logged and reported, no silent fallback
 */
class KeyboardBackend(
    private val log: Logger,
    private val context: Context,
    private val hid: HidDeviceManager,
    private val mode: KeyboardBackendMode = KeyboardBackendMode.AUTO,
) {
    private var uhidDeviceId: Int? = null
    private var uhidBroken = false
    private var inputManagerUnavailable = false

    /** HID usages currently pressed (UHID keyboard reports current state, not transitions). */
    private val pressedUsages = LinkedHashSet<Int>()

    private val inputManager: InputManager = context.getSystemService(Context.INPUT_SERVICE) as InputManager

    init {
        when (mode) {
            KeyboardBackendMode.AUTO -> {
                log.info("KeyboardBackend", "keyboard backend selected backend=uhid mode=auto")
                tryCreateUhid()
            }
            KeyboardBackendMode.UHID -> {
                log.info("KeyboardBackend", "keyboard backend selected backend=uhid mode=forced")
                tryCreateUhid()
                if (uhidBroken) {
                    log.error("KeyboardBackend", "UHID keyboard creation failed in forced UHID mode; keyboard unavailable")
                }
            }
            KeyboardBackendMode.INPUT_MANAGER -> {
                log.info("KeyboardBackend", "keyboard backend selected backend=input-manager mode=forced")
                // In forced InputManager mode, don't create UHID at all
                uhidBroken = true
                checkInputManagerAvailable()
            }
        }
    }

    private fun tryCreateUhid() {
        if (uhidBroken) return
        val result = hid.create(KEYBOARD_DESCRIPTOR, KEYBOARD_NAME)
        result.fold(
            onSuccess = {
                uhidDeviceId = it
                log.info("KeyboardBackend", "UHID keyboard created id=$it")
            },
            onFailure = {
                uhidBroken = true
                log.warn("KeyboardBackend", "UHID keyboard unavailable (${it.javaClass.simpleName}); virtual fallback active")
            },
        )
    }

    private fun checkInputManagerAvailable() {
        if (injectInputEventMethod == null) {
            inputManagerUnavailable = true
            log.error("KeyboardBackend", "InputManager virtual injection unavailable (reflection lookup failed); keyboard unavailable")
        }
    }

    /** Sends one key transition. Backend selection is determined by mode. */
    fun keyEvent(event: Messages.KeyEvent) {
        when (mode) {
            KeyboardBackendMode.AUTO -> {
                // AUTO: try UHID first, fall back to virtual on any failure
                val deviceId = uhidDeviceId
                if (deviceId != null && !uhidBroken) {
                    val usage = KeyboardHidMapper.usageOf(event.keyCode)
                    if (usage != null) {
                        val isDown = event.action == 0
                        if (isDown) pressedUsages.add(usage) else pressedUsages.remove(usage)
                        val modifier = KeyboardHidMapper.modifierOf(event.metaState)
                        val report = KeyboardHidMapper.buildReport(modifier, pressedUsages.toList())
                        if (hid.sendReport(deviceId, report)) return
                        uhidBroken = true
                        pressedUsages.clear()
                        log.warn("KeyboardBackend", "UHID report failed; switching to virtual fallback")
                    }
                    // Unmappable keyCode (e.g. non-US layout keys) → fall through to virtual injection
                }
                injectVirtual(event)
            }
            KeyboardBackendMode.UHID -> {
                // UHID forced: only use UHID, fail safely if unavailable
                val deviceId = uhidDeviceId
                if (deviceId != null && !uhidBroken) {
                    val usage = KeyboardHidMapper.usageOf(event.keyCode)
                    if (usage != null) {
                        val isDown = event.action == 0
                        if (isDown) pressedUsages.add(usage) else pressedUsages.remove(usage)
                        val modifier = KeyboardHidMapper.modifierOf(event.metaState)
                        val report = KeyboardHidMapper.buildReport(modifier, pressedUsages.toList())
                        if (hid.sendReport(deviceId, report)) return
                        uhidBroken = true
                        pressedUsages.clear()
                        log.error("KeyboardBackend", "UHID report failed in forced UHID mode; key event dropped")
                        return
                    }
                    // Unmappable keyCode → drop (no fallback in forced mode)
                    log.warn("KeyboardBackend", "KeyCode not mappable to HID usage in forced UHID mode; key event dropped")
                    return
                }
                // UHID unavailable
                log.error("KeyboardBackend", "UHID keyboard unavailable in forced UHID mode; key event dropped")
            }
            KeyboardBackendMode.INPUT_MANAGER -> {
                // INPUT_MANAGER forced: only use virtual injection
                if (inputManagerUnavailable) {
                    log.error("KeyboardBackend", "InputManager virtual injection unavailable in forced InputManager mode; key event dropped")
                    return
                }
                injectVirtual(event)
            }
        }
    }

    private fun injectVirtual(event: Messages.KeyEvent) {
        if (injectInputEventMethod == null) {
            if (!inputManagerUnavailable) {
                inputManagerUnavailable = true
                log.error("KeyboardBackend", "Virtual key injection unavailable; input event dropped")
            }
            return
        }
        val now = SystemClock.uptimeMillis()
        val keyEvent = KeyEvent(
            now, now,
            if (event.action == 0) KeyEvent.ACTION_DOWN else KeyEvent.ACTION_UP,
            event.keyCode,
            event.repeatCount,
            event.metaState,
        )
        try {
            val result = injectInputEventMethod.invoke(inputManager, keyEvent, INJECT_INPUT_EVENT_MODE_ASYNC) as Boolean
            if (!result) log.warn("KeyboardBackend", "Virtual key injection was rejected")
        } catch (e: SecurityException) {
            log.error("KeyboardBackend", "Virtual key injection failed: ${e.javaClass.simpleName}")
        } catch (e: Exception) {
            log.error("KeyboardBackend", "Virtual key injection failed: ${e.javaClass.simpleName}")
        }
    }

    fun destroy() {
        if (pressedUsages.isNotEmpty()) {
            // Release any keys still reported as pressed so the keyboard state
            // doesn't hang after the device is torn down.
            uhidDeviceId?.let { hid.sendReport(it, KeyboardHidMapper.buildReport(0, listOf())) }
            pressedUsages.clear()
        }
        uhidDeviceId?.let { hid.destroy(it) }
        uhidDeviceId = null
    }

    companion object {
        private const val INJECT_INPUT_EVENT_MODE_ASYNC = 0
        private const val KEYBOARD_NAME = "Ampersand Keyboard"

        // Standard boot keyboard descriptor (protocol.md, "Standard boot keyboard
        // HID descriptor"): 1 modifier byte + 1 reserved + 6 key usages.
        val KEYBOARD_DESCRIPTOR = byteArrayOf(
            0x05, 0x01, 0x09, 0x06, 0xA1.toByte(), 0x01, 0x05, 0x07,
            0x19, 0xE0.toByte(), 0x29, 0xE7.toByte(), 0x15, 0x00, 0x25, 0x01,
            0x75, 0x01, 0x95.toByte(), 0x08, 0x81.toByte(), 0x02, 0x95.toByte(), 0x01,
            0x75, 0x08, 0x81.toByte(), 0x01, 0x95.toByte(), 0x05, 0x75, 0x01,
            0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91.toByte(), 0x02,
            0x95.toByte(), 0x01, 0x75, 0x03, 0x91.toByte(), 0x01, 0x95.toByte(), 0x06,
            0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07,
            0x19, 0x00, 0x29, 0x65, 0x81.toByte(), 0x00, 0xC0.toByte(),
        )

        private val injectInputEventMethod: Method? = try {
            InputManager::class.java.getMethod("injectInputEvent", InputEvent::class.java, Int::class.java)
        } catch (_: Throwable) {
            null
        }
    }
}