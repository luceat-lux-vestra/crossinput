package com.crossinput.helper

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.Display
import com.crossinput.helper.protocol.DisplayInfo
import com.crossinput.helper.protocol.Messages
import com.crossinput.helper.protocol.Protocol

/**
 * Enumerates displays via DisplayManager and pushes DISPLAY_CHANGED on
 * add/change. Display IDs are never hardcoded (AGENTS.md rule 3); the macOS
 * side selects the target display from DISPLAY_LIST.
 *
 * Removals are reported via LOG_EVENT only: DISPLAY_CHANGED carries a full
 * display structure, which cannot describe a display that no longer exists.
 *
 * android.view.DisplayInfo is @hide and absent from the public SDK; its fields
 * are read via reflection (works under app_process, shell uid). Failures
 * degrade to -1/0 sentinels per protocol.md instead of crashing the helper.
 */
class DisplayDiscovery(
    context: Context,
    private val writer: WriterLock,
    private val log: Logger,
) : DisplayManager.DisplayListener {

    private val displayManager =
        context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager

    init {
        displayManager.registerDisplayListener(this, Handler(Looper.myLooper()!!))
    }

    override fun onDisplayAdded(displayId: Int) = notifyChanged(displayId)
    override fun onDisplayChanged(displayId: Int) = notifyChanged(displayId)
    override fun onDisplayRemoved(displayId: Int) {
        log.info("DisplayDiscovery", "display removed id=$displayId")
    }

    fun displays(): List<DisplayInfo> = displayManager.displays.mapNotNull { buildInfo(it) }

    fun find(displayId: Int): DisplayInfo? = displays().firstOrNull { it.displayId == displayId }
        ?: buildInfo(displayManager.getDisplay(displayId))

    private fun notifyChanged(displayId: Int) {
        val info = buildInfo(displayManager.getDisplay(displayId)) ?: return
        log.info("DisplayDiscovery", "display changed id=$displayId")
        writer.withLock {
            it.write(Protocol.TYPE_DISPLAY_CHANGED, 0, Messages.displayChanged(info))
            it.flush()
        }
    }

    private fun buildInfo(display: Display?): DisplayInfo? {
        if (display == null) return null
        val hidden = HiddenInfo.read(display) ?: run {
            log.warn("DisplayDiscovery", "hidden DisplayInfo unavailable for display ${display.displayId}")
            return null
        }
        // Protocol display type 7 = "desktop"; Android 12 has no public
        // TYPE_* for DeX displays, so it is detected via the hidden
        // DisplayInfo.FLAG_DESKTOP bit.
        val type = if (hidden.flags and HiddenInfo.FLAG_DESKTOP != 0L) 7 else hidden.type
        val metrics = DisplayMetrics()
        display.getRealMetrics(metrics)
        return DisplayInfo(
            displayId = display.displayId,
            type = type,
            flags = hidden.flags.toInt(),
            state = display.state,
            width = hidden.logicalWidth,
            height = hidden.logicalHeight,
            densityDpi = metrics.densityDpi,
            rotation = display.rotation,
            name = hidden.name,
            uniqueId = hidden.uniqueId,
            layerStack = hidden.layerStack,
        )
    }

    /** Reflective view of the hidden android.view.DisplayInfo fields we need. */
    private class HiddenInfo(
        val flags: Long,
        val logicalWidth: Int,
        val logicalHeight: Int,
        val name: String,
        val uniqueId: String,
        val type: Int,
        val layerStack: Int,
    ) {
        companion object {
            // android.view.Display.FLAG_DESKTOP = 1 << 6 (hidden constant);
            // read reflectively, fall back to the AOSP value if absent.
            val FLAG_DESKTOP: Long by lazy {
                try {
                    Display::class.java.getField("FLAG_DESKTOP").getLong(null)
                } catch (_: Throwable) {
                    0x40L
                }
            }

            fun read(display: Display): HiddenInfo? {
                return try {
                    // getDisplayInfo takes a DisplayInfo object to populate
                    val diClass = Class.forName("android.view.DisplayInfo")
                    val di = diClass.newInstance()
                    display.javaClass.getMethod("getDisplayInfo", diClass).invoke(display, di)
                    HiddenInfo(
                        flags = longField(di, "flags") ?: 0L,
                        logicalWidth = intField(di, "logicalWidth") ?: 0,
                        logicalHeight = intField(di, "logicalHeight") ?: 0,
                        name = stringField(di, "name") ?: "",
                        uniqueId = stringField(di, "uniqueId") ?: "",
                        type = intField(di, "type") ?: -1,
                        layerStack = intField(di, "layerStack") ?: -1,
                    )
                } catch (e: Throwable) {
                    System.err.println("[DisplayDiscovery] HiddenInfo.read failed: ${e.javaClass.simpleName}: ${e.message}")
                    null
                }
            }

            private fun intField(obj: Any, name: String): Int? {
                val field = obj.javaClass.getField(name)
                return field.getInt(obj)
            }

            private fun longField(obj: Any, name: String): Long? {
                val field = obj.javaClass.getField(name)
                return field.getLong(obj)
            }

            private fun stringField(obj: Any, name: String): String? {
                val field = obj.javaClass.getField(name)
                return field.get(obj) as? String
            }
        }
    }
}

/** Serializes writer access across the stdin thread and display-callback thread. */
class WriterLock(private val writer: com.crossinput.helper.protocol.FrameWriter) {
    fun withLock(block: (com.crossinput.helper.protocol.FrameWriter) -> Unit) = synchronized(this) {
        block(writer)
    }
}