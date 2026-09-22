package com.crossinput.helper

import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import java.io.ByteArrayOutputStream
import java.io.FileDescriptor
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.ceil

internal data class BoundaryStallMetrics(
    val firstAdvanceIndex: Int,
    val finalPlateauStartIndex: Int,
    val finalPlateauSamples: Int,
    val longestInteriorPlateauSamples: Int,
    val startX: Double,
    val maxX: Double,
)

internal object BoundaryStallAnalysis {
    fun analyze(xs: List<Double>, epsilon: Double = 0.25): BoundaryStallMetrics? {
        if (xs.size < 3) return null

        val startX = xs.first()
        val maxX = xs.max()
        val firstAdvanceIndex = xs.indexOfFirst { it > startX + epsilon }
        if (firstAdvanceIndex < 0) return null

        var plateauStart = xs.lastIndex
        while (
            plateauStart > firstAdvanceIndex &&
            abs(xs[plateauStart - 1] - maxX) <= epsilon
        ) {
            plateauStart--
        }

        val finalPlateauSamples = xs.size - plateauStart
        var longestInterior = 1
        var current = 1
        if (plateauStart - firstAdvanceIndex >= 2) {
            for (index in (firstAdvanceIndex + 1) until plateauStart) {
                if (abs(xs[index] - xs[index - 1]) <= epsilon) {
                    current++
                    longestInterior = maxOf(longestInterior, current)
                } else {
                    current = 1
                }
            }
        }

        return BoundaryStallMetrics(
            firstAdvanceIndex = firstAdvanceIndex,
            finalPlateauStartIndex = plateauStart,
            finalPlateauSamples = finalPlateauSamples,
            longestInteriorPlateauSamples = longestInterior,
            startX = startX,
            maxX = maxX,
        )
    }
}

/**
 * Research-only issue #145 probe.
 *
 * A dedicated relative UHID mouse sends deterministic +X reports through the
 * same Android InputReader/compositor path as production. SurfaceFlinger Sprite
 * position is sampled directly through Binder after every report. The probe
 * never treats UHID write acceptance as proof of screen movement: only the
 * post-InputReader Sprite observable participates in the stall analysis.
 *
 * No clicks, key events, clipboard contents, or raw report payloads are logged.
 */
object SurfaceFlingerBoundaryStallProbe {
    private const val UHID_CREATE2 = 11
    private const val UHID_INPUT2 = 12
    private const val BUS_USB = 3
    private const val VENDOR = 0x046d
    private const val PRODUCT = 0xc077
    private const val DEVICE_NAME = "CrossInput Boundary Probe"

    private const val RIGHT_STEPS = 180
    private const val RIGHT_DX = 16
    private const val RECOVERY_STEPS = 12
    private const val RECOVERY_DX = -32
    private const val POST_REPORT_SETTLE_MS = 20L
    private const val DEVICE_SETTLE_MS = 500L

    private const val POSITION_EPSILON = 0.25
    private const val MIN_MOVEMENT_PX = 100.0
    private const val MIN_FINAL_PLATEAU_SAMPLES = 5
    private const val MIN_PLATEAU_SEPARATION = 2
    private const val MIN_RECOVERY_PX = 50.0

    private const val MAX_DUMP_BYTES = 4 * 1024 * 1024
    private const val READER_JOIN_TIMEOUT_MS = 5_000L

