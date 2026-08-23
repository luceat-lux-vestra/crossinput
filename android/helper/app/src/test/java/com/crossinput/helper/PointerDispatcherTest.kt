package com.crossinput.helper

import android.view.Display
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.eq
import org.mockito.kotlin.mock
import org.mockito.kotlin.never
import org.mockito.kotlin.times
import org.mockito.kotlin.verify
import org.mockito.kotlin.whenever

class PointerDispatcherTest {
    private val log: Logger = mock()
    private val uhid: UhidPointerInjector = mock()
    private val inputManager: InputManagerPointerInjector = mock()
    private val display: Display = mock()

    /** AUTO dispatcher with an injectable desktop-sink predicate. */
    private fun auto(desktopSink: Boolean): PointerDispatcher {
        whenever(uhid.routing).thenReturn(PointerRouting.SYSTEM_ROUTED)
        whenever(inputManager.routing).thenReturn(PointerRouting.EXPLICIT_DISPLAY)
        return PointerDispatcher(log, uhid, inputManager) { desktopSink }
    }

    @Test
    fun autoPrefersUhidOnDesktopSinkTargets() {
        whenever(uhid.selectSystemRoute()).thenReturn(true)
        whenever(uhid.moveRelative(5, 6)).thenReturn(PointerDelivery.DELIVERED)

        val dispatcher = auto(desktopSink = true)

        assertTrue(dispatcher.selectDisplay(display))
        assertEquals(PointerDelivery.DELIVERED, dispatcher.moveRelative(5, 6))
        // The UHID contract must stay honest: system routing never claims a
        // target-specific selection.
        verify(uhid, never()).selectDisplay(any())
    }

    @Test
    fun autoUsesInputManagerWhenTargetIsNotADesktopSink() {
        whenever(inputManager.selectDisplay(any())).thenReturn(true)
        whenever(inputManager.moveRelative(5, 6)).thenReturn(PointerDelivery.DELIVERED)

        val dispatcher = auto(desktopSink = false)

        assertTrue(dispatcher.selectDisplay(display))
        assertEquals(PointerDelivery.DELIVERED, dispatcher.moveRelative(5, 6))
        verify(uhid, never()).selectSystemRoute()
    }

    @Test
    fun autoFallsBackToInputManagerWhenUhidIsUnavailable() {
        whenever(uhid.selectSystemRoute()).thenReturn(false)
        whenever(inputManager.selectDisplay(any())).thenReturn(true)
        whenever(inputManager.moveRelative(5, 6)).thenReturn(PointerDelivery.DELIVERED)

        val dispatcher = auto(desktopSink = true)

        assertTrue(dispatcher.selectDisplay(display))
        assertEquals(PointerDelivery.DELIVERED, dispatcher.moveRelative(5, 6))
        verify(uhid).close()
    }

    @Test
    fun forcedUhidUsesSystemRoutingAndIgnoresTargetSelection() {
        whenever(uhid.selectSystemRoute()).thenReturn(true)

        val dispatcher = PointerDispatcher(log, uhid, inputManager, PointerBackendMode.UHID)

        assertTrue(dispatcher.selectDisplay(display))
        verify(uhid).selectSystemRoute()
        verify(uhid, never()).selectDisplay(any())
        assertFalse(dispatcher.supportsExplicitDisplayRouting)
    }

    @Test
    fun forcedUhidFailsWhenTheDeviceCannotBeCreated() {
        whenever(uhid.selectSystemRoute()).thenReturn(false)

        val dispatcher = PointerDispatcher(log, uhid, inputManager, PointerBackendMode.UHID)

        assertFalse(dispatcher.selectDisplay(display))
        assertEquals(PointerDelivery.FAILED, dispatcher.moveRelative(1, 1))
    }

    @Test
    fun forcedUhidDoesNotAdvertiseInputManagerRoutingCapability() {
        whenever(uhid.routing).thenReturn(PointerRouting.SYSTEM_ROUTED)
        whenever(inputManager.routing).thenReturn(PointerRouting.EXPLICIT_DISPLAY)

        val dispatcher = PointerDispatcher(log, uhid, inputManager, PointerBackendMode.UHID)

        assertFalse(dispatcher.supportsExplicitDisplayRouting)
    }

    @Test
    fun forcedInputManagerAdvertisesExplicitRoutingWhenAvailable() {
        whenever(inputManager.routing).thenReturn(PointerRouting.EXPLICIT_DISPLAY)
        whenever(inputManager.supportsExplicitDisplayRouting).thenReturn(true)

        val dispatcher = PointerDispatcher(log, uhid, inputManager, PointerBackendMode.INPUT_MANAGER)

        assertTrue(dispatcher.supportsExplicitDisplayRouting)
    }

    @Test
    fun autoAdvertisesExplicitRoutingWhenInputManagerIsAvailable() {
        whenever(uhid.routing).thenReturn(PointerRouting.SYSTEM_ROUTED)
        whenever(inputManager.routing).thenReturn(PointerRouting.EXPLICIT_DISPLAY)
        whenever(inputManager.supportsExplicitDisplayRouting).thenReturn(true)

        val dispatcher = PointerDispatcher(log, uhid, inputManager, PointerBackendMode.AUTO)

        assertTrue(dispatcher.supportsExplicitDisplayRouting)
    }

