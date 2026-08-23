package com.crossinput.helper

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit coverage for the AUTO desktop-sink classification (issue #57).
 *
 * [android.view.DisplayInfo] is @hide and absent from the host-JVM test
 * classpath, so the suite exercises [SystemRoutePolicy.classify] — the pure
 * decision the reflective adapter feeds. The reflective fail-closed wrapper
 * (`isDesktopSink`) is covered by `reflectionFailureAnswersFalse` semantics:
 * any missing class/method answers false by construction (try/catch).
 */
class SystemRoutePolicyTest {
    // ---- Rule 1: explicit desktop flag ------------------------------------

    @Test
    fun explicitDesktopFlagClassifiesAsDesktop() {
        assertTrue(
            SystemRoutePolicy.classify(
                flags = FLAG_DESKTOP,
                type = TYPE_BUILT_IN,
                name = "Built-in",
                uniqueId = "local:0",
            ),
        )
    }

    @Test
    fun desktopFlagWinsRegardlessOfTypeOrName() {
        assertTrue(
            SystemRoutePolicy.classify(
                flags = FLAG_DESKTOP,
                type = TYPE_HDMI,
                name = "Whatever",
                uniqueId = "hdmi:0",
            ),
        )
    }

    // ---- Rule 2: Samsung DeX virtual desktop -------------------------------

    @Test
    fun samsungStyleVirtualDisplayNamedDesktopClassifiesAsDesktop() {
        // Observed DeX-for-PC topology (SM-G977N): type VIRTUAL, Samsung
        // family flags WITHOUT the AOSP FLAG_DESKTOP bit.
        assertTrue(
            SystemRoutePolicy.classify(
                flags = SAMSUNG_DEX_FLAGS_NO_FLAG_DESKTOP,
                type = TYPE_VIRTUAL,
                name = "Desktop",
                uniqueId = "virtual:android,1000,Desktop,0",
            ),
        )
    }

    // ---- Negative cases -----------------------------------------------------

    @Test
    fun ordinaryVirtualPresentationDisplayIsNotADesktopSink() {
        assertFalse(
            SystemRoutePolicy.classify(
                flags = 0L,
                type = TYPE_VIRTUAL,
                name = "Presentation Screen",
                uniqueId = "virtual:com.example.presenter,10042,Presentation Screen,0",
            ),
        )
    }

    @Test
    fun virtualDisplayWithDesktopNameButForeignUniqueIdIsNotADesktopSink() {
        // An app-owned surface that merely calls itself "Desktop" must not
        // claim the system-routing sink role.
        assertFalse(
            SystemRoutePolicy.classify(
                flags = 0L,
                type = TYPE_VIRTUAL,
                name = "Desktop",
                uniqueId = "virtual:com.example.app,10069,Desktop,0",
            ),
        )
    }

    @Test
    fun desktopNameWithSystemOwnerButDifferentSurfaceIsNotADesktopSink() {
        // The uniqueId anchor requires the exact system-owned Desktop segment;
        // other uid-1000 surfaces stay out.
        assertFalse(
            SystemRoutePolicy.classify(
                flags = 0L,
                type = TYPE_VIRTUAL,
                name = "Overlay",
                uniqueId = "virtual:android,1000,Overlay,0",
            ),
        )
    }

    @Test
    fun builtInDisplayIsNotADesktopSink() {
        assertFalse(
            SystemRoutePolicy.classify(
                flags = 0L,
                type = TYPE_BUILT_IN,
                name = "Built-in Screen",
                uniqueId = "local:0",
            ),
        )
    }

    @Test
    fun hdmiExternalDisplayIsNotADesktopSink() {
        assertFalse(
            SystemRoutePolicy.classify(
                flags = 0L,
                type = TYPE_HDMI,
                name = "HDMI Screen",
                uniqueId = "hdmi:0",
            ),
        )
    }

    @Test
    fun emptyReflectionSentinelsAreNotADesktopSink() {
        // DisplayDiscovery's failure sentinels (-1/"" ) must never classify.
        assertFalse(SystemRoutePolicy.classify(flags = 0L, type = -1, name = "", uniqueId = ""))
    }

    private companion object {
        // android.view.Display hidden constants (AOSP values; the production
        // policy resolves them reflectively at runtime where available).
        const val FLAG_DESKTOP = 0x40L
        const val TYPE_BUILT_IN = 1
        const val TYPE_HDMI = 2
        const val TYPE_VIRTUAL = 5

        // Observed on SM-G977N DeX-for-PC: FLAG_SECURE | FLAG_OWN_CONTENT_ONLY
        // -family bits present, AOSP FLAG_DESKTOP bit absent.
        const val SAMSUNG_DEX_FLAGS_NO_FLAG_DESKTOP = 0x20000002L
    }
}
