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

        val context = systemContext()
        if (context == null) {
            log.error("Main", "no system context (ActivityThread unavailable); aborting")
            return
        }
        val discovery = DisplayDiscovery(context, writerLock, log)
        val hid = HidDeviceManager(log, context)
        val controller = Controller(discovery, hid, writerLock, log)

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
                Looper.myLooper()?.quitSafely()
            }
        }
        stdinThread.name = "cxi-stdin"
        stdinThread.start()

        Looper.loop()

        hid.destroyAll()
        writerLock.withLock { it.flush() }
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

/** Frame dispatch. All writes go through [WriterLock]. */
class Controller(
    private val discovery: DisplayDiscovery,
    private val hid: HidDeviceManager,
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
        log.info("Main", "selected display id=$displayId")
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