    @Test
    fun uhidFailureWhileIdleRetriesOnceOnInputManagerFallback() {
        whenever(uhid.selectSystemRoute()).thenReturn(true)
        whenever(uhid.moveRelative(5, 6)).thenReturn(PointerDelivery.FAILED)
        whenever(inputManager.selectDisplay(any())).thenReturn(true)
        whenever(inputManager.moveRelative(5, 6)).thenReturn(PointerDelivery.DELIVERED)

        val dispatcher = auto(desktopSink = true)
        dispatcher.selectDisplay(display)

        assertEquals(PointerDelivery.DELIVERED, dispatcher.moveRelative(5, 6))
        verify(uhid).close()
        verify(inputManager, times(1)).moveRelative(5, 6)
    }

    @Test
    fun partialUhidDeliverySwitchesBackendWithoutRetrying() {
        whenever(uhid.selectSystemRoute()).thenReturn(true)
        whenever(uhid.moveRelative(300, 0)).thenReturn(
            PointerDelivery.partiallyDeliveredMovement(dx = 200, dy = 0),
        )
        whenever(inputManager.selectDisplay(any())).thenReturn(true)
        whenever(inputManager.moveRelative(3, 4)).thenReturn(PointerDelivery.DELIVERED)

        val dispatcher = auto(desktopSink = true)
        dispatcher.selectDisplay(display)

        // A partial multi-report move is never retried on the fallback: that
        // would duplicate already-accepted movement.
        assertEquals(
            PointerDelivery.Status.PARTIALLY_DELIVERED,
            dispatcher.moveRelative(300, 0).status,
        )
        verify(inputManager, never()).moveRelative(any(), any())

        // The switch is sticky: the next event goes straight to InputManager.
        assertEquals(PointerDelivery.DELIVERED, dispatcher.moveRelative(3, 4))
        verify(uhid, times(1)).close()
    }

    @Test
    fun failoverWhileButtonHeldContinuesOnInputManagerFallback() {
        whenever(uhid.selectSystemRoute()).thenReturn(true)
        whenever(uhid.button(eq(0), eq(true))).thenReturn(PointerDelivery.DELIVERED)
        whenever(uhid.moveRelative(2, 2)).thenReturn(PointerDelivery.FAILED)
        whenever(inputManager.selectDisplay(any())).thenReturn(true)
        whenever(inputManager.moveRelative(2, 2)).thenReturn(PointerDelivery.DELIVERED)
        whenever(inputManager.button(eq(0), eq(false))).thenReturn(PointerDelivery.DELIVERED)

        val dispatcher = auto(desktopSink = true)
        dispatcher.selectDisplay(display)

        assertEquals(PointerDelivery.DELIVERED, dispatcher.button(0, true))
        // Mid-drag failure releases the UHID device (best-effort release
        // report happens inside close()) and switches backends.
        assertEquals(PointerDelivery.DELIVERED, dispatcher.moveRelative(2, 2))
        // The subsequent release is served by InputManager, not lost.
        assertEquals(PointerDelivery.DELIVERED, dispatcher.button(0, false))
        verify(uhid).close()
        verify(inputManager, times(1)).button(0, false)
    }

    @Test
    fun scrollFailoverRetriesOnceOnInputManager() {
        whenever(uhid.selectSystemRoute()).thenReturn(true)
        whenever(uhid.scroll(1f, 0f)).thenReturn(PointerDelivery.FAILED)
        whenever(inputManager.selectDisplay(any())).thenReturn(true)
        whenever(inputManager.scroll(1f, 0f)).thenReturn(PointerDelivery.DELIVERED)

        val dispatcher = auto(desktopSink = true)
        dispatcher.selectDisplay(display)

        assertEquals(PointerDelivery.DELIVERED, dispatcher.scroll(1f, 0f))
        verify(uhid).close()
        verify(inputManager, times(1)).scroll(1f, 0f)
    }

    @Test
    fun nextSelectDisplayStartsANewSelectionEpoch() {
        whenever(uhid.selectSystemRoute()).thenReturn(true)
        whenever(uhid.moveRelative(1, 0)).thenReturn(PointerDelivery.FAILED)
        whenever(inputManager.selectDisplay(any())).thenReturn(true)
        whenever(inputManager.moveRelative(1, 0)).thenReturn(PointerDelivery.DELIVERED)
        whenever(uhid.moveRelative(7, 8)).thenReturn(PointerDelivery.DELIVERED)

        val dispatcher = auto(desktopSink = true)
        dispatcher.selectDisplay(display)
        assertEquals(PointerDelivery.DELIVERED, dispatcher.moveRelative(1, 0))

        // A new SELECT_DISPLAY re-evaluates UHID instead of staying degraded.
        assertTrue(dispatcher.selectDisplay(display))
        assertEquals(PointerDelivery.DELIVERED, dispatcher.moveRelative(7, 8))
        verify(inputManager, times(1)).selectDisplay(any())
    }
}