    @JvmStatic
    fun main(args: Array<String>) {
        val rightSteps = args.getOrNull(0)?.toIntOrNull()?.coerceIn(20, 400) ?: RIGHT_STEPS
        val settleMs = args.getOrNull(1)?.toLongOrNull()?.coerceIn(0L, 250L)
            ?: POST_REPORT_SETTLE_MS

        val binder = surfaceFlingerBinder()
        if (binder == null) {
            println("SF_STALL_PROBE result=FAIL reason=surfaceflinger-service-unavailable")
            return
        }

        val fd = try {
            createRelativeMouse()
        } catch (t: Throwable) {
            println("SF_STALL_PROBE result=FAIL reason=uhid-create exception=${t.javaClass.simpleName}")
            return
        }

        try {
            Thread.sleep(DEVICE_SETTLE_MS)

            val initial = captureSingleSprite(binder)
                ?: return fail("initial-sprite-not-singular")

            val identityName = initial.position.name
            val identityStack = initial.position.layerStack
            val rightXs = mutableListOf(initial.position.x)
            val dumpLatencies = mutableListOf(initial.dumpMs)

            repeat(rightSteps) {
                if (!sendRelative(fd, RIGHT_DX, 0)) {
                    return fail("uhid-right-report-write")
                }
                if (settleMs > 0) Thread.sleep(settleMs)

                val sample = captureSingleSprite(binder)
                    ?: return fail("right-sprite-not-singular")
                if (
                    sample.position.name != identityName ||
                    sample.position.layerStack != identityStack
                ) {
                    return fail("sprite-identity-changed")
                }

                rightXs += sample.position.x
                dumpLatencies += sample.dumpMs
            }

            val metrics = BoundaryStallAnalysis.analyze(rightXs, POSITION_EPSILON)
                ?: return fail("no-rightward-compositor-movement")

            val recoveryXs = mutableListOf<Double>()
            repeat(RECOVERY_STEPS) {
                if (!sendRelative(fd, RECOVERY_DX, 0)) {
                    return fail("uhid-recovery-report-write")
                }
                if (settleMs > 0) Thread.sleep(settleMs)

                val sample = captureSingleSprite(binder)
                    ?: return fail("recovery-sprite-not-singular")
                if (
                    sample.position.name != identityName ||
                    sample.position.layerStack != identityStack
                ) {
                    return fail("sprite-identity-changed-during-recovery")
                }

                recoveryXs += sample.position.x
                dumpLatencies += sample.dumpMs
            }

            val recoveryMinX = recoveryXs.minOrNull() ?: metrics.maxX
            val recoveryDelta = metrics.maxX - recoveryMinX
            val movement = metrics.maxX - metrics.startX
            val plateauDominatesInterior =
                metrics.finalPlateauSamples >=
                    metrics.longestInteriorPlateauSamples + MIN_PLATEAU_SEPARATION

            println("=== SURFACEFLINGER BOUNDARY STALL ORACLE ===")
            println("sprite_name=$identityName")
            println("layer_stack=$identityStack")
            println("right_samples=${rightXs.size}")
            println("start_x=${format(metrics.startX)}")
            println("max_x=${format(metrics.maxX)}")
            println("rightward_compositor_movement_px=${format(movement)}")
            println("final_plateau_samples=${metrics.finalPlateauSamples}")
            println("longest_interior_plateau_samples=${metrics.longestInteriorPlateauSamples}")
            println("plateau_dominates_interior=$plateauDominatesInterior")
            println("recovery_left_px=${format(recoveryDelta)}")
            printLatency("binder_dump_ms", dumpLatencies)

            val result = when {
                movement < MIN_MOVEMENT_PX -> "FAIL_MOVEMENT_TOO_SMALL"
                metrics.finalPlateauSamples < MIN_FINAL_PLATEAU_SAMPLES -> "FAIL_NO_STABLE_EDGE_PLATEAU"
                !plateauDominatesInterior -> "FAIL_PLATEAU_NOT_DISTINGUISHABLE"
                recoveryDelta < MIN_RECOVERY_PX -> "FAIL_NO_RECOVERY_LIVENESS"
                else -> "PASS"
            }
            println("SF_STALL_PROBE result=$result")
        } catch (t: Throwable) {
            println(
                "SF_STALL_PROBE result=FAIL reason=exception " +
                    "exception=${t.javaClass.simpleName}",
            )
        } finally {
            try {
                Os.close(fd)
            } catch (_: Throwable) {
            }
        }
    }

    private data class SpritePosition(
        val name: String,
        val layerStack: Int,
        val x: Double,
        val y: Double,
    )

    private data class SpriteSample(
        val position: SpritePosition,
        val dumpMs: Double,
    )

    private data class DumpCapture(
        val text: String,
        val dumpMs: Double,
    )

    private fun captureSingleSprite(binder: IBinder): SpriteSample? {
        val capture = captureHwLayers(binder)
        val positions = parseSpritePositions(capture.text)
        val position = positions.singleOrNull() ?: return null
        return SpriteSample(position, capture.dumpMs)
    }

    private fun parseSpritePositions(text: String): List<SpritePosition> {
        val block = Regex(
            pattern = """(?ms)^\+ BufferStateLayer \((Sprite#\d+)\).*?(?=^\+ |\z)""",
        )
        val geometry = Regex(
            pattern = """layerStack=\s*(-?\d+).*?pos=\(\s*(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\)""",
            option = RegexOption.DOT_MATCHES_ALL,
        )

        return block.findAll(text).mapNotNull { match ->
            val detail = geometry.find(match.value) ?: return@mapNotNull null
            SpritePosition(
                name = match.groupValues[1],
                layerStack = detail.groupValues[1].toInt(),
                x = detail.groupValues[2].toDouble(),
                y = detail.groupValues[3].toDouble(),
            )
        }.toList()
    }

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

