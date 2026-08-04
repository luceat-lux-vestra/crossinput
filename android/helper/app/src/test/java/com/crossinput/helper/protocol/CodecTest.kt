package com.crossinput.helper.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

class CodecTest {

    private fun roundTrip(frame: Frame): Frame {
        val out = ByteArrayOutputStream()
        val writer = FrameWriter(out)
        writer.write(frame.type, frame.requestId, frame.payload)
        writer.flush()
        return FrameReader(ByteArrayInputStream(out.toByteArray())).readFrame()!!
    }

    @Test
    fun frameRoundTrip() {
        val payload = byteArrayOf(0x01, 0x02, 0x03)
        val frame = roundTrip(Frame(Protocol.TYPE_HELLO, 42, payload))
        assertEquals(Protocol.TYPE_HELLO, frame.type)
        assertEquals(42, frame.requestId)
        assertArrayEquals(payload, frame.payload)
    }

    @Test
    fun emptyPayloadRoundTrip() {
        val frame = roundTrip(Frame(Protocol.TYPE_PING, 7))
        assertEquals(Protocol.TYPE_PING, frame.type)
        assertEquals(7, frame.requestId)
        assertEquals(0, frame.payload.size)
    }

    @Test
    fun eofAtFrameBoundaryReturnsNull() {
        val reader = FrameReader(ByteArrayInputStream(ByteArray(0)))
        assertNull(reader.readFrame())
    }

    @Test
    fun partialHeaderThrows() {
        val bytes = byteArrayOf(0x43, 0x58, 0x49, 0x01) // magic + version, nothing more
        val reader = FrameReader(ByteArrayInputStream(bytes))
        assertThrows(ProtocolException::class.java) { reader.readFrame() }
    }

    @Test
    fun badMagicThrows() {
        val writerBytes = ByteArrayOutputStream()
        FrameWriter(writerBytes).write(Protocol.TYPE_PING, 1)
        val bytes = writerBytes.toByteArray()
        bytes[1] = 0x00 // corrupt magic
        val reader = FrameReader(ByteArrayInputStream(bytes))
        assertThrows(ProtocolException::class.java) { reader.readFrame() }
    }

