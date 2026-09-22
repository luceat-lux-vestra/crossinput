package com.crossinput.helper

import android.os.IBinder
import android.os.ParcelFileDescriptor
import com.crossinput.helper.protocol.Messages
import com.crossinput.helper.protocol.Protocol
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

enum class PointerBoundaryAuthority {
    DELIVERED_COORDINATES,
    COMPOSITOR,
    UNAVAILABLE,
}

internal data class SurfaceFlingerSpritePosition(
    val name: String,
    val layerStack: Int,
    val x: Double,
    val y: Double,
)

internal class BoundaryPlateauTracker(
    private val epsilon: Double = 0.25,
    private val requiredSamples: Int = 5,
    private val minimumDurationNanos: Long = 80_000_000L,
) {
    private var maxProgress: Double? = null
    private var plateauSamples = 0
    private var plateauStartedNanos = 0L

    fun reset(progress: Double? = null) {
        maxProgress = progress
        plateauSamples = 0
        plateauStartedNanos = 0L
    }

    fun observe(progress: Double, nowNanos: Long): Boolean {
        val currentMax = maxProgress
        if (currentMax == null || progress > currentMax + epsilon) {
            reset(progress)
            return false
        }
        if (progress < currentMax - epsilon) {
            reset(progress)
            return false
        }

        if (plateauSamples == 0) plateauStartedNanos = nowNanos
        plateauSamples++
        return plateauSamples >= requiredSamples &&
            nowNanos - plateauStartedNanos >= minimumDurationNanos
    }
}

internal interface BoundarySpriteOracle {
    fun sample(layerStack: Int): SurfaceFlingerSpritePosition
}

internal class SurfaceFlingerSpriteOracle : BoundarySpriteOracle {
    private val binder: IBinder = surfaceFlingerBinder()
        ?: throw IOException("SurfaceFlinger service unavailable")

    override fun sample(layerStack: Int): SurfaceFlingerSpritePosition {
        val text = captureHwLayers()
        val matches = parseSpritePositions(text).filter { it.layerStack == layerStack }
        if (matches.size != 1) {
            throw IOException("expected one Sprite for layerStack=$layerStack, found ${matches.size}")
        }
        return matches.single()
    }

    private fun captureHwLayers(): String {
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
                        if (total > MAX_DUMP_BYTES) {
                            continue
                        }
                        captured.write(buffer, 0, count)
                    }
                }
            } catch (t: Throwable) {
                readerFailure.set(t)
            }
        }, "crossinput-boundary-dump-reader")
        reader.isDaemon = true
        reader.start()

        try {
            binder.dump(writeEnd.fileDescriptor, arrayOf("--hwclayers"))
        } finally {
            writeEnd.close()
        }

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
        return captured.toByteArray().toString(Charsets.UTF_8)
    }

    private fun parseSpritePositions(text: String): List<SurfaceFlingerSpritePosition> {
        val spriteBlock = Regex(
            pattern = """(?ms)^\+ BufferStateLayer \((Sprite#\d+)\).*?(?=^\+ |\z)""",
        )
        val geometry = Regex(
            pattern = """layerStack=\s*(-?\d+).*?pos=\(\s*(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\)""",
            option = RegexOption.DOT_MATCHES_ALL,
        )
        return spriteBlock.findAll(text).mapNotNull { match ->
            val detail = geometry.find(match.value) ?: return@mapNotNull null
            SurfaceFlingerSpritePosition(
                name = match.groupValues[1],
                layerStack = detail.groupValues[1].toInt(),
                x = detail.groupValues[2].toDouble(),
                y = detail.groupValues[3].toDouble(),
            )
        }.toList()
    }

    private fun surfaceFlingerBinder(): IBinder? =
        try {
            val serviceManager = Class.forName("android.os.ServiceManager")
            val getService = serviceManager.getMethod("getService", String::class.java)
            getService.invoke(null, "SurfaceFlinger") as? IBinder
        } catch (_: Throwable) {
            null
        }

    companion object {
        private const val MAX_DUMP_BYTES = 4 * 1024 * 1024
        private const val READER_JOIN_TIMEOUT_MS = 5_000L
    }
}

/**
 * Android-owned return-boundary authority for issue #145.
 *
 * START is completed before macOS suppression. COMPOSITOR mode samples
 * SurfaceFlinger only while fresh return-direction pointer intent exists.
 * Semantic pointer delivery never waits for the sampler.
 */
