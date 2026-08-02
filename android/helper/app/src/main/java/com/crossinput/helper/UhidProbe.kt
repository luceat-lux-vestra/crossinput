package com.crossinput.helper

import android.system.Os
import android.system.OsConstants
import java.io.BufferedReader
import java.io.FileDescriptor
import java.io.InputStreamReader
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * UHID 최소 CLI probe — Phase 0 (R1 입력 위험 검증용 개발 도구, 제품 코드 아님).
 *
 * 실행 (호스트):
 *   scripts/uhid-probe.sh [mouse-rel|mouse-abs|mouse-wheel|stylus]
 *
 * stdin 명령 (행 단위):
 *   rel <dx> <dy>       상대 이동 (mouse-rel, mouse-wheel)
 *   abs <x> <y>         절대 이동 0..32767 (mouse-abs, stylus)
 *   down <0|1|2>        버튼 누름 (0=좌, 1=우, 2=중)
 *   up <0|1|2>          버튼 해제
 *   wheel <n>           수직 휠 (±127)
 *   hwheel <n>          수평 휠 (±127, mouse-wheel만)
 *   in | out            스타일러스 in-range 설정 (stylus만)
 *   quit                종료
 *
 * 로깅 규칙: report payload는 절대 로그에 남기지 않음 (AGENTS.md #4).
 */
object UhidProbe {

    private const val UHID_CREATE2 = 11
    private const val UHID_INPUT2 = 12
    private const val BUS_VIRTUAL = 6

    private fun hd(vararg b: Int) = ByteArray(b.size) { b[it].toByte() }

    private val MOUSE_REL = hd(
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x02, 0x81, 0x06,
        0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
        0xC0, 0xC0,
    )

    private val MOUSE_WHEEL = hd(
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x02, 0x81, 0x06,
        0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
        0x09, 0x48, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
        0xC0, 0xC0,
    )

    private val MOUSE_ABS = hd(
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
        0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
        0xC0, 0xC0,
    )

    private val STYLUS = hd(
        0x05, 0x0d, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x20, 0xa1, 0x00,
        0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01,
        0x09, 0x42, 0x81, 0x02, 0x09, 0x44, 0x81, 0x02, 0x09, 0x3c, 0x81, 0x02, 0x09, 0x45, 0x81, 0x02,
        0x81, 0x03, 0x09, 0x32, 0x81, 0x02, 0x95, 0x02, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x30, 0x75, 0x10, 0x95, 0x01, 0x26, 0xFF, 0x7F, 0x81, 0x02,
        0x09, 0x31, 0x81, 0x02,
        0xC0, 0xC0,
    )

    private val STYLUS_WHEEL = hd(
        0x05, 0x0d, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x20, 0xa1, 0x00,
        0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01,
        0x09, 0x42, 0x81, 0x02, 0x09, 0x44, 0x81, 0x02, 0x09, 0x3c, 0x81, 0x02, 0x09, 0x45, 0x81, 0x02,
        0x81, 0x03, 0x09, 0x32, 0x81, 0x02, 0x95, 0x02, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x30, 0x75, 0x10, 0x95, 0x01, 0x26, 0xFF, 0x7F, 0x81, 0x02,
        0x09, 0x31, 0x81, 0x02,
        0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
        0x09, 0x48, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
        0xC0, 0xC0,
    )

    @JvmStatic
    fun main(vararg args: String) {
        val type = args.getOrNull(0) ?: "mouse-rel"
        val descriptor = when (type) {
            "mouse-rel" -> MOUSE_REL
            "mouse-wheel" -> MOUSE_WHEEL
            "mouse-abs" -> MOUSE_ABS
            "stylus" -> STYLUS
            "stylus-wheel" -> STYLUS_WHEEL
            else -> {
                System.err.println("unknown type: $type (mouse-rel|mouse-abs|mouse-wheel|stylus|stylus-wheel)")
                return
            }
        }

        val fd = Os.open("/dev/uhid", OsConstants.O_RDWR, 0)
        val vendor = args.getOrNull(2)?.toInt(16) ?: 0
        val product = args.getOrNull(3)?.toInt(16) ?: 0
        val bus = args.getOrNull(4)?.toInt(16) ?: BUS_VIRTUAL
        val createPayload = createCreate2Payload("crossinput-probe", descriptor, vendor, product, bus)
        Os.write(fd, createPayload, 0, createPayload.size)
        System.out.println("device created type=$type")

        // CREATE2는 커널 워커가 비동기로 처리하므로 device가 running이 되기 전에
        // INPUT2를 쓰면 ENOTSUP이 반환됨 — 준비 시간 확보.
        Thread.sleep(500)

        val cmdFile = args.getOrNull(1)
        val state = ProbeState(type)
        if (cmdFile != null) {
            val f = java.io.File(cmdFile)
            java.io.RandomAccessFile(f, "rw").use { it.setLength(0) } // 시작 시 초기화
            val raf = java.io.RandomAccessFile(f, "r")
            var offset = 0L
            val pending = StringBuilder()
            while (true) {
                val len = f.length()
                if (len > offset) {
                    raf.seek(offset)
                    val data = ByteArray((len - offset).toInt())
                    raf.readFully(data)
                    offset = len
                    pending.append(String(data, Charsets.UTF_8))
                    var nl: Int
                    while (pending.indexOf("\n").also { nl = it } >= 0) {
                        val line = pending.substring(0, nl).trim()
                        pending.delete(0, nl + 1)
                        if (line.isNotEmpty()) {
                            System.out.println("exec: ${line.split(' ')[0]} ${line.length}")
                            try {
                                val report = exec(line, state)
                                if (line == "quit") {
                                    System.out.println("done")
                                    return
                                }
                                if (report != null) {
                                    writeInput(fd, report)
                                }
                            } catch (e: Exception) {
                                System.err.println("err: $line -> ${e.javaClass.simpleName}")
                            }
                        }
                    }
                }
                Thread.sleep(50)
            }
        }
        val reader = BufferedReader(InputStreamReader(System.`in`))
        if (state.absolute) {
            val report = state.abs(16384, 16384)!!
            try {
                writeInput(fd, report)
                System.out.println("initial abs report sent")
            } catch (e: android.system.ErrnoException) {
                System.err.println("initial report failed: ${e.errno} ${e.message}")
            }
        }
        while (true) {
            val line = reader.readLine() ?: break
            if (line.isBlank()) continue
            if (line.trim() == "quit") break
            val report = exec(line.trim(), state)
            if (report != null) {
                try {
                    writeInput(fd, report)
                } catch (e: android.system.ErrnoException) {
                    System.err.println("report write failed: ${e.errno} ${e.message}")
                }
            }
        }
        System.out.println("done")
    }

    private fun exec(line: String, state: ProbeState): ByteArray? {
        val parts = line.split(Regex("\\s+"))
        return when (parts[0]) {
            "rel" -> state.rel(parts[1].toInt(), parts[2].toInt())
            "abs" -> state.abs(parts[1].toInt(), parts[2].toInt())
            "down" -> state.down(parts[1].toInt())
            "up" -> state.up(parts[1].toInt())
            "wheel" -> state.wheel(parts[1].toInt())
            "hwheel" -> state.hwheel(parts[1].toInt())
                "in" -> state.inRange(true)
                "out" -> state.inRange(false)
                "btn" -> state.setRawButton(parts[1].toInt(16))
            "sleep" -> {
                Thread.sleep(parts[1].toLong())
                null
            }
            else -> {
                System.err.println("unknown command: ${parts[0]}")
                null
            }
        }
    }

    private fun writeInput(fd: FileDescriptor, report: ByteArray) {
        val buf = ByteBuffer.allocate(4 + 2 + report.size)
        buf.order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(12) // UHID_INPUT2
        buf.putShort(report.size.toShort())
        buf.put(report)
        Os.write(fd, buf.array(), 0, buf.capacity())
    }

    private fun createCreate2Payload(
        name: String,
        descriptor: ByteArray,
        vendor: Int = 0,
        product: Int = 0,
        bus: Int = BUS_VIRTUAL,
    ): ByteArray {
        val buf = ByteBuffer.allocate(4 + 128 + 64 + 64 + 2 + 2 + 4 + 4 + 4 + 4 + descriptor.size)
        buf.order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(UHID_CREATE2)
        val nameBytes = name.toByteArray(Charsets.US_ASCII)
        buf.put(nameBytes)
        buf.put(ByteArray(128 - nameBytes.size))
        buf.put(ByteArray(64))
        buf.put(ByteArray(64))
        buf.putShort(descriptor.size.toShort())
        buf.putShort(bus.toShort())
        buf.putInt(vendor)
        buf.putInt(product)
        buf.putInt(0) // version
        buf.putInt(0) // country
        buf.put(descriptor)
        return buf.array()
    }

    private class ProbeState(private val type: String) {
        private val report: ByteArray
        private val absReport: Boolean
        val absolute: Boolean get() = absReport

        init {
            absReport = type == "mouse-abs" || type == "stylus" || type == "stylus-wheel"
            report = ByteArray(
                when (type) {
                    "mouse-wheel" -> 5
                    "stylus-wheel" -> 7
                    else -> if (absReport) 6 else 4
                }
            )
        }

        fun rel(dx: Int, dy: Int): ByteArray? {
            if (absReport) return null
            report[1] = dx.toByte()
            report[2] = dy.toByte()
            return report
        }

        fun abs(x: Int, y: Int): ByteArray? {
            if (!absReport) return null
            val xb = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(x).array()
            val yb = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(y).array()
            report[1] = xb[0]
            report[2] = xb[1]
            report[3] = yb[0]
            report[4] = yb[1]
            return report
        }

        fun down(button: Int): ByteArray {
            report[0] = (report[0].toInt() or (1 shl button)).toByte()
            return report
        }

        fun up(button: Int): ByteArray {
            report[0] = (report[0].toInt() and (1 shl button).inv()).toByte()
            return report
        }

        fun wheel(n: Int): ByteArray? {
            if (type == "stylus") return null
            if (absReport) {
                report[5] = n.toByte()
            } else {
                report[3] = n.toByte()
            }
            return report
        }

        fun hwheel(n: Int): ByteArray? {
            if (type == "mouse-wheel") {
                report[4] = n.toByte()
                return report
            }
            if (type == "stylus-wheel") {
                report[6] = n.toByte()
                return report
            }
            return null
        }

        fun inRange(inRange: Boolean): ByteArray? {
            if (type != "stylus" && type != "stylus-wheel") return null
            if (inRange) {
                report[0] = (report[0].toInt() or 0x20).toByte()
            } else {
                report[0] = (report[0].toInt() and 0x20.inv()).toByte()
            }
            return report
        }

        fun setRawButton(bit: Int): ByteArray? {
            report[0] = bit.toByte()
            return report
        }
    }
}
