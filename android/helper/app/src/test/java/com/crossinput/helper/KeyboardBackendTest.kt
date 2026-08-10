package com.crossinput.helper

import android.content.Context
import android.view.KeyEvent
import com.crossinput.helper.protocol.Messages
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.Mockito.mockingDetails
import org.mockito.kotlin.any
import org.mockito.kotlin.atLeastOnce
import org.mockito.kotlin.argumentCaptor
import org.mockito.kotlin.eq
import org.mockito.kotlin.mock
import org.mockito.kotlin.never
import org.mockito.kotlin.times
import org.mockito.kotlin.verify
import org.mockito.kotlin.whenever

/**
 * Backend-selection and failure behavior of [KeyboardBackend].
 *
 * The virtual-injection path is exercised through a fake [VirtualKeyInjector]:
 * the real hidden API is absent from the unit-test android.jar, so without the
 * seam every test would take the "unavailable" branch and prove nothing.
 *
 * HID usage mapping is covered by KeyboardHidMapperTest; KEY_EVENT payload
 * parsing by protocol/CodecTest.
 */
class KeyboardBackendTest {

    private val log: Logger = mock()
    private val context: Context = mock()
    private val hid: HidDeviceManager = mock()

    private class FakeInjector(
        override val available: Boolean = true,
        private val accepts: Boolean = true,
        private val failWith: Throwable? = null,
    ) : VirtualKeyInjector {
        val events = mutableListOf<Messages.KeyEvent>()

        override fun inject(event: Messages.KeyEvent): Boolean {
            events += event
            failWith?.let { throw it }
            return accepts
        }
    }

    private class FailFirstReleaseInjector : VirtualKeyInjector {
        override val available: Boolean = true
        val events = mutableListOf<Messages.KeyEvent>()
        private var releaseAttempts = 0

        override fun inject(event: Messages.KeyEvent): Boolean {
            events += event
            if (event.action == 1 && releaseAttempts++ == 0) {
                throw SecurityException("release rejected")
            }
            return true
        }
    }

    private fun backend(
        mode: KeyboardBackendMode,
        injector: VirtualKeyInjector = FakeInjector(),
        uhidId: Int? = UHID_ID,
        reportSucceeds: Boolean = true,
    ): KeyboardBackend {
        whenever(hid.create(any(), any())).thenReturn(
            if (uhidId != null) Result.success(uhidId) else Result.failure(IllegalStateException("no uhid")),
        )
        whenever(hid.sendReport(any(), any())).thenReturn(reportSucceeds)
        return KeyboardBackend(log, context, hid, mode, injector)
    }

    /** Every message passed to the [Logger] mock, across all levels. */
    private fun logged(): List<String> =
        mockingDetails(log).invocations.map { it.arguments[1] as String }

    private fun sentReports(): List<ByteArray> {
        val reports = argumentCaptor<ByteArray>()
        verify(hid, atLeastOnce()).sendReport(any(), reports.capture())
        return reports.allValues
    }

    // --- AUTO (production default) ---------------------------------------

    @Test
    fun autoUsesUhidWhenAvailable() {
        val injector = FakeInjector()
        val backend = backend(KeyboardBackendMode.AUTO, injector)

        backend.keyEvent(down(KeyEvent.KEYCODE_A))

        verify(hid).sendReport(eq(UHID_ID), any())
        assertTrue("virtual injection must not run while UHID works", injector.events.isEmpty())
        assertTrue(logged().contains("keyboard backend selected backend=uhid mode=auto"))
    }

    @Test
    fun autoReportsKeyStateSoAKeyDoesNotRepeatAfterRelease() {
        val backend = backend(KeyboardBackendMode.AUTO)

        backend.keyEvent(down(KeyEvent.KEYCODE_A))
        backend.keyEvent(up(KeyEvent.KEYCODE_A))

        val reports = sentReports()
        assertEquals(2, reports.size)
        assertEquals(0x04, reports[0][2].toInt() and 0xFF) // A held
        assertEquals(0x00, reports[1][2].toInt() and 0xFF) // released: empty state report
    }

    @Test
    fun autoFallsBackToVirtualWhenUhidCreationFails() {
        val injector = FakeInjector()
        val backend = backend(KeyboardBackendMode.AUTO, injector, uhidId = null)

        backend.keyEvent(down(KeyEvent.KEYCODE_A))

        verify(hid, never()).sendReport(any(), any())
        assertEquals(1, injector.events.size)
        assertTrue(logged().contains("keyboard backend selected backend=input-manager mode=auto"))
    }

