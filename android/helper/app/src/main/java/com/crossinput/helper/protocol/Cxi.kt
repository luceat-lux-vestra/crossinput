package com.crossinput.helper.protocol

import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * CXI frame framing: 15-byte little-endian header + payload.
 * Wire format: protocol/protocol.md.
 * Changing the wire format requires updating protocol.md, protocol/fixtures/,
 * and both implementations (AGENTS.md hard rule 6).
 */
object Cxi {
    const val HEADER_SIZE = 15
    const val VERSION = 1
    val MAGIC = byteArrayOf(0x43, 0x58, 0x49) // "CXI"
    const val MAX_PAYLOAD = 1 shl 20 // 1 MiB safety cap
}

class ProtocolException(message: String) : Exception(message)

/** One decoded frame (header fields + raw payload). */
data class Frame(
    val type: Int,
    val requestId: Int,
    val payload: ByteArray = ByteArray(0),
)

/**
 * Incremental frame parser over a stream (helper stdin).
 * Returns null only on a clean EOF at a frame boundary.
 */
class FrameReader(private val input: InputStream) {

    fun readFrame(): Frame? {
        val header = ByteArray(Cxi.HEADER_SIZE)
        if (!readFully(header)) return null
        val bb = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
        val magic = byteArrayOf(bb.get(), bb.get(), bb.get())
        if (!magic.contentEquals(Cxi.MAGIC)) throw ProtocolException("bad magic ${magic.joinToString { "%02X".format(it) }}")
        val version = bb.short.toInt() and 0xFFFF
        if (version != Cxi.VERSION) throw ProtocolException("unsupported version $version")
        val type = bb.short.toInt() and 0xFFFF
        val requestId = bb.int
        val payloadLen = bb.int
        if (payloadLen < 0 || payloadLen > Cxi.MAX_PAYLOAD) {
            throw ProtocolException("invalid payloadLen $payloadLen")
        }
        val payload = ByteArray(payloadLen)
        if (payloadLen > 0 && !readFully(payload)) throw ProtocolException("truncated frame payload")
        return Frame(type, requestId, payload)
    }

    /** Returns false only for clean EOF before any byte of this buffer was read. */
    private fun readFully(buf: ByteArray): Boolean {
        var off = 0
        while (off < buf.size) {
            val n = input.read(buf, off, buf.size - off)
            if (n < 0) {
                if (off == 0) return false
                throw ProtocolException("truncated frame (got $off of ${buf.size} bytes)")
            }
            off += n
        }
        return true
    }
}

/** Frame writer over a stream (helper stdout). Thread-safe. */
class FrameWriter(private val out: OutputStream) {

    fun write(type: Int, requestId: Int, payload: ByteArray = ByteArray(0)) {
        val buf = ByteBuffer.allocate(Cxi.HEADER_SIZE + payload.size).order(ByteOrder.LITTLE_ENDIAN)
        buf.put(Cxi.MAGIC)
        buf.putShort(Cxi.VERSION.toShort())
        buf.putShort(type.toShort())
        buf.putInt(requestId)
        buf.putInt(payload.size)
        buf.put(payload)
        synchronized(this) {
            out.write(buf.array())
        }
    }

    fun flush() = synchronized(this) { out.flush() }
}
