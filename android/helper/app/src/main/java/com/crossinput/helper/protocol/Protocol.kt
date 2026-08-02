package com.crossinput.helper.protocol

/**
 * CXI 프로토콜 상수 (protocol/protocol.md와 동기화).
 * 변경 시: protocol.md + protocol/fixtures/ 갱신 필수 (AGENTS.md 하드 룰 6).
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

    const val TYPE_HELLO_ACK: Int = 0x8001
    const val TYPE_DISPLAY_LIST: Int = 0x8002
    const val TYPE_DISPLAY_CHANGED: Int = 0x8003
    const val TYPE_HID_CREATED: Int = 0x8004
    const val TYPE_HID_ERROR: Int = 0x8005
    const val TYPE_PONG: Int = 0x8006
    const val TYPE_LOG_EVENT: Int = 0x8007
    const val TYPE_FATAL_ERROR: Int = 0x8008
}
