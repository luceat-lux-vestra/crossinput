package com.crossinput.helper

import com.crossinput.helper.protocol.FrameWriter
import com.crossinput.helper.protocol.Messages
import com.crossinput.helper.protocol.Protocol

/**
 * Structured logging to stderr plus LOG_EVENT frames to the Mac.
 * Never logs input payloads (AGENTS.md rule 4).
 */
class Logger(private val writer: WriterLock) {

    fun debug(tag: String, message: String) = send(Messages.LEVEL_DEBUG, tag, message)
    fun info(tag: String, message: String) = send(Messages.LEVEL_INFO, tag, message)
    fun warn(tag: String, message: String) = send(Messages.LEVEL_WARN, tag, message)
    fun error(tag: String, message: String) = send(Messages.LEVEL_ERROR, tag, message)

    private fun send(level: Int, tag: String, message: String) {
        System.err.println("[$tag] $message")
        try {
            writer.withLock { w ->
                w.write(Protocol.TYPE_LOG_EVENT, 0, Messages.logEvent(level, tag, message))
                w.flush()
            }
        } catch (_: Exception) {
            // stderr copy already emitted; never let logging break the loop
        }
    }
}
