package com.crossinput.helper

import android.os.IBinder
import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.ceil

/**
 * Research-only capability probe for issue #145.
 *
 * Calls SurfaceFlinger directly through Binder from the existing shell/app_process
 * privilege model. It measures the cost of --hwclayers without adb-shell process
 * startup and verifies that the Sprite position changes while the user moves the
 * real DeX pointer. Raw pointer deltas and key/input payloads are never logged.
 *
 * The dump sink deliberately mirrors native dumpsys: a pipe write-end is sent to
 * the service while a reader drains the other end concurrently. Passing a regular
 * /data/local/tmp file descriptor is not equivalent on production SELinux builds.
 */
object SurfaceFlingerBinderProbe {
    private const val DEFAULT_SAMPLES = 24
    private const val DEFAULT_DELAY_MS = 50L
    private const val MAX_DUMP_BYTES = 4 * 1024 * 1024
    private const val READER_JOIN_TIMEOUT_MS = 5_000L

    @JvmStatic
    fun main(args: Array<String>) {
        val samples = args.getOrNull(0)?.toIntOrNull()?.coerceIn(3, 200) ?: DEFAULT_SAMPLES
        val delayMs = args.getOrNull(1)?.toLongOrNull()?.coerceIn(0L, 1_000L) ?: DEFAULT_DELAY_MS

        val binder = surfaceFlingerBinder()
        if (binder == null) {
            println("SF_BINDER_PROBE result=FAIL reason=service-unavailable")
            return
        }

        val dumpLatencies = mutableListOf<Double>()
        val totalLatencies = mutableListOf<Double>()
        val observations = mutableListOf<SurfaceFlingerSpritePosition?>()
        var successfulDumps = 0

        repeat(samples) { index ->
            val totalStart = System.nanoTime()
            val capture = try {
                captureHwLayers(binder)
            } catch (t: Throwable) {
                println(
                    "SF_BINDER_PROBE result=FAIL reason=binder-dump-error " +
                        "exception=${t.javaClass.simpleName} " +
                        "binder_alive=${safeBinderAlive(binder)} " +
                        "binder_ping=${safeBinderPing(binder)}",
                )
                return
            }
            successfulDumps++

            if (capture.totalBytes <= 0 || capture.totalBytes > MAX_DUMP_BYTES) {
                println(
                    "SF_BINDER_PROBE result=FAIL reason=invalid-dump-size " +
                        "bytes=${capture.totalBytes}",
                )
                return
            }

            val positions = SurfaceFlingerHwLayersParser.parseSpritePositions(
                capture.bytes.toString(Charsets.UTF_8),
            )

            observations += positions.singleOrNull()
            dumpLatencies += capture.dumpMs
            totalLatencies += nanosToMillis(System.nanoTime() - totalStart)

            if (index + 1 < samples && delayMs > 0) {
                Thread.sleep(delayMs)
            }
        }

        val valid = observations.filterNotNull()
        val identity = valid.firstOrNull()?.let { first ->
            valid.all { it.name == first.name && it.layerStack == first.layerStack }
        } ?: false
        val positionChanges = valid.zipWithNext().count { (before, after) ->
            before.x != after.x || before.y != after.y
        }
        val stableIdentity = identity && valid.size == observations.size

        println("=== SURFACEFLINGER DIRECT-BINDER ORACLE ===")
        println("samples=${observations.size}")
        println("successful_dumps=$successfulDumps")
        println("parseable_samples=${valid.size}")
        println("stable_sprite_identity=$stableIdentity")
        println("position_changes=$positionChanges")
        valid.firstOrNull()?.let {
            println("sprite_name=${it.name}")
            println("layer_stack=${it.layerStack}")
        }
        printLatency("binder_dump_ms", dumpLatencies)
        printLatency("total_sample_ms", totalLatencies)

        val result = when {
            successfulDumps != samples -> "FAIL"
            valid.size != samples -> "FAIL"
            !stableIdentity -> "FAIL"
            positionChanges == 0 -> "UNVERIFIED_STATIC"
            else -> "PASS"
        }
        println("SF_BINDER_PROBE result=$result")
    }

