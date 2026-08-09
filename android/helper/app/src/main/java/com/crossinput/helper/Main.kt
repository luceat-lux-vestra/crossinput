package com.crossinput.helper

import android.content.Context
import android.os.Looper
import com.crossinput.helper.protocol.Cxi
import com.crossinput.helper.protocol.Frame
import com.crossinput.helper.protocol.FrameReader
import com.crossinput.helper.protocol.FrameWriter
import com.crossinput.helper.protocol.Messages
import com.crossinput.helper.protocol.Protocol
import com.crossinput.helper.protocol.ProtocolException
import com.crossinput.helper.SdkPointerBackend
import java.io.BufferedOutputStream
import java.io.FileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream

/**
 * Android helper entry point (Phase 2).
 * Run: adb shell app_process -cp /data/local/tmp/crossinput-helper.apk / com.crossinput.helper.Main
 *
 * Binary CXI protocol on stdout; diagnostics on stderr. stdin is read on a
 * dedicated thread while the main looper services DisplayManager callbacks.
 */
object Main {

    @JvmStatic
    fun main(vararg args: String) {
        Looper.prepare()

        val stdout = BufferedOutputStream(FileOutputStream(FileDescriptor.out), 8192)
        val writer = FrameWriter(stdout)
        val writerLock = WriterLock(writer)
        val log = Logger(writerLock)

        val mode = parseKeyboardBackendMode(args, log)

        val context = systemContext()
        if (context == null) {
            log.error("Main", "no system context (ActivityThread unavailable); aborting")
            return
        }
        val sdkPointer = SdkPointerBackend(log, context)
        val discovery = DisplayDiscovery(context, writerLock, log, sdkPointer::refreshMetrics)
        val hid = HidDeviceManager(log, context)
        val keyboard = KeyboardBackend(log, context, hid, mode)
        val controller = Controller(discovery, hid, sdkPointer, keyboard, writerLock, log)

        val reader = FrameReader(FileInputStream(FileDescriptor.`in`))
        val stdinThread = Thread {
            try {
                while (true) {
                    val frame = reader.readFrame() ?: break
                    controller.handle(frame)
                    writerLock.withLock { it.flush() }
                    if (controller.shutdownRequested) break
                }
            } catch (e: ProtocolException) {
                log.error("Main", "protocol error: ${e.message}")
            } catch (e: Throwable) {
                log.error("Main", "stdin thread crashed: ${e.javaClass.simpleName}: ${e.message}")
            } finally {
                log.info("Main", "stdin closed; shutting down")
                hid.destroyAll()
                keyboard.destroy()
                Looper.myLooper()?.quitSafely()
            }
        }
        stdinThread.name = "cxi-stdin"
        stdinThread.start()

        Looper.loop()

        hid.destroyAll()
        keyboard.destroy()
        writerLock.withLock { it.flush() }
        System.exit(0)
    }

    /**
     * Parses the --keyboard-backend command-line argument.
     * Default: auto (UHID preferred, fallback to InputManager on failure).
     * Values: auto | uhid | input-manager
     */
    private fun parseKeyboardBackendMode(args: Array<out String>, log: Logger): KeyboardBackendMode {
        var mode = KeyboardBackendMode.AUTO
        var i = 0
        while (i < args.size) {
            val arg = args[i]
            if (arg == "--keyboard-backend") {
                i++
                if (i >= args.size) {
                    log.error("Main", "--keyboard-backend requires a value (auto|uhid|input-manager)")
                    System.exit(1)
                }
                val value = args[i].lowercase()
                mode = when (value) {
                    "auto" -> KeyboardBackendMode.AUTO
                    "uhid" -> KeyboardBackendMode.UHID
                    "input-manager" -> KeyboardBackendMode.INPUT_MANAGER
                    else -> {
                        log.error("Main", "invalid --keyboard-backend value: $value (expected auto|uhid|input-manager)")
                        System.exit(1)
                        KeyboardBackendMode.AUTO // unreachable
                    }
                }
            }
            i++
        }
        log.info("Main", "keyboard backend mode=$mode")
        return mode
    }

    /**
     * ActivityThread is not in the public SDK; obtain the system context via
     * reflection (app_process shell execution, as proven by scrcpy).
     */
    private fun systemContext(): Context? {
        return try {
            val klass = Class.forName("android.app.ActivityThread")
            val thread = klass.getMethod("systemMain").invoke(null)
            klass.getMethod("getSystemContext").invoke(thread) as Context
        } catch (t: Throwable) {
            System.err.println("[Main] system context unavailable: ${t.javaClass.simpleName}: ${t.message}")
            null
        }
    }
}

/**
 * Keyboard backend selection mode.
 * Test-only deterministic override; not a user-facing preference.
 */
enum class KeyboardBackendMode {
    AUTO,           // UHID preferred, fallback to InputManager on failure (production default)
    UHID,           // Force UHID; fail safely if unavailable
    INPUT_MANAGER   // Force InputManager virtual injection; fail safely if unavailable
}

