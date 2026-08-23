package com.crossinput.helper

import android.view.Display

/**
 * Conservative routing heuristic for AUTO backend selection: whether the
 * target display looks like a desktop system sink (e.g. Samsung DeX), where
 * Android routes /dev/uhid mice through the native InputReader pipeline so
 * the visible pointer sprite follows the virtual device.
 *
 * Two deterministic classification rules, in decreasing order of authority:
 *
 * 1. Hidden [DisplayInfo.FLAG_DESKTOP] bit (0x40) — the AOSP "system desktop
 *    display" classification.
 * 2. Samsung DeX virtual-desktop shape: VIRTUAL type plus the canonical
 *    desktop name `Desktop`, anchored to the system-owned uniqueId segment
 *    (`virtual:android,1000,Desktop,…`). On the SM-G977N DeX-for-PC topology
 *    the virtual Desktop display exposes `type=5 (VIRTUAL)` and
 *    `flags=0x20000002` (FLAG_SECURE | FLAG_OWN_CONTENT_ONLY-family bits;
 *    Samsung's own FLAG_DESKTOP_DISPLAY lives outside the flag bits we can
 *    read), so rule 1 fails there even though forced UHID is verified to work
 *    on that exact display. The uniqueId anchor keeps app-owned surfaces that
 *    merely call themselves "Desktop" out of the sink role; an OEM renaming
 *    its desktop surface simply falls back to InputManager injection
 *    (fail-closed, same as today).
 *
 * A desktop classification is not a formal guarantee that the system pointer
 * controller serves that display. False negatives degrade to explicit
 * InputManager injection; false positives would deliver system-routed input
 * without a selected target, so any reflection failure answers false. All
 * hidden android.view.DisplayInfo access stays isolated in this adapter
 * (AGENTS.md rule 9); the decision itself lives in [classify], which is
 * unit-testable on the host JVM where DisplayInfo does not exist.
 */
internal object SystemRoutePolicy {
    fun isDesktopSink(display: Display): Boolean = try {
        val diClass = Class.forName("android.view.DisplayInfo")
        val di = diClass.newInstance()
        display.javaClass.getMethod("getDisplayInfo", diClass).invoke(display, di)
        classify(
            flags = diClass.getField("flags").getLong(di),
            type = diClass.getField("type").getInt(di),
            name = diClass.getField("name").get(di) as? String ?: "",
            uniqueId = diClass.getField("uniqueId").get(di) as? String ?: "",
        )
    } catch (_: Throwable) {
        false
    }

    /** Pure decision over extracted [android.view.DisplayInfo] fields. */
    internal fun classify(
        flags: Long,
        type: Int,
        name: String,
        uniqueId: String,
    ): Boolean = flags and FLAG_DESKTOP != 0L ||
        (
            type == TYPE_VIRTUAL &&
                name == DESKTOP_DISPLAY_NAME &&
                uniqueId.contains(DESKTOP_UNIQUE_ID_SEGMENT)
            )

    // android.view.Display.FLAG_DESKTOP is hidden; read reflectively and
    // fall back to the AOSP constant if absent (mirrors DisplayDiscovery).
    private val FLAG_DESKTOP: Long by lazy {
        try {
            Display::class.java.getField("FLAG_DESKTOP").getLong(null)
        } catch (_: Throwable) {
            0x40L
        }
    }

    /** android.view.Display.TYPE_VIRTUAL (hidden constant; AOSP fallback). */
    private const val TYPE_VIRTUAL = 5

    /** Canonical Samsung DeX desktop display name. */
    internal const val DESKTOP_DISPLAY_NAME = "Desktop"

    /**
     * uniqueId prefix identifying the Android-managed desktop virtual display
     * (`virtual:android,1000,Desktop,<flags>`); owner uid 1000 keeps the rule
     * anchored to the system-owned surface.
     */
    internal const val DESKTOP_UNIQUE_ID_SEGMENT = "virtual:android,1000,Desktop,"
}
