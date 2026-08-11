package com.crossinput.helper

import android.view.Display

/**
 * Semantic pointer injector backed by a virtual relative mouse on /dev/uhid.
 *
 * The macOS application never sees this implementation or its descriptor. It
 * sends CXI v1 semantic pointer messages; the helper owns descriptor creation,
 * report encoding, button state, large-delta splitting, and cleanup.
 */
class UhidPointerInjector(
    private val log: Logger,
    private val hid: HidDeviceManager,
) : PointerInjector {
    override val routing: PointerRouting = PointerRouting.SYSTEM_ROUTED
    private var deviceId: Int? = null
    private var selectedDisplayId: Int = -1
    private var buttons: Int = 0
    private var failed = false

    /** Creates the device lazily so backend selection can fall back cleanly. */
    fun create(): Boolean {
        if (deviceId != null && !failed) return true
        close()
        val result = hid.create(MOUSE_DESCRIPTOR, DEVICE_NAME)
        val id = result.getOrNull()
        if (id == null) {
            failed = true
            log.warn(TAG, "UHID pointer creation unavailable")
            return false
        }
        deviceId = id
        failed = false
        buttons = 0
        log.info(TAG, "pointer backend ready backend=uhid")
        return true
    }

    override fun selectDisplay(display: Display): Boolean {
        selectedDisplayId = display.displayId
        // UHID is a system input device and this API has no per-report display
        // selector. Never claim a target-specific selection succeeded.
        log.warn(TAG, "UHID is system-routed; explicit target selection unavailable")
        return false
    }

    /** Allows a caller without target-selection semantics to use system routing. */
    fun selectSystemRoute(): Boolean {
        selectedDisplayId = -1
        return create()
    }

    override fun refreshMetrics(displayId: Int) {
        // Relative UHID reports do not require display metrics.
    }

    override fun moveRelative(dx: Int, dy: Int): PointerDelivery {
        val id = deviceId ?: return PointerDelivery.FAILED
        if (failed) return PointerDelivery.FAILED

        val reports = split(dx, dy)
        if (reports.isEmpty()) return PointerDelivery.DELIVERED

        var sent = 0
        var deliveredDx = 0
        var deliveredDy = 0
        for (report in reports) {
            if (!hid.sendReport(id, report(buttons, report.first, report.second, 0))) {
                failed = true
                close()
                // Retrying a partially sent semantic move on another backend
                // would duplicate the already accepted reports. The dispatcher
                // may switch backend for the next event, but must not retry this
                // one.
                return if (sent == 0) {
                    PointerDelivery.FAILED
                } else {
                    PointerDelivery.partiallyDeliveredMovement(deliveredDx, deliveredDy)
                }
            }
            sent++
            deliveredDx += report.first
            deliveredDy += report.second
        }
        return PointerDelivery.deliveredMovement(deliveredDx, deliveredDy)
    }

    override fun button(button: Int, down: Boolean): PointerDelivery {
        val id = deviceId ?: return PointerDelivery.FAILED
        val bit = buttonBit(button) ?: return PointerDelivery.FAILED
        val next = if (down) buttons or bit else buttons and bit.inv()
        if (!hid.sendReport(id, report(next, 0, 0, 0))) {
            failed = true
            close()
            return PointerDelivery.FAILED
        }
        buttons = next
        return PointerDelivery.DELIVERED
    }

    override fun scroll(horizontal: Float, vertical: Float): PointerDelivery {
        // Keep the descriptor/report contract byte-for-byte compatible with
        // the verified v1 mouse. Horizontal scrolling is not represented by
        // that descriptor, so the dispatcher uses InputManager for it.
        if (horizontal != 0f) return PointerDelivery.FAILED
        val id = deviceId ?: return PointerDelivery.FAILED
        val wheel = when {
            vertical > 0f -> 1
            vertical < 0f -> 255
            else -> 0
        }
        if (!hid.sendReport(id, report(buttons, 0, 0, wheel))) {
            failed = true
            close()
            return PointerDelivery.FAILED
        }
        return PointerDelivery.DELIVERED
    }

    override fun close() {
        val id = deviceId ?: run {
            buttons = 0
            return
        }
        // Release every held button before closing the virtual device. This
        // is idempotent and is safe even after a failed report write.
        if (buttons != 0) hid.sendReport(id, report(0, 0, 0, 0))
        buttons = 0
        hid.destroy(id)
        deviceId = null
        selectedDisplayId = -1
    }

    private fun report(buttons: Int, dx: Int, dy: Int, wheel: Int): ByteArray =
        byteArrayOf(buttons.toByte(), dx.toByte(), dy.toByte(), wheel.toByte())

    private fun buttonBit(button: Int): Int? = when (button) {
        0 -> 0x01
        1 -> 0x02
        2 -> 0x04
        else -> null
    }

    /** Exact v1-compatible split: each report axis is in [-127, 127]. */
    private fun split(dx: Int, dy: Int): List<Pair<Int, Int>> {
        val x = chunks(dx.toLong())
        val y = chunks(dy.toLong())
        val count = maxOf(x.size, y.size).coerceAtMost(MAX_REPORTS)
        return (0 until count).map { index ->
            Pair(x.getOrElse(index) { 0L }.toInt(), y.getOrElse(index) { 0L }.toInt())
        }
    }

    private fun chunks(value: Long): List<Long> {
        if (value == 0L) return emptyList()
        val magnitude = kotlin.math.abs(value)
        val full = minOf(magnitude / REPORT_LIMIT, MAX_REPORTS.toLong())
        val remainder = if (full < MAX_REPORTS) magnitude % REPORT_LIMIT else 0L
        val sign = if (value > 0) 1L else -1L
        return buildList {
            repeat(full.toInt()) { add(sign * REPORT_LIMIT) }
            if (remainder > 0) add(sign * remainder)
        }
    }

    companion object {
        private const val TAG = "UhidPointerInjector"
        private const val DEVICE_NAME = "Ampersand Mouse"
        private const val REPORT_LIMIT = 127L
        private const val MAX_REPORTS = 1024

        // Standard v1 relative mouse descriptor: buttons, signed X/Y, wheel.
        // Keep this identical to protocol/fixtures/create-hid.bin.
        val MOUSE_DESCRIPTOR = byteArrayOf(
            0x05, 0x01, 0x09, 0x02, 0xA1.toByte(), 0x01, 0x09, 0x01, 0xA1.toByte(), 0x00,
            0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01,
            0x95.toByte(), 0x03, 0x75, 0x01, 0x81.toByte(), 0x02,
            0x95.toByte(), 0x01, 0x75, 0x05, 0x81.toByte(), 0x01,
            0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x81.toByte(), 0x25, 0x7F,
            0x75, 0x08, 0x95.toByte(), 0x02, 0x81.toByte(), 0x06,
            0x09, 0x38, 0x15, 0x81.toByte(), 0x25, 0x7F, 0x75, 0x08,
            0x95.toByte(), 0x01, 0x81.toByte(), 0x06, 0xC0.toByte(), 0xC0.toByte(),
        )
    }
}