class BoundaryWatchController internal constructor(
    private val writer: WriterLock,
    private val log: Logger,
    private val oracleFactory: () -> BoundarySpriteOracle = { SurfaceFlingerSpriteOracle() },
) {
    data class StartResult(
        val mode: Int,
        val layerStack: Int,
        val errorCode: Int? = null,
    )

    private data class WatchState(
        val token: Long,
        val displayId: Int,
        val layerStack: Int,
        val edge: Int,
        val spriteName: String,
        val tracker: BoundaryPlateauTracker,
        var returnIntentSequence: Long = 0,
        var lastSampledIntentSequence: Long = 0,
        var emitted: Boolean = false,
    )

    private val lock = Any()
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "crossinput-boundary-watch").apply { isDaemon = true }
    }
    private var oracle: BoundarySpriteOracle? = null
    private var watch: WatchState? = null
    private var workerRunning = false
    private var closed = false
    private val displayGenerations = mutableMapOf<Int, Long>()

    fun start(
        token: Long,
        displayId: Int,
        layerStack: Int,
        edge: Int,
        authority: PointerBoundaryAuthority,
    ): StartResult {
        if (edge !in 0..3) {
            return StartResult(MODE_DELIVERED_COORDINATES, layerStack, ERROR_TARGET_MISMATCH)
        }

        val displayGeneration = synchronized(lock) {
            if (closed) {
                return StartResult(MODE_COMPOSITOR, layerStack, ERROR_ORACLE_UNAVAILABLE)
            }
            watch = null
            workerRunning = false
            displayGenerations[displayId] ?: 0L
        }

        return when (authority) {
            PointerBoundaryAuthority.DELIVERED_COORDINATES ->
                StartResult(MODE_DELIVERED_COORDINATES, layerStack)

            PointerBoundaryAuthority.UNAVAILABLE ->
                StartResult(MODE_DELIVERED_COORDINATES, layerStack, ERROR_ORACLE_UNAVAILABLE)

            PointerBoundaryAuthority.COMPOSITOR -> {
                if (layerStack < 0) {
                    return StartResult(MODE_COMPOSITOR, layerStack, ERROR_ORACLE_UNAVAILABLE)
                }
                val currentOracle = try {
                    oracle ?: oracleFactory().also { oracle = it }
                } catch (_: Throwable) {
                    return StartResult(MODE_COMPOSITOR, layerStack, ERROR_ORACLE_UNAVAILABLE)
                }
                val first = try {
                    currentOracle.sample(layerStack)
                } catch (_: Throwable) {
                    return StartResult(MODE_COMPOSITOR, layerStack, ERROR_ORACLE_UNAVAILABLE)
                }
                val state = WatchState(
                    token = token,
                    displayId = displayId,
                    layerStack = layerStack,
                    edge = edge,
                    spriteName = first.name,
                    tracker = BoundaryPlateauTracker().also {
                        it.reset(progress(edge, first))
                    },
                )
                synchronized(lock) {
                    if (closed) {
                        return StartResult(MODE_COMPOSITOR, layerStack, ERROR_ORACLE_UNAVAILABLE)
                    }
                    if ((displayGenerations[displayId] ?: 0L) != displayGeneration) {
                        return StartResult(MODE_COMPOSITOR, layerStack, ERROR_TARGET_MISMATCH)
                    }
                    watch = state
                }
                StartResult(MODE_COMPOSITOR, layerStack)
            }
        }
    }

    fun stop(token: Long) {
        synchronized(lock) {
            if (watch?.token == token) watch = null
        }
    }

    fun invalidateForTargetChange() {
        val invalidated = synchronized(lock) {
            val state = watch ?: return@synchronized null
            bumpDisplayGenerationLocked(state.displayId)
            watch = null
            workerRunning = false
            state.token
        }
        invalidated?.let { emitError(it, ERROR_TARGET_MISMATCH) }
    }

    fun invalidateForDisplayChange(displayId: Int) {
        val invalidated = synchronized(lock) {
            bumpDisplayGenerationLocked(displayId)
            val state = watch
            if (state == null || state.displayId != displayId) {
                return@synchronized null
            }
            watch = null
            workerRunning = false
            state.token
        }
        invalidated?.let { emitError(it, ERROR_TARGET_MISMATCH) }
    }

    fun onPointerMove(dx: Int, dy: Int, authority: PointerBoundaryAuthority) {
        var runtimeError: Pair<Long, Int>? = null
        var shouldSchedule = false
        synchronized(lock) {
            val state = watch ?: return
            if (state.emitted) return

            if (authority != PointerBoundaryAuthority.COMPOSITOR) {
                runtimeError = Pair(state.token, ERROR_BACKEND_CHANGED)
                watch = null
                return@synchronized
            }

            when (intentDirection(state.edge, dx, dy)) {
                1 -> {
                    state.returnIntentSequence++
                    if (!workerRunning) {
                        workerRunning = true
                        shouldSchedule = true
                    }
                }
                -1 -> {
                    state.tracker.reset()
                    state.lastSampledIntentSequence = state.returnIntentSequence
                }
            }
        }

        runtimeError?.let {
            emitError(it.first, it.second)
            return
        }
        if (shouldSchedule) executor.execute(::drainSamples)
    }

    fun close() {
        synchronized(lock) {
            closed = true
            watch = null
        }
        executor.shutdownNow()
    }

    private fun drainSamples() {
        while (true) {
            val snapshot = synchronized(lock) {
                val state = watch
                if (
                    closed || state == null || state.emitted ||
                    state.returnIntentSequence <= state.lastSampledIntentSequence
                ) {
                    workerRunning = false
                    return
                }
                SampleRequest(
                    token = state.token,
                    displayId = state.displayId,
                    layerStack = state.layerStack,
                    edge = state.edge,
                    spriteName = state.spriteName,
                    intentSequence = state.returnIntentSequence,
                )
            }

            val sample = try {
                (oracle ?: throw IOException("oracle unavailable")).sample(snapshot.layerStack)
            } catch (_: Throwable) {
                failRuntime(snapshot.token, ERROR_OBSERVATION_FAILED)
                return
            }

            var reached = false
            var observationFailed = false
            var staleSample = false
            synchronized(lock) {
                val state = watch
                if (
                    state == null || state.token != snapshot.token ||
                    state.displayId != snapshot.displayId
                ) {
                    staleSample = true
                } else if (
                    sample.name != snapshot.spriteName ||
                    sample.layerStack != snapshot.layerStack
                ) {
                    watch = null
                    workerRunning = false
                    observationFailed = true
                } else {
                    state.lastSampledIntentSequence = snapshot.intentSequence
                    reached = state.tracker.observe(progress(state.edge, sample), System.nanoTime())
                    if (reached) {
                        state.emitted = true
                        workerRunning = false
                    }
                }
            }

            if (staleSample) continue
            if (observationFailed) {
                emitError(snapshot.token, ERROR_OBSERVATION_FAILED)
                return
            }
            if (reached) {
                emitReached(snapshot.token, snapshot.displayId, snapshot.edge)
                return
            }
        }
    }

    private data class SampleRequest(
        val token: Long,
        val displayId: Int,
        val layerStack: Int,
        val edge: Int,
        val spriteName: String,
        val intentSequence: Long,
    )

    private fun failRuntime(token: Long, code: Int) {
        val shouldEmit = synchronized(lock) {
            if (watch?.token != token) {
                false
            } else {
                watch = null
                workerRunning = false
                true
            }
        }
        if (shouldEmit) emitError(token, code)
    }

    private fun emitReached(token: Long, displayId: Int, edge: Int) {
        writer.withLock {
            it.write(Protocol.TYPE_BOUNDARY_REACHED, 0, Messages.boundaryReached(token, displayId, edge))
            it.flush()
        }
        log.info(TAG, "boundary reached display=$displayId edge=$edge")
    }

    private fun emitError(token: Long, code: Int) {
        writer.withLock {
            it.write(Protocol.TYPE_BOUNDARY_WATCH_ERROR, 0, Messages.boundaryWatchError(token, code))
            it.flush()
        }
        log.warn(TAG, "boundary watch failed code=$code")
    }

    private fun bumpDisplayGenerationLocked(displayId: Int) {
        displayGenerations[displayId] = (displayGenerations[displayId] ?: 0L) + 1L
    }

    private fun progress(edge: Int, position: SurfaceFlingerSpritePosition): Double = when (edge) {
        EDGE_LEFT -> -position.x
        EDGE_RIGHT -> position.x
        EDGE_TOP -> -position.y
        EDGE_BOTTOM -> position.y
        else -> Double.NaN
    }

    private fun intentDirection(edge: Int, dx: Int, dy: Int): Int = when (edge) {
        EDGE_LEFT -> sign(-dx)
        EDGE_RIGHT -> sign(dx)
        EDGE_TOP -> sign(-dy)
        EDGE_BOTTOM -> sign(dy)
        else -> 0
    }

    private fun sign(value: Int): Int = when {
        value > 0 -> 1
        value < 0 -> -1
        else -> 0
    }

    companion object {
        const val MODE_DELIVERED_COORDINATES = 0
        const val MODE_COMPOSITOR = 1

        const val ERROR_TARGET_MISMATCH = 1
        const val ERROR_ORACLE_UNAVAILABLE = 2
        const val ERROR_BACKEND_CHANGED = 3
        const val ERROR_OBSERVATION_FAILED = 4

        const val EDGE_LEFT = 0
        const val EDGE_RIGHT = 1
        const val EDGE_TOP = 2
        const val EDGE_BOTTOM = 3

        private const val TAG = "BoundaryWatch"
    }
}