package com.crossinput.helper

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class KeyboardHidMapperTest {

    @Test
    fun lettersMapToUsages() {
        assertEquals(0x04, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_A))
        assertEquals(0x1D, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_Z))
        assertEquals(0x0A, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_G))
    }

    @Test
    fun digitsMapToUsages() {
        assertEquals(0x1E, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_1))
        assertEquals(0x27, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_0))
    }

    @Test
    fun controlKeysMapToUsages() {
        assertEquals(0x28, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_ENTER))
        assertEquals(0x29, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_ESCAPE))
        assertEquals(0x2A, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_DEL))
        assertEquals(0x2C, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_SPACE))
        assertEquals(0x39, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_CAPS_LOCK))
        assertEquals(0x3A, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_F1))
        assertEquals(0x45, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_F12))
        assertEquals(0x4F, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_DPAD_RIGHT))
    }

    @Test
    fun numpadMapsToUsages() {
        assertEquals(0x59, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_NUMPAD_1))
        assertEquals(0x61, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_NUMPAD_9))
        assertEquals(0x62, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_NUMPAD_0))
        assertEquals(0x63, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_NUMPAD_DOT))
        assertEquals(0x54, KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_NUMPAD_DIVIDE))
    }

    @Test
    fun unmappedKeysReturnNull() {
        assertNull(KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_VOLUME_UP))
        assertNull(KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_BACK))
        assertNull(KeyboardHidMapper.usageOf(KeyEvent.KEYCODE_ASSIST))
    }

    @Test
    fun modifiersMapToHidBits() {
        assertEquals(0x02, KeyboardHidMapper.modifierOf(KeyEvent.META_SHIFT_ON))
        assertEquals(0x01, KeyboardHidMapper.modifierOf(KeyEvent.META_CTRL_ON))
        assertEquals(0x04, KeyboardHidMapper.modifierOf(KeyEvent.META_ALT_ON))
        assertEquals(0x08, KeyboardHidMapper.modifierOf(KeyEvent.META_META_ON))
        assertEquals(0x02, KeyboardHidMapper.modifierOf(KeyEvent.META_SHIFT_LEFT_ON))
        assertEquals(0x20, KeyboardHidMapper.modifierOf(KeyEvent.META_SHIFT_RIGHT_ON))
        assertEquals(0x10, KeyboardHidMapper.modifierOf(KeyEvent.META_CTRL_RIGHT_ON))
        assertEquals(0x03, KeyboardHidMapper.modifierOf(KeyEvent.META_SHIFT_ON or KeyEvent.META_CTRL_ON))
        assertEquals(0x00, KeyboardHidMapper.modifierOf(0))
    }

    @Test
    fun buildReportLayout() {
        val report = KeyboardHidMapper.buildReport(0x02, 0x04) // Shift + A
        assertEquals(8, report.size)
        assertEquals(0x02, report[0].toInt() and 0xFF)
        assertEquals(0x00, report[1].toInt() and 0xFF)
        assertEquals(0x04, report[2].toInt() and 0xFF)
        for (i in 3 until 8) assertEquals(0x00, report[i].toInt() and 0xFF)
    }

    @Test
    fun buildReportMultiKeyLayout() {
        val report = KeyboardHidMapper.buildReport(0x03, listOf(0x04, 0x1D, 0x28)) // Ctrl+Shift+A+Z+Enter
        assertEquals(8, report.size)
        assertEquals(0x03, report[0].toInt() and 0xFF)
        assertEquals(0x04, report[2].toInt() and 0xFF)
        assertEquals(0x1D, report[3].toInt() and 0xFF)
        assertEquals(0x28, report[4].toInt() and 0xFF)
        for (i in 5 until 8) assertEquals(0x00, report[i].toInt() and 0xFF)
    }

    @Test
    fun buildReportEmptyReportIsAllZero() {
        val report = KeyboardHidMapper.buildReport(0, emptyList())
        assertEquals(8, report.size)
        for (i in 0 until 8) assertEquals(0x00, report[i].toInt() and 0xFF)
    }

    @Test
    fun buildReportTruncatesToSixSlots() {
        val report = KeyboardHidMapper.buildReport(0, (0x04..0x20).toList()) // 29 usages > 6 slots
        assertEquals(8, report.size)
        for (i in 0 until KeyboardHidMapper.MAX_KEY_SLOTS) {
            assertEquals(0x04 + i, report[2 + i].toInt() and 0xFF)
        }
        assertEquals(0x04 + KeyboardHidMapper.MAX_KEY_SLOTS - 1, report[7].toInt() and 0xFF)
    }
}
