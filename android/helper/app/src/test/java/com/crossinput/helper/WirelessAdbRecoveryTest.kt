package com.crossinput.helper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WirelessAdbRecoveryTest {

    @Test
    fun unsupportedPlatformStopsWithoutTouchingSetting() {
        val store = FakeStore(supported = false, enabled = false)
        val outcome = recovery(store, wifiConnected = true).run()

        assertEquals(WirelessAdbRecoveryOutcome.UNSUPPORTED, outcome)
        assertEquals(0, store.reads)
        assertEquals(0, store.writes)
    }

    @Test
    fun missingWifiRequestsRetryWithoutTouchingSetting() {
        val store = FakeStore(supported = true, enabled = false)
        val outcome = recovery(store, wifiConnected = false).run()

        assertEquals(WirelessAdbRecoveryOutcome.RETRY, outcome)
        assertEquals(0, store.reads)
        assertEquals(0, store.writes)
    }

    @Test
    fun alreadyEnabledIsIdempotentSuccess() {
        val store = FakeStore(supported = true, enabled = true)
        val outcome = recovery(store, wifiConnected = true).run()

        assertEquals(WirelessAdbRecoveryOutcome.ALREADY_ENABLED, outcome)
        assertEquals(1, store.reads)
        assertEquals(0, store.writes)
    }

    @Test
    fun disabledSettingIsEnabledAndVerified() {
        val store = FakeStore(supported = true, enabled = false)
        var slept = false
        val outcome = WirelessAdbRecovery(
            settingStore = store,
            wifiConnected = { true },
            sleep = { delay ->
                assertEquals(WIRELESS_ADB_VERIFY_DELAY_MS, delay)
                slept = true
            },
        ).run()

        assertEquals(WirelessAdbRecoveryOutcome.ENABLED, outcome)
        assertTrue(slept)
        assertEquals(2, store.reads)
        assertEquals(1, store.writes)
        assertTrue(store.enabled)
    }

    @Test
    fun failedWriteRequestsRetry() {
        val store = FakeStore(supported = true, enabled = false, writeSucceeds = false)
        val outcome = recovery(store, wifiConnected = true).run()

        assertEquals(WirelessAdbRecoveryOutcome.RETRY, outcome)
        assertEquals(1, store.reads)
        assertEquals(1, store.writes)
        assertFalse(store.enabled)
    }

    @Test
    fun settingClearedAfterWriteRequestsRetry() {
        val store = FakeStore(
            supported = true,
            enabled = false,
            clearAfterSuccessfulWrite = true,
        )
        val outcome = recovery(store, wifiConnected = true).run()

        assertEquals(WirelessAdbRecoveryOutcome.RETRY, outcome)
        assertEquals(2, store.reads)
        assertEquals(1, store.writes)
        assertFalse(store.enabled)
    }

    @Test
    fun securityExceptionIsPermanentPermissionFailure() {
        val store = FakeStore(
            supported = true,
            enabled = false,
            throwSecurityExceptionOnRead = true,
        )
        val outcome = recovery(store, wifiConnected = true).run()

        assertEquals(WirelessAdbRecoveryOutcome.PERMISSION_DENIED, outcome)
        assertEquals(1, store.reads)
        assertEquals(0, store.writes)
    }

    private fun recovery(store: FakeStore, wifiConnected: Boolean) =
        WirelessAdbRecovery(
            settingStore = store,
            wifiConnected = { wifiConnected },
            sleep = {},
        )

    private class FakeStore(
        private val supported: Boolean,
        var enabled: Boolean,
        private val writeSucceeds: Boolean = true,
        private val clearAfterSuccessfulWrite: Boolean = false,
        private val throwSecurityExceptionOnRead: Boolean = false,
    ) : WirelessAdbSettingStore {
        var reads = 0
            private set
        var writes = 0
            private set

        override fun isSupported(): Boolean = supported

        override fun isEnabled(): Boolean {
            reads++
            if (throwSecurityExceptionOnRead) throw SecurityException("denied")
            return enabled
        }

        override fun setEnabled(enabled: Boolean): Boolean {
            writes++
            if (!writeSucceeds) return false
            this.enabled = if (clearAfterSuccessfulWrite) false else enabled
            return true
        }
    }
}