    @Test
    fun autoFallsBackToVirtualAfterAReportFailureAndStaysThere() {
        val injector = FakeInjector()
        val backend = backend(KeyboardBackendMode.AUTO, injector, reportSucceeds = false)

        backend.keyEvent(down(KeyEvent.KEYCODE_A))
        backend.keyEvent(up(KeyEvent.KEYCODE_A))

        // UHID is retried only once; after the failure the session is virtual.
        verify(hid, times(1)).sendReport(any(), any())
        assertEquals(2, injector.events.size)
    }

    @Test
    fun autoFallbackReleasesAcceptedVirtualDownOnDestroy() {
        val injector = FakeInjector()
        val backend = backend(KeyboardBackendMode.AUTO, injector, uhidId = null)

        backend.keyEvent(down(KeyEvent.KEYCODE_A))
        backend.destroy()

        assertEquals(listOf(0, 1), injector.events.map { it.action })
    }

    @Test
    fun autoRoutesUnmappableKeyCodesToVirtualInjection() {
        val injector = FakeInjector()
        val backend = backend(KeyboardBackendMode.AUTO, injector)

        backend.keyEvent(down(KeyEvent.KEYCODE_VOLUME_UP)) // no HID usage

        verify(hid, never()).sendReport(any(), any())
        assertEquals(1, injector.events.size)
    }

    // --- forced UHID ------------------------------------------------------

    @Test
    fun forcedUhidNeverFallsBackToVirtual() {
        val injector = FakeInjector()
        val backend = backend(KeyboardBackendMode.UHID, injector, uhidId = null)

        backend.keyEvent(down(KeyEvent.KEYCODE_A))

        assertTrue("forced uhid must not silently become virtual", injector.events.isEmpty())
        assertTrue(logged().contains("keyboard backend selected backend=uhid mode=forced"))
    }

    @Test
    fun forcedUhidDropsUnmappableKeyCodeInsteadOfInjecting() {
        val injector = FakeInjector()
        val backend = backend(KeyboardBackendMode.UHID, injector)

        backend.keyEvent(down(KeyEvent.KEYCODE_VOLUME_UP))

        verify(hid, never()).sendReport(any(), any())
        assertTrue(injector.events.isEmpty())
    }

    @Test
    fun forcedUhidSurvivesReportFailure() {
        val injector = FakeInjector()
        val backend = backend(KeyboardBackendMode.UHID, injector, reportSucceeds = false)

        backend.keyEvent(down(KeyEvent.KEYCODE_A)) // must not throw
        backend.keyEvent(up(KeyEvent.KEYCODE_A))

        assertTrue(injector.events.isEmpty())
    }

    // --- forced InputManager (the path issue #33 verifies) ----------------

    @Test
    fun forcedInputManagerNeverCreatesOrUsesUhid() {
        val injector = FakeInjector()
        val backend = backend(KeyboardBackendMode.INPUT_MANAGER, injector)

        backend.keyEvent(down(KeyEvent.KEYCODE_A))
        backend.keyEvent(up(KeyEvent.KEYCODE_A))

        verify(hid, never()).create(any(), any())
        verify(hid, never()).sendReport(any(), any())
        assertEquals(listOf(0, 1), injector.events.map { it.action }) // exactly one down, one up
        assertTrue(logged().contains("keyboard backend selected backend=input-manager mode=forced"))
    }

    @Test
    fun forcedInputManagerDestroySynthesizesOneUpForAcceptedDown() {
        val injector = FakeInjector()
        val backend = backend(KeyboardBackendMode.INPUT_MANAGER, injector)

        backend.keyEvent(down(KeyEvent.KEYCODE_A))
        backend.destroy()

        assertEquals(listOf(0, 1), injector.events.map { it.action })
    }

    @Test
    fun acceptedVirtualUpPreventsDuplicateUpDuringDestroy() {
        val injector = FakeInjector()
        val backend = backend(KeyboardBackendMode.INPUT_MANAGER, injector)

        backend.keyEvent(down(KeyEvent.KEYCODE_A))
        backend.keyEvent(up(KeyEvent.KEYCODE_A))
        backend.destroy()

        assertEquals(listOf(0, 1), injector.events.map { it.action })
    }

