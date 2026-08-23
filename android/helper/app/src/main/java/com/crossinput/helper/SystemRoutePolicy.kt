package com.crossinput.helper

import android.view.Display

/**
 * Conservative routing heuristic for AUTO backend selection: whether the
 * target display looks like a desktop system sink (e.g. Samsung DeX), where
 * Android routes /dev/uhid mice through the native InputReader pipeline so
 * the visible pointer sprite follows the virtual device.
 *
 * FLAG_DESKTOP is a display classification, not a formal guarantee that the
 * system pointer controller serves that display. False negatives degrade to
 * explicit InputManager injection; false positives would deliver system-
 * routed input without a selected target, so any reflection failure answers
 * false. Hidden android.view.DisplayInfo access stays isolated in this
 * adapter (AGENTS.md rule 9).
 */
internal object SystemRoutePolicy {
    fun isDesktopSink(display: Display): Boolean = try {
        val diClass = Class.forName("android.view.DisplayInfo")
        val di = diClass.newInstance()
        display.javaClass.getMethod("getDisplayInfo", diClass).invoke(display, di)
        val flags = diClass.getField("flags").getLong(di)
        flags and FLAG_DESKTOP != 0L
    } catch (_: Throwable) {
        false
    }

    // android.view.Display.FLAG_DESKTOP is hidden; read reflectively and
    // fall back to the AOSP constant if absent (mirrors DisplayDiscovery).
    private val FLAG_DESKTOP: Long by lazy {
        try {
            Display::class.java.getField("FLAG_DESKTOP").getLong(null)
        } catch (_: Throwable) {
            0x40L
        }
    }
}
