package com.crossinput.helper.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets

/**
 * CXI message payload codecs (little-endian), per protocol/protocol.md.
 * Parsers are for Mac → Android messages; builders are for Android → Mac responses.
 */
object Messages {

    // Log levels (LOG_EVENT payload, level u8)
    const val LEVEL_DEBUG = 0
    const val LEVEL_INFO = 1
    const val LEVEL_WARN = 2
    const val LEVEL_ERROR = 3

    // ---- Mac → Android (parsers) ----

    fun helloVersion(payload: ByteArray): Int = le(payload, 0).short.toInt() and 0xFFFF

    fun selectDisplayId(payload: ByteArray): Int = le(payload, 0).int

    fun createHidDescriptor(payload: ByteArray): ByteArray = lengthPrefixed(payload, 0)

    fun destroyHidDeviceId(payload: ByteArray): Int = le(payload, 0).int

    data class HidReport(val deviceId: Int, val report: ByteArray)

    fun hidReport(payload: ByteArray): HidReport {
        val deviceId = le(payload, 0).int
        return HidReport(deviceId, lengthPrefixed(payload, 4))
    }

    fun pointerMoveRel(payload: ByteArray): Pair<Int, Int> {
        val bb = le(payload, 0)
        return Pair(bb.int, bb.int)
    }

    data class PointerButton(val button: Int, val down: Boolean)

    fun pointerButton(payload: ByteArray): PointerButton {
        val bb = le(payload, 0)
        return PointerButton(bb.int, bb.get().toInt() != 0)
    }

    fun pointerScroll(payload: ByteArray): Pair<Float, Float> {
        val bb = le(payload, 0)
        return Pair(bb.float, bb.float)
    }

    // ---- Android → Mac (builders) ----

    fun helloAck(version: Int): ByteArray =
        ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(version.toShort()).array()

    fun displayList(displays: List<DisplayInfo>): ByteArray {
        val bodies = displays.map { it.encode() }
        val total = 4 + bodies.sumOf { it.size }
        val bb = ByteBuffer.allocate(total).order(ByteOrder.LITTLE_ENDIAN)
        bb.putInt(displays.size)
        bodies.forEach { bb.put(it) }
        return bb.array()
    }

    fun displayChanged(display: DisplayInfo): ByteArray = display.encode()

    fun hidCreated(deviceId: Int): ByteArray =
        ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(deviceId).array()

    fun hidError(deviceId: Int, code: Int, message: String): ByteArray {
        val msg = message.toByteArray(StandardCharsets.UTF_8)
        val bb = ByteBuffer.allocate(8 + 4 + msg.size).order(ByteOrder.LITTLE_ENDIAN)
        bb.putInt(deviceId)
        bb.putInt(code)
        putString(bb, msg)
        return bb.array()
    }

    fun pong(): ByteArray = ByteArray(0)

    fun logEvent(level: Int, tag: String, message: String): ByteArray {
        val tagBytes = tag.toByteArray(StandardCharsets.UTF_8)
        val msgBytes = message.toByteArray(StandardCharsets.UTF_8)
        val bb = ByteBuffer.allocate(1 + 4 + tagBytes.size + 4 + msgBytes.size)
            .order(ByteOrder.LITTLE_ENDIAN)
        bb.put(level.toByte())
        putString(bb, tagBytes)
        putString(bb, msgBytes)
        return bb.array()
    }

    fun fatalError(code: Int, message: String): ByteArray {
        val msg = message.toByteArray(StandardCharsets.UTF_8)
        val bb = ByteBuffer.allocate(4 + 4 + msg.size).order(ByteOrder.LITTLE_ENDIAN)
        bb.putInt(code)
        putString(bb, msg)
        return bb.array()
    }

    // ---- helpers ----

    private fun le(payload: ByteArray, off: Int): ByteBuffer =
        ByteBuffer.wrap(payload, off, payload.size - off).order(ByteOrder.LITTLE_ENDIAN)

    private fun lengthPrefixed(payload: ByteArray, off: Int): ByteArray {
        val bb = le(payload, off)
        val len = bb.int
        if (len < 0 || len > bb.remaining()) throw ProtocolException("bad length $len")
        val bytes = ByteArray(len)
        bb.get(bytes)
        return bytes
    }

    private fun putString(bb: ByteBuffer, bytes: ByteArray) {
        bb.putInt(bytes.size)
        bb.put(bytes)
    }
}
