package com.crossinput.helper

import com.crossinput.helper.protocol.Messages

/**
 * UHID-specific keyboard implementation. It owns the pressed-usage state and
 * the report lifecycle; the session-level [KeyboardBackend] only selects it.
 */
class UhidKeyboardInjector(
    private val log: Logger,
    private val hid: HidDeviceManager,
    private val descriptor: ByteArray,
    private val deviceName: String,
) {
    private var deviceId: Int? = null
    private var broken = false
    private val pressedUsages = LinkedHashSet<Int>()

    fun create(): Boolean {
        if (broken) return false
        hid.create(descriptor, deviceName).fold(
            onSuccess = {
                deviceId = it
                log.info(TAG, "UHID keyboard created id=$it")
            },
            onFailure = {
                broken = true
                log.warn(TAG, "UHID keyboard unavailable (${it.javaClass.simpleName})")
            },
        )
        return usable()
    }

    fun usable(): Boolean = deviceId != null && !broken

    /** Returns false when the key is unmappable or the report path failed. */
    fun send(event: Messages.KeyEvent): Boolean {
        val id = deviceId
        if (id == null || broken) return false
        val usage = KeyboardHidMapper.usageOf(event.keyCode) ?: return false

        if (event.action == 0) pressedUsages.add(usage) else pressedUsages.remove(usage)
        val modifier = KeyboardHidMapper.modifierOf(event.metaState)
        val report = KeyboardHidMapper.buildReport(modifier, pressedUsages.toList())
        if (hid.sendReport(id, report)) return true

        broken = true
        pressedUsages.clear()
        log.warn(TAG, "UHID report failed; UHID disabled for this session")
        return false
    }

    fun destroy() {
        val id = deviceId
        if (id != null && pressedUsages.isNotEmpty()) {
            // Release any keys still reported as pressed before closing UHID.
            hid.sendReport(id, KeyboardHidMapper.buildReport(0, emptyList()))
            pressedUsages.clear()
        }
        id?.let { hid.destroy(it) }
        deviceId = null
    }

    private companion object {
        const val TAG = "UhidKeyboardInjector"
    }
}