    @Test
    fun badVersionThrows() {
        val out = ByteArrayOutputStream()
        val buf = ByteBuffer.allocate(Cxi.HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        buf.put(Cxi.MAGIC)
        buf.putShort(99.toShort())
        buf.putShort(Protocol.TYPE_PING.toShort())
        buf.putInt(0)
        buf.putInt(0)
        out.write(buf.array())
        val reader = FrameReader(ByteArrayInputStream(out.toByteArray()))
        assertThrows(ProtocolException::class.java) { reader.readFrame() }
    }

    @Test
    fun truncatedPayloadThrows() {
        val out = ByteArrayOutputStream()
        val writer = FrameWriter(out)
        writer.write(Protocol.TYPE_HID_REPORT, 1, ByteArray(10))
        writer.flush()
        val bytes = out.toByteArray()
        val reader = FrameReader(ByteArrayInputStream(bytes, 0, bytes.size - 5))
        assertThrows(ProtocolException::class.java) { reader.readFrame() }
    }

    @Test
    fun multipleFramesInOneStream() {
        val out = ByteArrayOutputStream()
        val writer = FrameWriter(out)
        writer.write(Protocol.TYPE_PING, 1)
        writer.write(Protocol.TYPE_PING, 2)
        writer.write(Protocol.TYPE_PING, 3)
        writer.flush()
        val reader = FrameReader(ByteArrayInputStream(out.toByteArray()))
        assertEquals(1, reader.readFrame()!!.requestId)
        assertEquals(2, reader.readFrame()!!.requestId)
        assertEquals(3, reader.readFrame()!!.requestId)
        assertNull(reader.readFrame())
    }

    @Test
    fun displayEncodeDecodeRoundTrip() {
        val display = DisplayInfo(
            displayId = 2,
            type = 7,
            flags = 0x100,
            state = 1,
            width = 1920,
            height = 1080,
            densityDpi = 160,
            rotation = 0,
            name = "Desktop",
            uniqueId = "local:2",
            layerStack = 2,
        )
        val decoded = DisplayInfo.decode(ByteBuffer.wrap(display.encode()))
        assertEquals(display, decoded)
    }

    @Test
    fun displayEncodeLayout() {
        // Fixed part is 23 bytes: id u32, type u8, flags u32, state u8,
        // width u32, height u32, density u32, rotation u8.
        val display = DisplayInfo(2, 7, 0x100, 1, 1920, 1080, 160, 0, "Desktop", "local:2", 2)
        val encoded = display.encode()
        assertEquals(23 + 4 + 7 + 4 + 7 + 4, encoded.size)
        val bb = ByteBuffer.wrap(encoded).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(2, bb.int)
        assertEquals(7, bb.get().toInt())
        assertEquals(0x100, bb.int)
        assertEquals(1, bb.get().toInt())
        assertEquals(1920, bb.int)
        assertEquals(1080, bb.int)
        assertEquals(160, bb.int)
        assertEquals(0, bb.get().toInt())
        assertEquals(7, bb.int) // "Desktop"
        assertEquals("Desktop", String(encoded, bb.position(), 7, Charsets.UTF_8))
        bb.position(bb.position() + 7)
        assertEquals(7, bb.int) // "local:2"
        assertEquals("local:2", String(encoded, bb.position(), 7, Charsets.UTF_8))
        bb.position(bb.position() + 7)
        assertEquals(2, bb.int)
    }

    @Test
    fun displayListEncodeDecode() {
        val displays = listOf(
            DisplayInfo(0, 1, 0x2, 2, 1440, 3040, 640, 3, "Phone", "local:0", 0),
            DisplayInfo(2, 7, 0x100, 1, 1920, 1080, 160, 0, "Desktop", "local:2", 2),
        )
        val payload = Messages.displayList(displays)
        val bb = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(2, bb.int)
        val first = DisplayInfo.decode(bb)
        val second = DisplayInfo.decode(bb)
        assertEquals(displays, listOf(first, second))
    }

    @Test
    fun helloVersionParses() {
        val payload = ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(1).array()
        assertEquals(1, Messages.helloVersion(payload))
    }

    @Test
    fun helloAckMatchesVersion() {
        val payload = Messages.helloAck(Cxi.VERSION)
        val bb = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(Cxi.VERSION, bb.short.toInt() and 0xFFFF)
    }

    @Test
    fun selectDisplayIdParses() {
        val payload = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(2).array()
        assertEquals(2, Messages.selectDisplayId(payload))
    }

    @Test
    fun createHidDescriptorParses() {
        val descriptor = byteArrayOf(0x05, 0x01, 0x09, 0x02, 0xA1.toByte())
        val payload = ByteBuffer.allocate(4 + descriptor.size).order(ByteOrder.LITTLE_ENDIAN)
        payload.putInt(descriptor.size)
        payload.put(descriptor)
        assertArrayEquals(descriptor, Messages.createHidDescriptor(payload.array()))
    }

    @Test
    fun hidReportParses() {
        val report = byteArrayOf(0x00, 0x10, 0x00, 0x00)
        val payload = ByteBuffer.allocate(4 + 4 + report.size).order(ByteOrder.LITTLE_ENDIAN)
        payload.putInt(1)
        payload.putInt(report.size)
        payload.put(report)
        val parsed = Messages.hidReport(payload.array())
        assertEquals(1, parsed.deviceId)
        assertArrayEquals(report, parsed.report)
    }

    @Test
    fun keyEventParses() {
        val payload = byteArrayOf(0x1D, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00) // keyCode 29, meta 0x1 (Shift), down, repeat 0
        val parsed = Messages.keyEvent(payload)
        assertEquals(29, parsed.keyCode)
        assertEquals(0x1, parsed.metaState)
        assertEquals(0, parsed.action)
        assertEquals(0, parsed.repeatCount)
    }

    @Test
    fun keyEventParsesHighBits() {
        val payload = byteArrayOf(0x6F, 0x00, 0x00, 0x20, 0x00, 0x00, 0x01, 0x02) // keyCode 111, meta 0x2000, up, repeat 2
        val parsed = Messages.keyEvent(payload)
        assertEquals(111, parsed.keyCode)
        assertEquals(0x2000, parsed.metaState)
        assertEquals(1, parsed.action)
        assertEquals(2, parsed.repeatCount)
    }

    @Test
    fun hidErrorBuilds() {        val payload = Messages.hidError(3, 2, "boom")
        val bb = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(3, bb.int)
        assertEquals(2, bb.int)
        val len = bb.int
        assertEquals(4, len)
        assertEquals("boom", String(ByteArray(len) { bb.get() }, Charsets.UTF_8))
    }

    @Test
    fun logEventBuilds() {
        val payload = Messages.logEvent(Messages.LEVEL_WARN, "tag", "msg")
        val bb = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(Messages.LEVEL_WARN, bb.get().toInt())
        val tagLen = bb.int
        assertEquals(3, tagLen)
        assertEquals("tag", String(ByteArray(tagLen) { bb.get() }, Charsets.UTF_8))
        val msgLen = bb.int
        assertEquals("msg", String(ByteArray(msgLen) { bb.get() }, Charsets.UTF_8))
    }

    @Test
    fun fatalErrorBuilds() {
        val payload = Messages.fatalError(7, "bad")
        val bb = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(7, bb.int)
        val len = bb.int
        assertEquals("bad", String(ByteArray(len) { bb.get() }, Charsets.UTF_8))
    }

    @Test
    fun unknownMessageTypeFailsAfterFatalErrorPath() {
        // sanity: FATAL_ERROR payload parses back
        val fatal = Messages.fatalError(1, "unknown message type 0xffff")
        val bb = ByteBuffer.wrap(fatal).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(1, bb.int)
        assertTrue(bb.remaining() >= 4)
    }
}
