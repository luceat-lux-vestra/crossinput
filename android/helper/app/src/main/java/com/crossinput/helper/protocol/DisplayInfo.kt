package com.crossinput.helper.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets

/**
 * Display descriptor as defined in protocol/protocol.md ("display structure").
 * Pure JVM model shared by the Android-side Discovery and the codec.
 */
data class DisplayInfo(
    val displayId: Int,
    val type: Int,
    val flags: Int,
    val state: Int,
    val width: Int,
    val height: Int,
    val densityDpi: Int,
    val rotation: Int,
    val name: String,
    val uniqueId: String,
    val layerStack: Int,
) {
    fun encode(): ByteArray {
        val nameBytes = name.toByteArray(StandardCharsets.UTF_8)
        val uniqueBytes = uniqueId.toByteArray(StandardCharsets.UTF_8)
        val bb = ByteBuffer.allocate(23 + 4 + nameBytes.size + 4 + uniqueBytes.size + 4)
            .order(ByteOrder.LITTLE_ENDIAN)
        bb.putInt(displayId)
        bb.put(type.toByte())
        bb.putInt(flags)
        bb.put(state.toByte())
        bb.putInt(width)
        bb.putInt(height)
        bb.putInt(densityDpi)
        bb.put(rotation.toByte())
        bb.putInt(nameBytes.size)
        bb.put(nameBytes)
        bb.putInt(uniqueBytes.size)
        bb.put(uniqueBytes)
        bb.putInt(layerStack)
        return bb.array()
    }

    companion object {
        fun decode(payload: ByteBuffer): DisplayInfo {
            val bb = payload.order(ByteOrder.LITTLE_ENDIAN)
            val displayId = bb.int
            val type = bb.get().toInt() and 0xFF
            val flags = bb.int
            val state = bb.get().toInt() and 0xFF
            val width = bb.int
            val height = bb.int
            val densityDpi = bb.int
            val rotation = bb.get().toInt() and 0xFF
            val name = str(bb)
            val uniqueId = str(bb)
            val layerStack = bb.int
            return DisplayInfo(
                displayId = displayId,
                type = type,
                flags = flags,
                state = state,
                width = width,
                height = height,
                densityDpi = densityDpi,
                rotation = rotation,
                name = name,
                uniqueId = uniqueId,
                layerStack = layerStack,
            )
        }

        private fun str(bb: ByteBuffer): String {
            val len = bb.int
            if (len < 0 || len > bb.remaining()) throw ProtocolException("bad string length $len")
            val bytes = ByteArray(len)
            bb.get(bytes)
            return String(bytes, StandardCharsets.UTF_8)
        }
    }
}