/** Frame dispatch. All writes go through [WriterLock]. */
class Controller(
    private val discovery: DisplayDiscovery,
    private val hid: HidDeviceManager,
    private val sdkPointer: SdkPointerBackend,
    private val keyboard: KeyboardBackend,
    private val writerLock: WriterLock,
    private val log: Logger,
) {
    @Volatile
    var shutdownRequested = false
        private set

    fun handle(frame: Frame) {
        when (frame.type) {
            Protocol.TYPE_HELLO -> handleHello(frame)
            Protocol.TYPE_LIST_DISPLAYS -> handleListDisplays(frame)
            Protocol.TYPE_SELECT_DISPLAY -> handleSelectDisplay(frame)
            Protocol.TYPE_CREATE_HID_DEVICE -> handleCreateHid(frame)
            Protocol.TYPE_DESTROY_HID_DEVICE -> hid.destroy(Messages.destroyHidDeviceId(frame.payload))
            Protocol.TYPE_HID_REPORT -> {
                val r = Messages.hidReport(frame.payload)
                hid.sendReport(r.deviceId, r.report)
            }
            Protocol.TYPE_POINTER_MOVE_REL -> {
                val (dx, dy) = Messages.pointerMoveRel(frame.payload)
                sdkPointer.moveRelative(dx, dy)
            }
            Protocol.TYPE_POINTER_BUTTON -> {
                val btn = Messages.pointerButton(frame.payload)
                sdkPointer.button(btn.button, btn.down)
            }
            Protocol.TYPE_POINTER_SCROLL -> {
                val (horizontal, vertical) = Messages.pointerScroll(frame.payload)
                sdkPointer.scroll(horizontal, vertical)
            }
            Protocol.TYPE_KEY_EVENT -> {
                keyboard.keyEvent(Messages.keyEvent(frame.payload))
            }
            Protocol.TYPE_PING -> writerLock.withLock {
                it.write(Protocol.TYPE_PONG, frame.requestId, Messages.pong())
            }
            Protocol.TYPE_SHUTDOWN -> {
                log.info("Main", "shutdown requested")
                shutdownRequested = true
            }
            else -> {
                log.error("Main", "unknown message type 0x${frame.type.toString(16)}")
                writerLock.withLock {
                    it.write(
                        Protocol.TYPE_FATAL_ERROR,
                        frame.requestId,
                        Messages.fatalError(1, "unknown message type 0x${frame.type.toString(16)}"),
                    )
                }
            }
        }
    }

    private fun handleHello(frame: Frame) {
        val version = Messages.helloVersion(frame.payload)
        if (version != Cxi.VERSION) {
            log.error("Main", "unsupported protocol version $version")
            writerLock.withLock {
                it.write(
                    Protocol.TYPE_FATAL_ERROR,
                    frame.requestId,
                    Messages.fatalError(2, "unsupported protocol version $version"),
                )
            }
            shutdownRequested = true
            return
        }
        log.info("Main", "handshake ok (v$version)")
        writerLock.withLock {
            it.write(Protocol.TYPE_HELLO_ACK, frame.requestId, Messages.helloAck(Cxi.VERSION))
        }
    }

    private fun handleListDisplays(frame: Frame) {
        val displays = discovery.displays()
        log.info("Main", "listing ${displays.size} display(s)")
        writerLock.withLock {
            it.write(Protocol.TYPE_DISPLAY_LIST, frame.requestId, Messages.displayList(displays))
        }
    }

    private fun handleSelectDisplay(frame: Frame) {
        val displayId = Messages.selectDisplayId(frame.payload)
        val displayInfo = discovery.find(displayId)
        if (displayInfo == null) {
            log.error("Main", "unknown display id=$displayId")
            writerLock.withLock {
                it.write(
                    Protocol.TYPE_FATAL_ERROR,
                    frame.requestId,
                    Messages.fatalError(3, "unknown display id=$displayId"),
                )
            }
            return
        }
        val raw = discovery.display(displayId)
        if (raw == null) {
            log.error("Main", "display id=$displayId disappeared between discovery and selection")
            writerLock.withLock {
                it.write(
                    Protocol.TYPE_FATAL_ERROR,
                    frame.requestId,
                    Messages.fatalError(3, "display id=$displayId disappeared"),
                )
            }
            return
        }
        sdkPointer.selectDisplay(raw)
        log.info("Main", "selected display id=$displayId (SDK pointer backend)")
        writerLock.withLock {
            it.write(Protocol.TYPE_DISPLAY_CHANGED, frame.requestId, Messages.displayChanged(displayInfo))
        }
    }

    private fun handleCreateHid(frame: Frame) {
        val descriptor = Messages.createHidDescriptor(frame.payload)
        val result = hid.create(descriptor)
        writerLock.withLock { w ->
            result.fold(
                onSuccess = { id -> w.write(Protocol.TYPE_HID_CREATED, frame.requestId, Messages.hidCreated(id)) },
                onFailure = { e ->
                    val err = e as? HidDeviceManager.HidError
                    w.write(
                        Protocol.TYPE_HID_ERROR,
                        frame.requestId,
                        Messages.hidError(0, err?.code ?: -1, e.message ?: "create failed"),
                    )
                },
            )
        }
    }
}