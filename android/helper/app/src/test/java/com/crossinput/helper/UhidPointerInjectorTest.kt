package com.crossinput.helper

import android.view.Display
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.argumentCaptor
import org.mockito.kotlin.eq
import org.mockito.kotlin.mock
import org.mockito.kotlin.times
import org.mockito.kotlin.verify
import org.mockito.kotlin.whenever

class UhidPointerInjectorTest {
    private val log: Logger = mock()
    private val hid: HidDeviceManager = mock()
    private val display: Display = mock()

    private fun injector(sendSucceeds: Boolean = true): UhidPointerInjector {
        whenever(display.displayId).thenReturn(42)
        whenever(hid.create(any(), any())).thenReturn(Result.success(9))
        whenever(hid.sendReport(any(), any())).thenReturn(sendSucceeds)
        return UhidPointerInjector(log, hid)
    }

    @Test
    fun largeDeltaIsSplitWithoutLosingMovement() {
        val pointer = injector()
        assertTrue(pointer.create())

        val result = pointer.moveRelative(300, 0)
        assertEquals(PointerDelivery.Status.DELIVERED, result.status)
        assertEquals(300, result.deliveredDx)
        val reports = argumentCaptor<ByteArray>()
        verify(hid, times(3)).sendReport(eq(9), reports.capture())
        assertEquals(300, reports.allValues.sumOf { it[1].toInt() })
        assertTrue(reports.allValues.all { it[1].toInt() in -127..127 })
    }

    @Test
    fun buttonStateAndWheelAreEncodedAndCleanupReleasesButtons() {
        val pointer = injector()
        pointer.create()

        assertEquals(PointerDelivery.DELIVERED, pointer.button(0, true))
        assertEquals(PointerDelivery.DELIVERED, pointer.scroll(0f, -1f))
        pointer.close()

        val reports = argumentCaptor<ByteArray>()
        verify(hid, times(3)).sendReport(eq(9), reports.capture())
        assertEquals(0x01, reports.allValues[0][0].toInt() and 0xFF)
        assertEquals(0xFF, reports.allValues[1][3].toInt() and 0xFF)
        assertEquals(0, reports.allValues[2][0].toInt() and 0xFF)
        verify(hid).destroy(9)
    }

    @Test
    fun failedReportDoesNotPretendToDeliverMovement() {
        val pointer = injector(sendSucceeds = false)
        pointer.create()

        assertEquals(PointerDelivery.FAILED, pointer.moveRelative(10, 0))
        verify(hid).destroy(9)
    }

    @Test
    fun selectedDisplayCannotBeClaimedBySystemRoutedUhid() {
        val pointer = injector()

        assertTrue(!pointer.selectDisplay(display))
        assertEquals(PointerRouting.SYSTEM_ROUTED, pointer.routing)
    }

    @Test
    fun semanticDescriptorMatchesGoldenBytesIncludingAcPanUsage() {
        val expected = hexToBytes(
            "05 01 09 02 A1 01 09 01 A1 00 " +
                "05 09 19 01 29 03 15 00 25 01 " +
                "95 03 75 01 81 02 " +
                "95 01 75 05 81 01 " +
                "05 01 09 30 09 31 15 81 25 7F " +
                "75 08 95 02 81 06 " +
                "09 38 15 81 25 7F 75 08 95 01 81 06 " +
                // Consumer AC Pan usage 0x0238 (16-bit usage item) maps to
                // REL_HWHEEL in the Linux generic HID layer.
                "05 0C 0A 38 02 15 81 25 7F 75 08 95 01 81 06 " +
                "C0 C0",
        )
        assertArrayEquals(expected, UhidPointerInjector.MOUSE_DESCRIPTOR)
    }

    @Test
    fun horizontalScrollInvertsTheCxiSignIntoThePanField() {
        val pointer = injector()
        pointer.create()

        assertEquals(PointerDelivery.DELIVERED, pointer.scroll(1f, 0f))
        assertEquals(PointerDelivery.DELIVERED, pointer.scroll(-1f, 0f))

        val reports = argumentCaptor<ByteArray>()
        verify(hid, times(2)).sendReport(eq(9), reports.capture())
        // CXI +horizontal means LEFT; the native chain treats positive pan as
        // RIGHT, so the byte is inverted: left -> -1 (0xFF), right -> +1.
        assertEquals(5, reports.allValues[0].size)
        assertEquals(0xFF, reports.allValues[0][4].toInt() and 0xFF)
        assertEquals(0x01, reports.allValues[1][4].toInt() and 0xFF)
        assertEquals(0, reports.allValues[0][3].toInt())
    }

    @Test
    fun movementButtonAndVerticalWheelReportsCarryZeroPan() {
        val pointer = injector()
        pointer.create()

        pointer.moveRelative(10, 20)
        pointer.scroll(0f, -1f)
        pointer.button(2, true)

        val reports = argumentCaptor<ByteArray>()
        verify(hid, times(3)).sendReport(eq(9), reports.capture())
        for (report in reports.allValues) {
            assertEquals(5, report.size)
            assertEquals(0, report[4].toInt())
        }
        assertEquals(20, reports.allValues[0][2].toInt())
        assertEquals(-1, reports.allValues[1][3].toInt())
        assertEquals(0x04, reports.allValues[2][0].toInt() and 0xFF)
    }

    private companion object {
        fun hexToBytes(hex: String): ByteArray =
            hex.trim().split(Regex("\\s+")).map { it.toInt(16).toByte() }.toByteArray()
    }
}
