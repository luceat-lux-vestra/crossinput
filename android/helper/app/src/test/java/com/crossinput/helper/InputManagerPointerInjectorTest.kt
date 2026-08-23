package com.crossinput.helper

import android.content.Context
import android.hardware.input.InputManager
import android.view.Display
import android.view.MotionEvent
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import org.mockito.ArgumentMatchers.any
import org.mockito.ArgumentMatchers.anyInt
import org.mockito.Mockito
import org.mockito.MockedStatic
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever

/**
 * Unit coverage for InputManager button semantics (issue #57, finding 2).
 *
 * `MotionEvent` is final and the stock android.jar throws "Stub!" at runtime,
 * so [MotionEvent.obtain] is statically mocked: each call yields an event
 * mock that records its construction arguments plus any later
 * setActionButton mutation. Every [InputManagerPointerInjector.button] call
 * therefore produces exactly one captured snapshot — the same object the
 * reflective injectInputEvent boundary would hand the system.
 *
 * Contract asserted (Android MotionEvent mouse semantics):
 * - left click rides ACTION_DOWN/ACTION_UP (touch-like primary click),
 * - right/middle ride ACTION_BUTTON_PRESS/ACTION_BUTTON_RELEASE with the
 *   matching actionButton (Samsung's DeX pipeline rejects press/release
 *   events whose actionButton disagrees with buttonState),
 * - buttonState accumulates across held buttons and clears on release,
 * - close() leaves no stuck buttons behind.
 */
class InputManagerPointerInjectorTest {
    private val log: Logger = mock()

    /** Semantic snapshot of one built MotionEvent. */
    private data class Injected(
        val action: Int,
        var buttonState: Int,
        var actionButton: Int,
    )

    private lateinit var staticMock: MockedStatic<MotionEvent>
    private val captured = mutableListOf<Injected>()

    private fun newInjector(): InputManagerPointerInjector {
        captured.clear()
        staticMock = Mockito.mockStatic(
            MotionEvent::class.java,
            Mockito.withSettings().defaultAnswer { invocation ->
                val snapshot = Injected(
                    action = invocation.getArgument<Int>(2),
                    buttonState = invocation.getArgument<Int>(7),
                    actionButton = 0,
                )
                captured += snapshot
                val event = Mockito.mock(MotionEvent::class.java)
                whenever(event.action).thenReturn(snapshot.action)
                whenever(event.buttonState).thenAnswer { snapshot.buttonState }
                whenever(event.actionButton).thenAnswer { snapshot.actionButton }
                event
            },
        )
        // Any MotionEvent.obtain(...) overload routes to the default answer
        // above, which records the 14-arg call's action/buttonState.

        val display = Mockito.mock(Display::class.java)
        whenever(display.displayId).thenReturn(2)
        whenever(display.getRealMetrics(any())).then { invocation ->
            val m = invocation.getArgument<android.util.DisplayMetrics>(0)
            m.widthPixels = 1920
            m.heightPixels = 1080
            Unit
        }
        val context = Mockito.mock(Context::class.java)
        whenever(context.getSystemService(Context.INPUT_SERVICE))
            .thenReturn(Mockito.mock(InputManager::class.java))

        // Test seams: apply actionButton straight onto the snapshot and accept
        // every injection (the reflective hidden API is absent on host JVM).
        val actionButtonSetter = ActionButtonSetter { _, button ->
            captured.lastOrNull()?.actionButton = button
        }
        val displayIdSetter = DisplayIdSetter { _, _ -> true }
        val eventInjector = MotionEventInjector { true }
        return InputManagerPointerInjector(log, context, actionButtonSetter, displayIdSetter, eventInjector)
            .also { it.selectDisplay(display) }
    }

    @After
    fun tearDown() {
        if (::staticMock.isInitialized) staticMock.close()
    }

    private fun InputManagerPointerInjector.press(button: Int): Injected {
        assertEquals(PointerDelivery.DELIVERED, this.button(button, true))
        return captured.last()
    }

    private fun InputManagerPointerInjector.release(button: Int): Injected {
        assertEquals(PointerDelivery.DELIVERED, this.button(button, false))
        return captured.last()
    }

    @Test
    fun leftClickUsesActionDownUpWithoutActionButton() {
        val injector = newInjector()

        val down = injector.press(0)
        val up = injector.release(0)

        assertEquals(MotionEvent.ACTION_DOWN, down.action)
        assertEquals(MotionEvent.BUTTON_PRIMARY, down.buttonState)
        assertEquals(0, down.actionButton)
        assertEquals(MotionEvent.ACTION_UP, up.action)
        assertEquals(0, up.buttonState)
    }

    @Test
    fun rightClickUsesButtonPressReleaseWithMatchingActionButton() {
        val injector = newInjector()

        val down = injector.press(1)
        val up = injector.release(1)

        assertEquals(MotionEvent.ACTION_BUTTON_PRESS, down.action)
        assertEquals(MotionEvent.BUTTON_SECONDARY, down.buttonState)
        assertEquals(MotionEvent.BUTTON_SECONDARY, down.actionButton)
        assertEquals(MotionEvent.ACTION_BUTTON_RELEASE, up.action)
        assertEquals(0, up.buttonState)
        assertEquals(MotionEvent.BUTTON_SECONDARY, up.actionButton)
    }

    @Test
    fun middleClickUsesButtonPressReleaseWithMatchingActionButton() {
        val injector = newInjector()

        val down = injector.press(2)
        val up = injector.release(2)

        assertEquals(MotionEvent.ACTION_BUTTON_PRESS, down.action)
        assertEquals(MotionEvent.BUTTON_TERTIARY, down.buttonState)
        assertEquals(MotionEvent.BUTTON_TERTIARY, down.actionButton)
        assertEquals(MotionEvent.ACTION_BUTTON_RELEASE, up.action)
        assertEquals(0, up.buttonState)
        assertEquals(MotionEvent.BUTTON_TERTIARY, up.actionButton)
    }

    @Test
    fun buttonStateAccumulatesAcrossHeldButtonsAndClearsOnRelease() {
        val injector = newInjector()

        val leftDown = injector.press(0)
        val rightDown = injector.press(1)
        val middleDown = injector.press(2)

        assertEquals(MotionEvent.BUTTON_PRIMARY, leftDown.buttonState)
        assertEquals(
            MotionEvent.BUTTON_PRIMARY or MotionEvent.BUTTON_SECONDARY,
            rightDown.buttonState,
        )
        assertEquals(
            MotionEvent.BUTTON_PRIMARY or MotionEvent.BUTTON_SECONDARY or
                MotionEvent.BUTTON_TERTIARY,
            middleDown.buttonState,
        )

        injector.release(1)
        injector.release(2)
        val lastUp = injector.release(0)
        assertEquals(0, lastUp.buttonState)
    }

    @Test
    fun multipleSequentialClicksKeepConsistentState() {
        val injector = newInjector()
        repeat(3) {
            injector.press(1)
            val up = injector.release(1)
            assertEquals(0, up.buttonState)
        }
        assertEquals(6, captured.size)
    }

    @Test
    fun closeAfterHeldButtonsBuildsNoStuckEvents() {
        val injector = newInjector()
        injector.press(0)
        injector.press(1)

        injector.close()

        // Held-button cleanup is the UhidPointerInjector contract (kernel
        // device); the InputManager backend holds no virtual device, so close
        // must simply tear down selection state without emitting events.
        assertEquals(2, captured.size)
    }
}
