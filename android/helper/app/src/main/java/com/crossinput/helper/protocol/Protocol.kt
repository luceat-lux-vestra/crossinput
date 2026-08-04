package com.crossinput.helper.protocol

/**
 * CXI protocol constants (kept in sync with protocol/protocol.md).
 * On change: protocol.md + protocol/fixtures/ must be updated (AGENTS.md hard rule 6).
 */
object Protocol {
    const val MAGIC = "CXI"
    const val VERSION: Int = 1

    const val TYPE_HELLO: Int = 0x0001
    const val TYPE_LIST_DISPLAYS: Int = 0x0002
    const val TYPE_SELECT_DISPLAY: Int = 0x0003
    const val TYPE_CREATE_HID_DEVICE: Int = 0x0004
    const val TYPE_DESTROY_HID_DEVICE: Int = 0x0005
    const val TYPE_HID_REPORT: Int = 0x0006
    const val TYPE_PING: Int = 0x0007
    const val TYPE_SHUTDOWN: Int = 0x0008
    // Semantic pointer messages (SDK injection backend; scrcpy-style)
    const val TYPE_POINTER_MOVE_REL: Int = 0x0009
    const val TYPE_POINTER_BUTTON: Int = 0x000A
    const val TYPE_POINTER_SCROLL: Int = 0x000B
    const val TYPE_KEY_EVENT: Int = 0x000C

    const val TYPE_HELLO_ACK: Int = 0x8001
    const val TYPE_DISPLAY_LIST: Int = 0x8002
    const val TYPE_DISPLAY_CHANGED: Int = 0x8003
    const val TYPE_HID_CREATED: Int = 0x8004
    const val TYPE_HID_ERROR: Int = 0x8005
    const val TYPE_PONG: Int = 0x8006
    const val TYPE_LOG_EVENT: Int = 0x8007
    const val TYPE_FATAL_ERROR: Int = 0x8008
}