    private data class DumpCapture(
        val bytes: ByteArray,
        val totalBytes: Long,
        val dumpMs: Double,
    )

    /**
     * Mirrors dumpsys' service-dump transport closely enough for this probe:
     * send a pipe write-end to the remote Binder and drain the read-end while
     * the synchronous DUMP_TRANSACTION executes.
     */
    private fun captureHwLayers(binder: IBinder): DumpCapture {
        val pipe = ParcelFileDescriptor.createPipe()
        val readEnd = pipe[0]
        val writeEnd = pipe[1]
        val captured = ByteArrayOutputStream()
        val totalBytes = AtomicLong(0)
        val readerFailure = AtomicReference<Throwable?>(null)

        val reader = Thread({
            try {
                ParcelFileDescriptor.AutoCloseInputStream(readEnd).use { input ->
                    val buffer = ByteArray(8 * 1024)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break

                        val total = totalBytes.addAndGet(count.toLong())
                        val remaining = MAX_DUMP_BYTES - captured.size()
                        if (remaining > 0) {
                            captured.write(buffer, 0, minOf(count, remaining))
                        }

                        // Keep draining even after the cap so SurfaceFlinger can
                        // finish its synchronous dump instead of blocking on a
                        // full pipe. The caller rejects the oversized capture.
                        if (total < 0) {
                            throw IOException("dump byte counter overflow")
                        }
                    }
                }
            } catch (t: Throwable) {
                readerFailure.set(t)
            }
        }, "crossinput-sf-dump-reader")
        reader.isDaemon = true
        reader.start()

        val dumpStart = System.nanoTime()
        try {
            binder.dump(writeEnd.fileDescriptor, arrayOf("--hwclayers"))
        } finally {
            writeEnd.close()
        }
        val dumpMs = nanosToMillis(System.nanoTime() - dumpStart)

        reader.join(READER_JOIN_TIMEOUT_MS)
        if (reader.isAlive) {
            try {
                readEnd.close()
            } catch (_: Throwable) {
            }
            reader.interrupt()
            throw IOException("SurfaceFlinger dump reader timed out")
        }
        readerFailure.get()?.let { throw IOException("SurfaceFlinger dump reader failed", it) }

        return DumpCapture(
            bytes = captured.toByteArray(),
            totalBytes = totalBytes.get(),
            dumpMs = dumpMs,
        )
    }

    private fun surfaceFlingerBinder(): IBinder? =
        try {
            val serviceManager = Class.forName("android.os.ServiceManager")
            val getService = serviceManager.getMethod("getService", String::class.java)
            getService.invoke(null, "SurfaceFlinger") as? IBinder
        } catch (_: Throwable) {
            null
        }

    private fun safeBinderAlive(binder: IBinder): Boolean =
        try {
            binder.isBinderAlive
        } catch (_: Throwable) {
            false
        }

    private fun safeBinderPing(binder: IBinder): Boolean =
        try {
            binder.pingBinder()
        } catch (_: Throwable) {
            false
        }

    private fun nanosToMillis(nanos: Long): Double = nanos / 1_000_000.0

    private fun printLatency(label: String, values: List<Double>) {
        if (values.isEmpty()) return
        val sorted = values.sorted()
        val p50 = percentile(sorted, 0.50)
        val p95 = percentile(sorted, 0.95)
        println(
            "$label min=${"%.1f".format(sorted.first())} " +
                "p50=${"%.1f".format(p50)} " +
                "p95=${"%.1f".format(p95)} " +
                "max=${"%.1f".format(sorted.last())}",
        )
    }

    private fun percentile(sorted: List<Double>, fraction: Double): Double {
        val index = (ceil(sorted.size * fraction).toInt() - 1).coerceIn(0, sorted.lastIndex)
        return sorted[index]
    }
}