                        totalBytes.addAndGet(count.toLong())
                        val remaining = MAX_DUMP_BYTES - captured.size()
                        if (remaining > 0) {
                            captured.write(buffer, 0, minOf(count, remaining))
                        }
                    }
                }
            } catch (t: Throwable) {
                readerFailure.set(t)
            }
        }, "crossinput-sf-stall-reader")
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

        val size = totalBytes.get()
        if (size <= 0 || size > MAX_DUMP_BYTES) {
            throw IOException("invalid SurfaceFlinger dump size: $size")
        }

        return DumpCapture(
            text = captured.toByteArray().toString(Charsets.UTF_8),
            dumpMs = dumpMs,
        )
    }

    private fun createRelativeMouse(): FileDescriptor {
        val fd = Os.open("/dev/uhid", OsConstants.O_RDWR, 0)
        try {
            val descriptor = UhidPointerInjector.MOUSE_DESCRIPTOR
            val payload = create2Payload(DEVICE_NAME, descriptor)
            Os.write(fd, payload, 0, payload.size)
            return fd
        } catch (t: Throwable) {
            try {
                Os.close(fd)
            } catch (_: Throwable) {
            }
            throw t
        }
    }

    private fun sendRelative(fd: FileDescriptor, dx: Int, dy: Int): Boolean {
        require(dx in -127..127 && dy in -127..127)
        val report = byteArrayOf(0, dx.toByte(), dy.toByte(), 0, 0)
        val buffer = ByteBuffer.allocate(4 + 2 + report.size)
            .order(ByteOrder.LITTLE_ENDIAN)
        buffer.putInt(UHID_INPUT2)
        buffer.putShort(report.size.toShort())
        buffer.put(report)
        return try {
            Os.write(fd, buffer.array(), 0, buffer.capacity()) == buffer.capacity()
        } catch (_: Throwable) {
            false
        }
    }

    private fun create2Payload(name: String, descriptor: ByteArray): ByteArray {
        val buffer = ByteBuffer.allocate(
            4 + 128 + 64 + 64 + 2 + 2 + 4 + 4 + 4 + 4 + descriptor.size,
        ).order(ByteOrder.LITTLE_ENDIAN)

        buffer.putInt(UHID_CREATE2)
        val nameBytes = name.toByteArray(Charsets.US_ASCII)
        buffer.put(nameBytes)
        buffer.put(ByteArray(128 - nameBytes.size))
        buffer.put(ByteArray(64))
        buffer.put(ByteArray(64))
        buffer.putShort(descriptor.size.toShort())
        buffer.putShort(BUS_USB.toShort())
        buffer.putInt(VENDOR)
        buffer.putInt(PRODUCT)
        buffer.putInt(0)
        buffer.putInt(0)
        buffer.put(descriptor)
        return buffer.array()
    }

    private fun surfaceFlingerBinder(): IBinder? =
        try {
            val serviceManager = Class.forName("android.os.ServiceManager")
            val getService = serviceManager.getMethod("getService", String::class.java)
            getService.invoke(null, "SurfaceFlinger") as? IBinder
        } catch (_: Throwable) {
            null
        }

    private fun fail(reason: String) {
        println("SF_STALL_PROBE result=FAIL reason=$reason")
    }

    private fun nanosToMillis(nanos: Long): Double = nanos / 1_000_000.0

    private fun format(value: Double): String = "%.3f".format(value)

    private fun printLatency(label: String, values: List<Double>) {
        if (values.isEmpty()) return
        val sorted = values.sorted()
        val p50 = percentile(sorted, 0.50)
        val p95 = percentile(sorted, 0.95)
        println(
            "$label min=${format(sorted.first())} " +
                "p50=${format(p50)} " +
                "p95=${format(p95)} " +
                "max=${format(sorted.last())}",
        )
    }

    private fun percentile(sorted: List<Double>, fraction: Double): Double {
        val index = (ceil(sorted.size * fraction).toInt() - 1).coerceIn(0, sorted.lastIndex)
        return sorted[index]
    }
}
