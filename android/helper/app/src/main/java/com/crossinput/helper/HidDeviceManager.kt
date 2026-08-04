package com.crossinput.helper

import android.content.Context
import android.hardware.input.InputManager
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.view.InputDevice
import java.io.FileDescriptor
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Virtual HID device lifecycle over /dev/uhid (UHID_CREATE2 / UHID_INPUT2).
 * Direct /dev/uhid access from the shell user is proven on the SM-G977N
 * (Phase 0 probe). Report payloads are never logged (AGENTS.md rule 4).
 */
class HidDeviceManager(private val log: Logger, private val context: Context) {
    class HidError(val code: Int, message: String) : Exception(message)

    private data class Device(val id: Int, val fd: FileDescriptor, val inputDeviceId: Int? = null)

    private val devices = LinkedHashMap<Int, Device>()
    private var nextId = 1

    private val inputManager: InputManager = context.getSystemService(Context.INPUT_SERVICE) as InputManager

    fun create(descriptor: ByteArray, name: String = DEFAULT_NAME): Result<Int> {
        val fd = try {
            Os.open("/dev/uhid", OsConstants.O_RDWR, 0)
        } catch (e: ErrnoException) {
            return Result.failure(HidError(1, "open /dev/uhid failed: ${e.message}"))
        }
        try {
            val payload = create2Payload(name, descriptor)
            Os.write(fd, payload, 0, payload.size)
            Thread.sleep(500)
            val id = nextId++
            // Find the input device ID for our virtual device
            val inputDeviceId = findInputDeviceId(name)
            val device = Device(id, fd, inputDeviceId)
            synchronized(devices) { devices[id] = device }
            log.info("HidDeviceManager", "device created id=$id name=$name inputDeviceId=$inputDeviceId")
            return Result.success(id)
        } catch (e: ErrnoException) {
            safeClose(fd)
            return Result.failure(HidError(2, "create failed: ${e.message}"))
        }
    }

    private fun findInputDeviceId(name: String): Int? {
        val ids = InputDevice.getDeviceIds()
        for (id in ids) {
            val device = InputDevice.getDevice(id)
            if (device?.name == name) {
                return id
            }
        }
        return null
    }

    fun sendReport(deviceId: Int, report: ByteArray): Boolean {
        val device = synchronized(devices) { devices[deviceId] }
        if (device == null) {
            log.warn("HidDeviceManager", "report for unknown device id=$deviceId")
            return false
        }
        return try {
            val buf = ByteBuffer.allocate(4 + 2 + report.size).order(ByteOrder.LITTLE_ENDIAN)
            buf.putInt(UHID_INPUT2)
            buf.putShort(report.size.toShort())
            buf.put(report)
            val written = Os.write(device.fd, buf.array(), 0, buf.capacity())
            log.info("HidDeviceManager", "report sent id=$deviceId len=${report.size} written=$written")
            true
        } catch (e: ErrnoException) {
            log.error("HidDeviceManager", "report write failed id=$deviceId: ${e.message}")
            false
        }
    }

    fun destroy(deviceId: Int) {
        val device = synchronized(devices) { devices.remove(deviceId) } ?: return
        safeClose(device.fd)
        log.info("HidDeviceManager", "device destroyed id=$deviceId")
    }

    fun destroyAll() {
        val ids = synchronized(devices) { devices.values.map { it.id } }
        ids.forEach { destroy(it) }
    }

    private fun safeClose(fd: FileDescriptor) {
        try {
            Os.close(fd)
        } catch (_: ErrnoException) {
        }
    }

    companion object {
        private const val UHID_CREATE2 = 11
        private const val UHID_INPUT2 = 12
        private const val BUS_USB = 3
        // Proven in Phase 0: 046d:c077 with USB bus gets standard mouse
        // handling (pointer + acceleration) from the DeX input pipeline.
        private const val DEFAULT_VENDOR = 0x046d
        private const val DEFAULT_PRODUCT = 0xc077
        private const val DEFAULT_NAME = "Ampersand Mouse"

        private fun create2Payload(name: String, descriptor: ByteArray): ByteArray {
            val buf = ByteBuffer.allocate(4 + 128 + 64 + 64 + 2 + 2 + 4 + 4 + 4 + 4 + descriptor.size)
                .order(ByteOrder.LITTLE_ENDIAN)
            buf.putInt(UHID_CREATE2)
            val nameBytes = name.toByteArray(Charsets.US_ASCII)
            buf.put(nameBytes)
            buf.put(ByteArray(128 - nameBytes.size))
            buf.put(ByteArray(64)) // phys
            buf.put(ByteArray(64)) // uniq
            buf.putShort(descriptor.size.toShort())
            buf.putShort(BUS_USB.toShort())
            buf.putInt(DEFAULT_VENDOR)
            buf.putInt(DEFAULT_PRODUCT)
            buf.putInt(0) // version
            buf.putInt(0) // country
            buf.put(descriptor)
            return buf.array()
        }
    }
}