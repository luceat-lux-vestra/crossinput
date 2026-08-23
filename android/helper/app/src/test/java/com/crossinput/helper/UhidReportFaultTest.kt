package com.crossinput.helper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UhidReportFaultTest {
    @Test
    fun disabledByDefaultNeverFails() {
        val fault = UhidReportFault(0)
        assertFalse(fault.enabled)
        repeat(100) { assertFalse(fault.shouldFail()) }
    }

    @Test
    fun failsExactlyOnNthAttempt() {
        val fault = UhidReportFault(3)
        assertTrue(fault.enabled)
        assertFalse(fault.shouldFail())
        assertFalse(fault.shouldFail())
        assertTrue(fault.shouldFail())
        for (i in 4..20) {
            assertFalse("attempt $i must not fail", fault.shouldFail())
        }
    }

    @Test
    fun thresholdOneFailsFirstAttemptOnly() {
        val fault = UhidReportFault(1)
        assertTrue(fault.shouldFail())
        assertFalse(fault.shouldFail())
    }
}
