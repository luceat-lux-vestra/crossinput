package com.crossinput.helper

import android.content.Context
import android.hardware.input.InputManager
import android.os.SystemClock
import android.view.InputDevice
import android.view.InputEvent
import android.view.KeyCharacterMap
import android.view.KeyEvent
import com.crossinput.helper.protocol.Messages
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method

/**
 * Delivers a KeyEvent through the internal `InputManager.injectInputEvent` API.
 *
 * Extracted as a seam so the fallback path can be exercised off-device: the
 * hidden method is absent from the unit-test android.jar, so tests substitute a
 * fake instead of always taking the "unavailable" branch.
 */
interface VirtualKeyInjector {
    /** True when injection is possible at all (hidden API resolved). */
    val available: Boolean

    /** Returns true when the event was accepted. Throws on injection failure. */
    fun inject(event: Messages.KeyEvent): Boolean
}

/** Production [VirtualKeyInjector] backed by reflection against InputManager. */
class ReflectionKeyInjector(private val context: Context) : VirtualKeyInjector {

    private val inputManager: InputManager by lazy {
        context.getSystemService(Context.INPUT_SERVICE) as InputManager
    }

    override val available: Boolean get() = INJECT_INPUT_EVENT != null

    override fun inject(event: Messages.KeyEvent): Boolean {
        val method = INJECT_INPUT_EVENT ?: return false
        val now = SystemClock.uptimeMillis()
        // The short KeyEvent constructor leaves deviceId=0 and source=SOURCE_UNKNOWN.
        // injectInputEvent still returns true for such an event, but the dispatcher
        // never routes it to a focused text field — verified on SM-G977N, where the
        // fallback silently typed nothing. Identify as the virtual keyboard, exactly
        // as the platform `input keyevent` command does.
        val keyEvent = KeyEvent(
            now, now,
            if (event.action == 0) KeyEvent.ACTION_DOWN else KeyEvent.ACTION_UP,
            event.keyCode,
            event.repeatCount,
            event.metaState,
            KeyCharacterMap.VIRTUAL_KEYBOARD,
            0, // scanCode
            0, // flags
            InputDevice.SOURCE_KEYBOARD,
        )
        return try {
            method.invoke(inputManager, keyEvent, INJECT_INPUT_EVENT_MODE_ASYNC) as Boolean
        } catch (e: InvocationTargetException) {
            // Surface what the API actually threw (e.g. SecurityException);
            // the reflection wrapper alone tells the caller nothing.
            throw e.targetException
        }
    }

    private companion object {
        const val INJECT_INPUT_EVENT_MODE_ASYNC = 0

        val INJECT_INPUT_EVENT: Method? = try {
            InputManager::class.java.getMethod("injectInputEvent", InputEvent::class.java, Int::class.java)
        } catch (_: Throwable) {
            null
        }
    }
}

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
 * [mode] is a test-only deterministic override. A forced backend never becomes
 * the other backend: it fails safe (event dropped, error logged, session alive)
 * so a verification run cannot silently measure the wrong path.
 */
