package com.crossinput.helper

import android.os.Looper

/**
 * Android helper entry point.
 * Run: adb shell app_process -cp /data/local/tmp/crossinput-helper.apk / com.crossinput.helper.Main
 *
 * Skeleton — CXI protocol loop implemented in Phase 2.
 */
object Main {
    @JvmStatic
    fun main(vararg args: String) {
        Looper.prepare()

        // TODO(B-01): CXI header parsing loop (stdin)
        // TODO(B-02): DisplayManager display discovery + DISPLAY_LIST send
        // TODO(B-03): UHID create/inject (/dev/uhid)
        // TODO(B-04): SELECT_DISPLAY routing

        Looper.loop()
    }
}
