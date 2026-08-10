package com.crossinput.helper

import android.view.Display
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever

class PointerDispatcherTest {
    private val log: Logger = mock()
    private val uhid: UhidPointerInjector = mock()
    private val inputManager: InputManagerPointerInjector = mock()
    private val display: Display = mock()

    @Test
    fun autoPrefersUhid() {
        whenever(uhid.create()).thenReturn(true)
        whenever(uhid.selectDisplay(any())).thenReturn(true)

        val dispatcher = PointerDispatcher(log, uhid, inputManager)

        assertTrue(dispatcher.selectDisplay(display))
        whenever(uhid.moveRelative(5, 6)).thenReturn(PointerDelivery.DELIVERED)
        assertEquals(PointerDelivery.DELIVERED, dispatcher.moveRelative(5, 6))
    }

    @Test
    fun uhidFailureRetriesOnceOnInputManagerFallback() {
        whenever(uhid.create()).thenReturn(true)
        whenever(uhid.selectDisplay(any())).thenReturn(true)
        whenever(uhid.moveRelative(5, 6)).thenReturn(PointerDelivery.FAILED)
        whenever(inputManager.selectDisplay(any())).thenReturn(true)
        whenever(inputManager.moveRelative(5, 6)).thenReturn(PointerDelivery.DELIVERED)

        val dispatcher = PointerDispatcher(log, uhid, inputManager)
        dispatcher.selectDisplay(display)

        assertEquals(PointerDelivery.DELIVERED, dispatcher.moveRelative(5, 6))
    }
}
