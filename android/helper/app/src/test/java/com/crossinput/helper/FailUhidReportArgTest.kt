package com.crossinput.helper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FailUhidReportArgTest {
    @Test
    fun absentFlagMeansDisabled() {
        assertEquals(0, FailUhidReportArg.fromArgs(emptyArray()).getOrThrow())
    }

    @Test
    fun flagIsParsedInBothSpellings() {
        assertEquals(
            3,
            FailUhidReportArg.fromArgs(arrayOf("--pointer-backend=auto", "--fail-uhid-report=3")).getOrThrow(),
        )
        assertEquals(
            7,
            FailUhidReportArg.fromArgs(arrayOf("--fail-uhid-report", "7")).getOrThrow(),
        )
    }

    @Test
    fun invalidValuesFailLoudly() {
        assertTrue(FailUhidReportArg.fromArgs(arrayOf("--fail-uhid-report=abc")).isFailure)
        assertTrue(FailUhidReportArg.fromArgs(arrayOf("--fail-uhid-report=-1")).isFailure)
        assertTrue(FailUhidReportArg.fromArgs(arrayOf("--fail-uhid-report")).isFailure)
    }
}
