package com.crossinput.helper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Argument parsing for the test-only `--keyboard-backend` override.
 *
 * A silently-ignored override is the dangerous failure: the helper would run
 * AUTO while the operator believes a backend is forced, and the verification
 * run would measure the wrong path. Both spellings must therefore work, and an
 * unusable value must fail loudly instead of defaulting.
 */
class KeyboardBackendModeTest {

    private fun parse(vararg args: String) = KeyboardBackendMode.fromArgs(args)

    @Test
    fun noFlagMeansAuto() {
        assertEquals(KeyboardBackendMode.AUTO, parse().getOrThrow())
        assertEquals(KeyboardBackendMode.AUTO, parse("--other", "value").getOrThrow())
    }

    @Test
    fun equalsFormIsAccepted() {
        assertEquals(KeyboardBackendMode.UHID, parse("--keyboard-backend=uhid").getOrThrow())
        assertEquals(
            KeyboardBackendMode.INPUT_MANAGER,
            parse("--keyboard-backend=input-manager").getOrThrow(),
        )
        assertEquals(KeyboardBackendMode.AUTO, parse("--keyboard-backend=auto").getOrThrow())
    }

    @Test
    fun spaceSeparatedFormIsAccepted() {
        assertEquals(KeyboardBackendMode.UHID, parse("--keyboard-backend", "uhid").getOrThrow())
        assertEquals(
            KeyboardBackendMode.INPUT_MANAGER,
            parse("--keyboard-backend", "input-manager").getOrThrow(),
        )
    }

    @Test
    fun valueIsCaseInsensitive() {
        assertEquals(
            KeyboardBackendMode.INPUT_MANAGER,
            parse("--keyboard-backend=INPUT-MANAGER").getOrThrow(),
        )
    }

    @Test
    fun flagIsFoundAmongOtherArguments() {
        assertEquals(
            KeyboardBackendMode.UHID,
            parse("--verbose", "--keyboard-backend", "uhid", "--trailing").getOrThrow(),
        )
    }

    @Test
    fun unknownValueFails() {
        val result = parse("--keyboard-backend=virtual")
        assertTrue(result.isFailure)
        assertTrue(result.exceptionOrNull()!!.message!!.contains("auto|uhid|input-manager"))
    }

    @Test
    fun missingValueFails() {
        assertTrue(parse("--keyboard-backend").isFailure)
    }

    @Test
    fun emptyValueFails() {
        assertTrue(parse("--keyboard-backend=").isFailure)
    }

    @Test
    fun tokensMatchTheDocumentedSpelling() {
        // docs/testing.md and scripts/deploy-helper.sh use these spellings.
        assertEquals("auto", KeyboardBackendMode.AUTO.token)
        assertEquals("uhid", KeyboardBackendMode.UHID.token)
        assertEquals("input-manager", KeyboardBackendMode.INPUT_MANAGER.token)
    }
}
