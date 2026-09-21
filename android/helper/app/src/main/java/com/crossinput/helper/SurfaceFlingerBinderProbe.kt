package com.crossinput.helper

import android.os.IBinder
import android.os.Process
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.ceil

/**
 * Research-only capability probe for issue #145.
 *
 * Calls SurfaceFlinger directly through Binder from the existing shell/app_process
 * privilege model. It measures the cost of --hwclayers without adb-shell process
 * startup and verifies that the Sprite position changes while the user moves the
 * real DeX pointer. Raw pointer deltas and key/input payloads are never logged.
 */
object SurfaceFlingerBinderProbe {
    private const val DEFAULT_SAMPLES = 24
    private const val DEFAULT_DELAY_MS = 50L
    private const val MAX_DUMP_BYTES = 4 * 1024 * 1024

    @JvmStatic
    fun main(args: Array<String>) {
        val samples = args.getOrNull(0)?.toIntOrNull()?.coerceIn(3, 200) ?: DEFAULT_SAMPLES
        val delayMs = args.getOrNull(1)?.toLongOrNull()?.coerceIn(0L, 1_000L) ?: DEFAULT_DELAY_MS

        val binder = surfaceFlingerBinder()
        if (binder == null) {
            println("SF_BINDER_PROBE result=FAIL reason=service-unavailable")
            return
        }

        val scratch = File("/data/local/tmp/crossinput-sf-binder-probe-${Process.myPid()}.txt")
        val dumpLatencies = mutableListOf<Double>()
        val totalLatencies = mutableListOf<Double>()
        val observations = mutableListOf<SurfaceFlingerSpritePosition?>()
        var successfulDumps = 0

        try {
            RandomAccessFile(scratch, "rw").use { file ->
                repeat(samples) { index ->
                    val totalStart = System.nanoTime()
                    file.setLength(0)
                    file.seek(0)

                    val dumpStart = System.nanoTime()
                    try {
                        binder.dump(file.fd, arrayOf("--hwclayers"))
                    } catch (t: Throwable) {
                        println(
                            "SF_BINDER_PROBE result=FAIL reason=binder-dump-error " +
                                "exception=${t.javaClass.simpleName}",
                        )
                        return
                    }
                    val dumpMs = nanosToMillis(System.nanoTime() - dumpStart)
                    successfulDumps++

                    val length = file.length()
                    if (length <= 0 || length > MAX_DUMP_BYTES) {
                        println(
                            "SF_BINDER_PROBE result=FAIL reason=invalid-dump-size " +
                                "bytes=$length",
                        )
                        return
                    }

                    file.seek(0)
                    val bytes = ByteArray(length.toInt())
                    file.readFully(bytes)
                    val positions = SurfaceFlingerHwLayersParser.parseSpritePositions(
                        bytes.toString(Charsets.UTF_8),
                    )

                    observations += positions.singleOrNull()
                    dumpLatencies += dumpMs
                    totalLatencies += nanosToMillis(System.nanoTime() - totalStart)

                    if (index + 1 < samples && delayMs > 0) {
                        Thread.sleep(delayMs)
                    }
                }
            }
        } finally {
            scratch.delete()
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

    private fun surfaceFlingerBinder(): IBinder? =
        try {
            val serviceManager = Class.forName("android.os.ServiceManager")
            val getService = serviceManager.getMethod("getService", String::class.java)
            getService.invoke(null, "SurfaceFlinger") as? IBinder
        } catch (_: Throwable) {
            null
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
