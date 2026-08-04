package com.crossinput.helper

import android.view.KeyEvent

/**
 * KEY_EVENT → USB HID keyboard translation (ADR-0007, KEY_EVENT semantics).
 *
 * The wire format carries Android KeyEvent key codes + META_* flags; the UHID
 * backend needs HID keyboard usages and the 8-byte boot-keyboard report layout
 * (modifier byte, reserved byte, 6 key usages). The map is 1:1 with the USB
 * HID Usage Tables (0x00 = ErrorUndefined, letters/numbers follow the QWERTY
 * physical layout — no layout translation happens here; the Android IME
 * composes text from physical key positions).
 *
 * Pure functions so they are unit-testable on the JVM without a device.
 */
object KeyboardHidMapper {
    /** keyCode → HID keyboard usage. Null means "not mappable" (e.g. IME keys). */
    fun usageOf(keyCode: Int): Int? = USAGE[keyCode]

    /** KeyEvent.META_* → HID modifier byte bits (Left Ctrl=0x01 .. Right GUI=0x80). */
    fun modifierOf(metaState: Int): Int {
        var mod = 0
        if (metaState and KeyEvent.META_CTRL_LEFT_ON != 0) mod = mod or 0x01
        if (metaState and KeyEvent.META_CTRL_RIGHT_ON != 0) mod = mod or 0x10
        if (metaState and KeyEvent.META_CTRL_ON != 0 &&
            metaState and (KeyEvent.META_CTRL_LEFT_ON or KeyEvent.META_CTRL_RIGHT_ON) == 0
        ) mod = mod or 0x01
        if (metaState and KeyEvent.META_SHIFT_LEFT_ON != 0) mod = mod or 0x02
        if (metaState and KeyEvent.META_SHIFT_RIGHT_ON != 0) mod = mod or 0x20
        if (metaState and KeyEvent.META_SHIFT_ON != 0 &&
            metaState and (KeyEvent.META_SHIFT_LEFT_ON or KeyEvent.META_SHIFT_RIGHT_ON) == 0
        ) mod = mod or 0x02
        if (metaState and KeyEvent.META_ALT_LEFT_ON != 0) mod = mod or 0x04
        if (metaState and KeyEvent.META_ALT_RIGHT_ON != 0) mod = mod or 0x40
        if (metaState and KeyEvent.META_ALT_ON != 0 &&
            metaState and (KeyEvent.META_ALT_LEFT_ON or KeyEvent.META_ALT_RIGHT_ON) == 0
        ) mod = mod or 0x04
        if (metaState and KeyEvent.META_META_LEFT_ON != 0) mod = mod or 0x08
        if (metaState and KeyEvent.META_META_RIGHT_ON != 0) mod = mod or 0x80
        if (metaState and KeyEvent.META_META_ON != 0 &&
            metaState and (KeyEvent.META_META_LEFT_ON or KeyEvent.META_META_RIGHT_ON) == 0
        ) mod = mod or 0x08
        return mod
    }

    /**
     * Builds the 8-byte boot keyboard report for a single pressed key
     * (modifier, reserved 0, usage in slot 0, rest zero).
     */
    fun buildReport(modifier: Int, usage: Int): ByteArray =
        byteArrayOf(modifier.toByte(), 0, usage.toByte(), 0, 0, 0, 0, 0)

    /**
     * Builds the 8-byte boot keyboard report for a set of concurrently pressed
     * keys (boot keyboard = 6 key slots). Emits the current press state, so the
     * helper tracks down/up and reports the whole set on every transition.
     */
    fun buildReport(modifier: Int, usages: List<Int>): ByteArray {
        val report = ByteArray(8)
        report[0] = modifier.toByte()
        val head = usages.take(MAX_KEY_SLOTS)
        for (i in head.indices) report[2 + i] = head[i].toByte()
        return report
    }

    /** Boot keyboard report has 6 key slots (protocol.md). */
    const val MAX_KEY_SLOTS = 6

