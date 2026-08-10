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
import java.util.concurrent.atomic.AtomicBoolean

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
        val mainLooper = Looper.myLooper()
            ?: error("main looper unavailable after Looper.prepare()")

        val stdout = BufferedOutputStream(FileOutputStream(FileDescriptor.out), 8192)
        val writer = FrameWriter(stdout)
        val writerLock = WriterLock(writer)
        val log = Logger(writerLock)

        val mode = KeyboardBackendMode.fromArgs(args).getOrElse {
            log.error("Main", it.message ?: "invalid ${KeyboardBackendMode.FLAG} argument")
            System.exit(2)
            return
        }
        log.info("Main", "keyboard backend mode=${mode.token}")

        val context = systemContext()
        if (context == null) {
            log.error("Main", "no system context (ActivityThread unavailable); aborting")
            return
        }
        val sdkPointer = SdkPointerBackend(log, context)
        val discovery = DisplayDiscovery(context, writerLock, log, sdkPointer::refreshMetrics)
        val hid = HidDeviceManager(log, context)
        val keyboard = KeyboardBackend(log, context, hid, mode)
        val lifecycle = MainShutdownLifecycle(
            requestMainLoopQuit = { mainLooper.quitSafely() },
            destroyKeyboard = keyboard::destroy,
            destroyHid = hid::destroyAll,
            flush = { writerLock.withLock { it.flush() } },
        )
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
                lifecycle.requestQuit()
            }
        }
        stdinThread.name = "cxi-stdin"
        stdinThread.start()

        Looper.loop()

        lifecycle.cleanupOnce()
        System.exit(0)
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
 * Coordinates the two-thread shutdown boundary without owning Android
 * framework objects. The stdin worker requests main-loop termination; only the
 * main thread performs cleanup after [Looper.loop] returns.
 */
class MainShutdownLifecycle(
    private val requestMainLoopQuit: () -> Unit,
    private val destroyKeyboard: () -> Unit,
    private val destroyHid: () -> Unit,
    private val flush: () -> Unit,
) {
    private val quitRequested = AtomicBoolean(false)
    private val cleanupStarted = AtomicBoolean(false)

    fun requestQuit() {
        if (quitRequested.compareAndSet(false, true)) requestMainLoopQuit()
    }

    fun cleanupOnce() {
        if (!cleanupStarted.compareAndSet(false, true)) return
        try {
            destroyKeyboard()
        } finally {
            try {
                destroyHid()
            } finally {
                flush()
            }
        }
    }
}

/**
 * Keyboard backend selection mode.
 * Test-only deterministic override; not a user-facing preference.
 */
enum class KeyboardBackendMode(val token: String) {
    /** UHID preferred, automatic fallback to virtual injection (production default). */
    AUTO("auto"),

    /** Force UHID; never falls back to virtual injection. */
    UHID("uhid"),

    /** Force InputManager virtual injection; never uses UHID. */
    INPUT_MANAGER("input-manager");

    companion object {
        const val FLAG = "--keyboard-backend"

        private val EXPECTED = entries.joinToString("|") { it.token }

        /** Resolves one value token; null when it names no mode. */
        fun fromToken(token: String): KeyboardBackendMode? =
            entries.firstOrNull { it.token == token.lowercase() }

        /**
         * Reads the mode from helper arguments, accepting both
         * `--keyboard-backend=<value>` and `--keyboard-backend <value>`.
         * Absent flag means [AUTO]; a missing or unknown value is a failure so
         * the helper refuses to run under a silently wrong backend (a forced
         * backend that quietly degrades to AUTO would invalidate a test run).
         */
        fun fromArgs(args: Array<out String>): Result<KeyboardBackendMode> {
            var mode = AUTO
            var i = 0
            while (i < args.size) {
                val arg = args[i]
                val token = when {
                    arg.startsWith("$FLAG=") -> arg.substringAfter('=')
                    arg == FLAG -> args.getOrNull(++i)
                        ?: return failure("$FLAG requires a value ($EXPECTED)")
                    else -> {
                        i++
                        continue
                    }
                }
                mode = fromToken(token)
                    ?: return failure("invalid $FLAG value: $token (expected $EXPECTED)")
                i++
            }
            return Result.success(mode)
        }

        private fun failure(message: String): Result<KeyboardBackendMode> =
            Result.failure(IllegalArgumentException(message))
    }
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
        val display = discovery.find(displayId)
        if (display == null) {
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
            it.write(Protocol.TYPE_DISPLAY_CHANGED, frame.requestId, Messages.displayChanged(display))
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
