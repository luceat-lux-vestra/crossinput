package com.crossinput.helper.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Golden fixture tests: decode the shared .bin fixtures (protocol/fixtures/)
 * with the Kotlin codec. Expected values mirror the JSON files in
 * protocol/fixtures/, which protocol/scripts/check-fixtures.mjs validates independently in CI.
 */
class FixtureTest {

    private val fixturesDir =
        File(System.getProperty("user.dir"), "../../../protocol/fixtures").canonicalFile

    private fun fixture(name: String): Frame {
        val bin = fixturesDir.resolve("$name.bin")
        assertTrue("fixture missing: ${bin.path}", bin.exists())
        return FrameReader(bin.inputStream()).readFrame()!!
    }

    private fun le(payload: ByteArray, off: Int = 0): ByteBuffer =
        ByteBuffer.wrap(payload, off, payload.size - off).order(ByteOrder.LITTLE_ENDIAN)

    private fun str(bb: ByteBuffer): String {
        val len = bb.int
        val bytes = ByteArray(len)
        bb.get(bytes)
        return String(bytes, Charsets.UTF_8)
    }

    @Test
    fun hello() {
        val frame = fixture("hello")
        assertEquals(Protocol.TYPE_HELLO, frame.type)
        assertEquals(1, frame.requestId)
        assertEquals(1, Messages.helloVersion(frame.payload))
    }

    @Test
    fun helloAck() {
        val frame = fixture("hello-ack")
        assertEquals(Protocol.TYPE_HELLO_ACK, frame.type)
        assertEquals(1, frame.requestId)
        val version = le(frame.payload).short.toInt() and 0xFFFF
        assertEquals(1, version)
    }

    @Test
    fun listDisplays() {
        val frame = fixture("list-displays")
        assertEquals(Protocol.TYPE_LIST_DISPLAYS, frame.type)
        assertEquals(2, frame.requestId)
        assertEquals(0, frame.payload.size)
    }

    @Test
    fun displayList() {
        val frame = fixture("display-list")
        assertEquals(Protocol.TYPE_DISPLAY_LIST, frame.type)
        assertEquals(2, frame.requestId)
        val bb = le(frame.payload)
        assertEquals(1, bb.int)
        val display = DisplayInfo.decode(bb)
        assertEquals(2, display.displayId)
        assertEquals(7, display.type) // FLAG_DESKTOP
        assertEquals(0x100, display.flags)
        assertEquals(1, display.state)
        assertEquals(1920, display.width)
        assertEquals(1080, display.height)
        assertEquals(160, display.densityDpi)
        assertEquals(0, display.rotation)
        assertEquals("Desktop", display.name)
        assertEquals("local:2", display.uniqueId)
        assertEquals(2, display.layerStack)
    }

    @Test
    fun selectDisplay() {
        val frame = fixture("select-display")
        assertEquals(Protocol.TYPE_SELECT_DISPLAY, frame.type)
        assertEquals(3, frame.requestId)
        assertEquals(2, Messages.selectDisplayId(frame.payload))
    }

    @Test
    fun createHid() {
        val frame = fixture("create-hid")
        assertEquals(Protocol.TYPE_CREATE_HID_DEVICE, frame.type)
        assertEquals(4, frame.requestId)
        val descriptor = Messages.createHidDescriptor(frame.payload)
        // MOUSE_REL descriptor from the Phase 0 probe
        val expected = byteArrayOf(
            0x05, 0x01, 0x09, 0x02, 0xA1.toByte(), 0x01, 0x09, 0x01, 0xA1.toByte(), 0x00,
            0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95.toByte(), 0x03, 0x75, 0x01,
            0x81.toByte(), 0x02,
            0x95.toByte(), 0x01, 0x75, 0x05, 0x81.toByte(), 0x01,
            0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x81.toByte(), 0x25, 0x7F, 0x75, 0x08,
            0x95.toByte(), 0x02, 0x81.toByte(), 0x06,
            0x09, 0x38, 0x15, 0x81.toByte(), 0x25, 0x7F, 0x75, 0x08, 0x95.toByte(), 0x01, 0x81.toByte(), 0x06,
            0xC0.toByte(), 0xC0.toByte(),
        )
        assertArrayEquals(expected, descriptor)
    }

    @Test
    fun hidReport() {
        val frame = fixture("hid-report")
        assertEquals(Protocol.TYPE_HID_REPORT, frame.type)
        assertEquals(5, frame.requestId)
        val report = Messages.hidReport(frame.payload)
        assertEquals(1, report.deviceId)
        assertArrayEquals(byteArrayOf(0x00, 0x10, 0x00, 0x00), report.report)
    }
    @Test
    fun pointerMoveRel() {
        val frame = fixture("pointer-move-rel")
        assertEquals(Protocol.TYPE_POINTER_MOVE_REL, frame.type)
        assertEquals(10, frame.requestId)
        val (dx, dy) = Messages.pointerMoveRel(frame.payload)
        assertEquals(12, dx)
        assertEquals(-8, dy)
    }

    @Test
    fun pointerButton() {
        val frame = fixture("pointer-button")
        assertEquals(Protocol.TYPE_POINTER_BUTTON, frame.type)
        assertEquals(11, frame.requestId)
        val btn = Messages.pointerButton(frame.payload)
        assertEquals(0, btn.button)
        assertEquals(true, btn.down)
    }

    @Test
    fun pointerScroll() {
        val frame = fixture("pointer-scroll")
        assertEquals(Protocol.TYPE_POINTER_SCROLL, frame.type)
        assertEquals(12, frame.requestId)
        val (horizontal, vertical) = Messages.pointerScroll(frame.payload)
        assertEquals(0.0f, horizontal)
        assertEquals(1.0f, vertical)
    }

    @Test
    fun pointerResult() {
        val frame = fixture("pointer-result")
        assertEquals(Protocol.TYPE_POINTER_RESULT, frame.type)
        assertEquals(10, frame.requestId)
        assertArrayEquals(
            byteArrayOf(0, 12, 0, 0, 0, 248.toByte(), 255.toByte(), 255.toByte(), 255.toByte()),
            frame.payload,
        )
    }

    @Test
    fun ping() {
        val frame = fixture("ping")
        assertEquals(Protocol.TYPE_PING, frame.type)
        assertEquals(6, frame.requestId)
        assertEquals(0, frame.payload.size)
    }

    @Test
    fun pong() {
        val frame = fixture("pong")
        assertEquals(Protocol.TYPE_PONG, frame.type)
        assertEquals(6, frame.requestId)
        assertEquals(0, frame.payload.size)
    }
}