    private val USAGE: Map<Int, Int> = buildMap {
        // Letters (QWERTY physical positions)
        for (i in 0 until 26) put(KeyEvent.KEYCODE_A + i, 0x04 + i)
        // Digits row: KEYCODE_1..KEYCODE_0 = 8..16
        put(KeyEvent.KEYCODE_1, 0x1E); put(KeyEvent.KEYCODE_2, 0x1F); put(KeyEvent.KEYCODE_3, 0x20)
        put(KeyEvent.KEYCODE_4, 0x21); put(KeyEvent.KEYCODE_5, 0x22); put(KeyEvent.KEYCODE_6, 0x23)
        put(KeyEvent.KEYCODE_7, 0x24); put(KeyEvent.KEYCODE_8, 0x25); put(KeyEvent.KEYCODE_9, 0x26)
        put(KeyEvent.KEYCODE_0, 0x27)
        put(KeyEvent.KEYCODE_ENTER, 0x28)
        put(KeyEvent.KEYCODE_ESCAPE, 0x29)
        put(KeyEvent.KEYCODE_DEL, 0x2A) // backspace
        put(KeyEvent.KEYCODE_TAB, 0x2B)
        put(KeyEvent.KEYCODE_SPACE, 0x2C)
        put(KeyEvent.KEYCODE_MINUS, 0x2D)
        put(KeyEvent.KEYCODE_EQUALS, 0x2E)
        put(KeyEvent.KEYCODE_LEFT_BRACKET, 0x2F)
        put(KeyEvent.KEYCODE_RIGHT_BRACKET, 0x30)
        put(KeyEvent.KEYCODE_BACKSLASH, 0x31)
        put(KeyEvent.KEYCODE_SEMICOLON, 0x33)
        put(KeyEvent.KEYCODE_APOSTROPHE, 0x34)
        put(KeyEvent.KEYCODE_GRAVE, 0x35)
        put(KeyEvent.KEYCODE_COMMA, 0x36)
        put(KeyEvent.KEYCODE_PERIOD, 0x37)
        put(KeyEvent.KEYCODE_SLASH, 0x38)
        put(KeyEvent.KEYCODE_CAPS_LOCK, 0x39)
        // F1..F12 = 131..142
        for (i in 0 until 12) put(KeyEvent.KEYCODE_F1 + i, 0x3A + i)
        put(KeyEvent.KEYCODE_SYSRQ, 0x46) // PrintScreen (KEYCODE_SYSRQ on Android)
        put(KeyEvent.KEYCODE_SCROLL_LOCK, 0x47)
        put(KeyEvent.KEYCODE_BREAK, 0x48) // Pause/Break
        put(KeyEvent.KEYCODE_INSERT, 0x49)
        put(KeyEvent.KEYCODE_MOVE_HOME, 0x4A) // End-of-line Home (KEYCODE_MOVE_HOME)
        put(KeyEvent.KEYCODE_PAGE_UP, 0x4B)
        put(KeyEvent.KEYCODE_FORWARD_DEL, 0x4C)
        put(KeyEvent.KEYCODE_MOVE_END, 0x4D) // End (KEYCODE_MOVE_END)
        put(KeyEvent.KEYCODE_PAGE_DOWN, 0x4E)
        // Cursor keys
        put(KeyEvent.KEYCODE_DPAD_RIGHT, 0x4F)
        put(KeyEvent.KEYCODE_DPAD_LEFT, 0x50)
        put(KeyEvent.KEYCODE_DPAD_DOWN, 0x51)
        put(KeyEvent.KEYCODE_DPAD_UP, 0x52)
        // Numpad
        put(KeyEvent.KEYCODE_NUMPAD_DIVIDE, 0x54)
        put(KeyEvent.KEYCODE_NUMPAD_MULTIPLY, 0x55)
        put(KeyEvent.KEYCODE_NUMPAD_SUBTRACT, 0x56)
        put(KeyEvent.KEYCODE_NUMPAD_ADD, 0x57)
        put(KeyEvent.KEYCODE_NUMPAD_ENTER, 0x58)
        for (i in 0 until 9) put(KeyEvent.KEYCODE_NUMPAD_1 + i, 0x59 + i) // 1..9 → 0x59..0x61
        put(KeyEvent.KEYCODE_NUMPAD_0, 0x62)
        put(KeyEvent.KEYCODE_NUMPAD_DOT, 0x63)
    }
}
