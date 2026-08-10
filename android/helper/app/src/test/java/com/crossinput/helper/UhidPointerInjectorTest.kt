package com.crossinput.helper

import android.view.Display
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
        assertTrue(pointer.selectDisplay(display))

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
        pointer.selectDisplay(display)

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
        pointer.selectDisplay(display)

        assertEquals(PointerDelivery.FAILED, pointer.moveRelative(10, 0))
        verify(hid).destroy(9)
    }
}
