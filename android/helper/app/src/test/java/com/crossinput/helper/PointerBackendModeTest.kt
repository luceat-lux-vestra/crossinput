package com.crossinput.helper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PointerBackendModeTest {
    @Test
    fun absentModeUsesAutomaticSelection() {
        assertEquals(PointerBackendMode.AUTO, PointerBackendMode.fromArgs(emptyArray()).getOrThrow())
    }

    @Test
    fun forcedModesAreParsedAndUnknownValuesFail() {
        assertEquals(PointerBackendMode.UHID, PointerBackendMode.fromArgs(arrayOf("--pointer-backend=uhid")).getOrThrow())
        assertEquals(PointerBackendMode.INPUT_MANAGER,
            PointerBackendMode.fromArgs(arrayOf("--pointer-backend", "input-manager")).getOrThrow())
        assertTrue(PointerBackendMode.fromArgs(arrayOf("--pointer-backend=bad")).isFailure)
    }
}