class KeyboardBackend(
    private val log: Logger,
    context: Context,
    private val hid: HidDeviceManager,
    private val mode: KeyboardBackendMode = KeyboardBackendMode.AUTO,
    private val injector: VirtualKeyInjector = ReflectionKeyInjector(context),
) {
    private var uhidDeviceId: Int? = null
    private var uhidBroken = false
    private var virtualUnavailableLogged = false

    /** HID usages currently pressed (UHID keyboard reports current state, not transitions). */
    private val pressedUsages = LinkedHashSet<Int>()

    /** Accepted virtual key-down events awaiting an accepted key-up. */
    private val pressedVirtualKeys = LinkedHashMap<Int, Messages.KeyEvent>()

    init {
        when (mode) {
            KeyboardBackendMode.AUTO -> {
                tryCreateUhid()
                logSelected(if (uhidUsable()) BACKEND_UHID else BACKEND_VIRTUAL, "auto")
            }
            KeyboardBackendMode.UHID -> {
                tryCreateUhid()
                logSelected(BACKEND_UHID, "forced")
                if (!uhidUsable()) {
                    log.error(TAG, "UHID unavailable in forced uhid mode; keyboard inactive")
                }
            }
            KeyboardBackendMode.INPUT_MANAGER -> {
                // Never create the UHID device in this mode.
                uhidBroken = true
                logSelected(BACKEND_VIRTUAL, "forced")
                if (!injector.available) {
                    log.error(TAG, "virtual injection unavailable in forced input-manager mode; keyboard inactive")
                }
            }
        }
    }

    private fun tryCreateUhid() {
        if (uhidBroken) return
        val result = hid.create(KEYBOARD_DESCRIPTOR, KEYBOARD_NAME)
        result.fold(
            onSuccess = {
                uhidDeviceId = it
                log.info(TAG, "UHID keyboard created id=$it")
            },
            onFailure = {
                uhidBroken = true
                log.warn(TAG, "UHID keyboard unavailable (${it.javaClass.simpleName})")
            },
        )
    }

    private fun uhidUsable(): Boolean = uhidDeviceId != null && !uhidBroken

    /** Active-backend marker for verification runs; metadata only (AGENTS.md rule 4). */
    private fun logSelected(backend: String, selection: String) {
        log.info(TAG, "keyboard backend selected backend=$backend mode=$selection")
    }

    /** Sends one key transition through the backend selected by [mode]. */
    fun keyEvent(event: Messages.KeyEvent) {
        when (mode) {
            KeyboardBackendMode.AUTO -> if (!sendViaUhid(event)) injectVirtual(event)
            KeyboardBackendMode.UHID -> if (!sendViaUhid(event)) {
                log.warn(TAG, "key event dropped in forced uhid mode (UHID unusable or key code has no HID usage)")
            }
            KeyboardBackendMode.INPUT_MANAGER -> injectVirtual(event)
        }
    }

    /**
     * Attempts one UHID report. Returns false when UHID is unusable or the key
     * code has no HID usage (e.g. non-US layout keys) — the caller decides
     * whether that means fall back (AUTO) or drop (forced UHID).
     */
    private fun sendViaUhid(event: Messages.KeyEvent): Boolean {
        val deviceId = uhidDeviceId
        if (deviceId == null || uhidBroken) return false
        val usage = KeyboardHidMapper.usageOf(event.keyCode) ?: return false

        if (event.action == 0) pressedUsages.add(usage) else pressedUsages.remove(usage)
        val modifier = KeyboardHidMapper.modifierOf(event.metaState)
        val report = KeyboardHidMapper.buildReport(modifier, pressedUsages.toList())
        if (hid.sendReport(deviceId, report)) return true

        uhidBroken = true
        pressedUsages.clear()
        log.warn(TAG, "UHID report failed; UHID disabled for this session")
        if (mode == KeyboardBackendMode.AUTO) logSelected(BACKEND_VIRTUAL, "auto")
        return false
    }

    private fun injectVirtual(event: Messages.KeyEvent) {
        if (!injector.available) {
            if (!virtualUnavailableLogged) {
                virtualUnavailableLogged = true
                log.error(TAG, "virtual key injection unavailable; key events dropped")
            }
            return
        }
        try {
            if (!injector.inject(event)) {
                log.warn(TAG, "virtual key injection was rejected")
                return
            }
            when (event.action) {
                0 -> pressedVirtualKeys[event.keyCode] = event
                1 -> pressedVirtualKeys.remove(event.keyCode)
            }
        } catch (t: Throwable) {
            // Fail safe: the session stays alive, the event is dropped, and only
            // the exception class name is logged (AGENTS.md rule 4).
            log.error(TAG, "virtual key injection failed: ${t.javaClass.simpleName}")
        }
    }

    private fun releaseVirtualKeys() {
        // Snapshot the values: successful synthetic UPs remove entries from the
        // live map, while rejected/exceptional UPs intentionally remain held so
        // a later idempotent destroy can retry them.
        for (held in pressedVirtualKeys.values.toList()) {
            injectVirtual(Messages.KeyEvent(held.keyCode, held.metaState, 1, 0))
        }
    }

    fun destroy() {
        releaseVirtualKeys()
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
        private const val TAG = "KeyboardBackend"
        private const val KEYBOARD_NAME = "Ampersand Keyboard"
        private const val BACKEND_UHID = "uhid"
        private const val BACKEND_VIRTUAL = "input-manager"

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
    }
}