    @Test
    fun failedVirtualCleanupUpDoesNotAbortRemainingKeysAndCanBeRetried() {
        val injector = FailFirstReleaseInjector()
        val backend = backend(KeyboardBackendMode.INPUT_MANAGER, injector)

        backend.keyEvent(down(KeyEvent.KEYCODE_A))
        backend.keyEvent(down(KeyEvent.KEYCODE_B))
        backend.destroy()

        // The first UP fails, but the second held key is still attempted.
        assertEquals(listOf(0, 0, 1, 1), injector.events.map { it.action })
        assertTrue(logged().any { it.contains("SecurityException") })
        for (message in logged()) {
            assertFalse(message.contains("keyCode"))
            assertFalse(message.contains("metaState"))
            assertFalse(message.contains("payload"))
        }

        // The failed key remains held and is retried by an idempotent destroy.
        backend.destroy()
        assertEquals(listOf(0, 0, 1, 1, 1), injector.events.map { it.action })
    }

    @Test
    fun forcedInputManagerPassesKeyCodeAndModifiersThrough() {
        val injector = FakeInjector()
        val backend = backend(KeyboardBackendMode.INPUT_MANAGER, injector)

        backend.keyEvent(down(KeyEvent.KEYCODE_A, KeyEvent.META_SHIFT_ON or KeyEvent.META_CTRL_ON))

        val event = injector.events.single()
        assertEquals(KeyEvent.KEYCODE_A, event.keyCode)
        assertEquals(KeyEvent.META_SHIFT_ON or KeyEvent.META_CTRL_ON, event.metaState)
    }

    @Test
    fun unavailableInjectionApiFailsSafeAndLogsOnce() {
        val injector = FakeInjector(available = false)
        val backend = backend(KeyboardBackendMode.INPUT_MANAGER, injector)

        repeat(3) { backend.keyEvent(down(KeyEvent.KEYCODE_A)) } // must not throw

        assertTrue(injector.events.isEmpty())
        val unavailable = logged().filter { it.contains("virtual key injection unavailable") }
        assertEquals("unavailable API must not spam the log", 1, unavailable.size)
    }

    @Test
    fun securityExceptionIsContainedAndTheSessionKeepsAcceptingEvents() {
        val injector = FakeInjector(failWith = SecurityException("INJECT_EVENTS denied"))
        val backend = backend(KeyboardBackendMode.INPUT_MANAGER, injector)

        backend.keyEvent(down(KeyEvent.KEYCODE_A)) // must not throw
        backend.keyEvent(up(KeyEvent.KEYCODE_A))

        assertEquals("session must stay alive and keep delivering", 2, injector.events.size)
        assertTrue(logged().any { it.contains("SecurityException") })
    }

    @Test
    fun rejectedInjectionIsLoggedWithoutAborting() {
        val injector = FakeInjector(accepts = false)
        val backend = backend(KeyboardBackendMode.INPUT_MANAGER, injector)

        backend.keyEvent(down(KeyEvent.KEYCODE_A))

        assertTrue(logged().any { it.contains("rejected") })
    }

    // --- shutdown ---------------------------------------------------------

    @Test
    fun destroyReleasesHeldKeysBeforeDestroyingTheDevice() {
        val backend = backend(KeyboardBackendMode.AUTO)

        backend.keyEvent(down(KeyEvent.KEYCODE_A)) // left held
        backend.destroy()

        val last = sentReports().last()
        assertTrue("shutdown must leave no stuck key", last.all { it.toInt() == 0 })
        verify(hid).destroy(UHID_ID)
    }

    // --- AGENTS.md rule 4 -------------------------------------------------

    @Test
    fun logsCarryMetadataOnlyAndNeverKeyCodes() {
        val injector = FakeInjector(failWith = SecurityException("denied"))
        val backend = backend(KeyboardBackendMode.INPUT_MANAGER, injector)
        val secret = KeyEvent.KEYCODE_NUMPAD_7 // distinctive value: 151

        backend.keyEvent(down(secret, KeyEvent.META_CTRL_ON))
        backend.keyEvent(up(secret, KeyEvent.META_CTRL_ON))
        backend.destroy()

        val messages = logged()
        assertTrue("expected the failure path to log at all", messages.isNotEmpty())
        for (message in messages) {
            assertFalse("key code leaked: $message", message.contains(secret.toString()))
            assertFalse("meta state leaked: $message", message.contains(KeyEvent.META_CTRL_ON.toString()))
            assertFalse("payload leaked: $message", message.contains("keyCode"))
            assertFalse("payload leaked: $message", message.contains("usage"))
        }
    }

    private companion object {
        const val UHID_ID = 7

        fun down(keyCode: Int, metaState: Int = 0) = Messages.KeyEvent(keyCode, metaState, 0, 0)
        fun up(keyCode: Int, metaState: Int = 0) = Messages.KeyEvent(keyCode, metaState, 1, 0)
    }
}
