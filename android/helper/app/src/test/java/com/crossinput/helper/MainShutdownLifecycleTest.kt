package com.crossinput.helper

import org.junit.Assert.assertEquals
import org.junit.Test

class MainShutdownLifecycleTest {

    @Test
    fun stdinWorkerRequestsTheCapturedMainLooperExactlyOnce() {
        val events = mutableListOf<String>()
        val lifecycle = MainShutdownLifecycle(
            requestMainLoopQuit = { events += "quit" },
            destroyKeyboard = { events += "keyboard" },
            destroyHid = { events += "hid" },
            flush = { events += "flush" },
        )

        lifecycle.requestQuit()
        lifecycle.requestQuit()

        assertEquals(listOf("quit"), events)
    }

    @Test
    fun cleanupOrdersKeyboardPointerBeforeHidAndRunsOnlyOnce() {
        val events = mutableListOf<String>()
        val lifecycle = MainShutdownLifecycle(
            requestMainLoopQuit = { events += "quit" },
            destroyKeyboard = { events += "keyboard" },
            destroyPointer = { events += "pointer" },
            destroyHid = { events += "hid" },
            flush = { events += "flush" },
        )

        lifecycle.cleanupOnce()
        lifecycle.cleanupOnce()

        assertEquals(listOf("keyboard", "pointer", "hid", "flush"), events)
    }
}
