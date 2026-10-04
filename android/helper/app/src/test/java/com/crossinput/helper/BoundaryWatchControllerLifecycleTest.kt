package com.crossinput.helper

import com.crossinput.helper.protocol.FrameReader
import com.crossinput.helper.protocol.FrameWriter
import com.crossinput.helper.protocol.Protocol
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BoundaryWatchControllerLifecycleTest {
    @Test
    fun displayChangeDuringPreflightRejectsStaleReady() {
        val output = ByteArrayOutputStream()
        val writer = WriterLock(FrameWriter(output))
        val oracle = BlockingOracle()
        val controller = BoundaryWatchController(
            writer = writer,
            log = Logger(writer),
            oracleFactory = { oracle },
        )
        val result = AtomicReference<BoundaryWatchController.StartResult>()

        val starter = Thread {
            result.set(
                controller.start(
                    token = 41L,
                    displayId = 2,
                    layerStack = 2,
                    edge = BoundaryWatchController.EDGE_RIGHT,
                    authority = PointerBoundaryAuthority.COMPOSITOR,
                ),
            )
        }
        starter.start()

        assertTrue("preflight never reached oracle", oracle.entered.await(1, TimeUnit.SECONDS))
        controller.invalidateForDisplayChange(2)
        oracle.release.countDown()
        starter.join(1_000)

        assertEquals(
            BoundaryWatchController.ERROR_TARGET_MISMATCH,
            result.get().errorCode,
        )
        controller.close()
    }

    @Test
    fun activeWatchDisplayChangeEmitsFailClosedError() {
        val output = ByteArrayOutputStream()
        val writer = WriterLock(FrameWriter(output))
        val controller = BoundaryWatchController(
            writer = writer,
            log = Logger(writer),
            oracleFactory = { FixedOracle() },
        )

        val started = controller.start(
            token = 77L,
            displayId = 2,
            layerStack = 9,
            edge = BoundaryWatchController.EDGE_RIGHT,
            authority = PointerBoundaryAuthority.COMPOSITOR,
        )
        assertNull(started.errorCode)

        controller.invalidateForDisplayChange(2)

        val frame = FrameReader(ByteArrayInputStream(output.toByteArray())).readFrame()
        requireNotNull(frame)
        assertEquals(Protocol.TYPE_BOUNDARY_WATCH_ERROR, frame.type)
        val payload = ByteBuffer.wrap(frame.payload).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(77L, payload.long)
        assertEquals(
            BoundaryWatchController.ERROR_TARGET_MISMATCH,
            payload.get().toInt() and 0xFF,
        )
        controller.close()
    }

    @Test
    fun reversalInvalidatesInFlightSampleBeforeFreshIntentWindow() {
        val output = ByteArrayOutputStream()
        val writer = WriterLock(FrameWriter(output))
        val oracle = ReversalRaceOracle()
        val controller = BoundaryWatchController(
            writer = writer,
            log = Logger(writer),
            oracleFactory = { oracle },
            trackerFactory = {
                BoundaryPlateauTracker(requiredSamples = 1, minimumDurationNanos = 0)
            },
        )

        val started = controller.start(
            token = 90L,
            displayId = 2,
            layerStack = 9,
            edge = BoundaryWatchController.EDGE_RIGHT,
            authority = PointerBoundaryAuthority.COMPOSITOR,
        )
        assertNull(started.errorCode)

        controller.onPointerMove(10, 0, PointerBoundaryAuthority.COMPOSITOR)
        assertTrue("old intent sample never started", oracle.oldSampleEntered.await(1, TimeUnit.SECONDS))

        controller.onPointerMove(-10, 0, PointerBoundaryAuthority.COMPOSITOR)
        oracle.releaseOldSample.countDown()

        controller.onPointerMove(10, 0, PointerBoundaryAuthority.COMPOSITOR)
        assertTrue(
            "fresh intent did not reach a new sample; stale sample likely confirmed",
            oracle.freshSampleEntered.await(1, TimeUnit.SECONDS),
        )
        assertEquals(
            "stale pre-reversal sample must not emit a boundary frame",
            0,
            output.size(),
        )

        oracle.releaseFreshSample.countDown()
        controller.close()
    }

    @Test
    fun compositorCadenceSurvivesWorkerRestart() {
        val output = ByteArrayOutputStream()
        val writer = WriterLock(FrameWriter(output))
        val clock = AtomicLong(0L)
        val oracle = CadenceOracle(clock)
        val controller = BoundaryWatchController(
            writer = writer,
            log = Logger(writer),
            oracleFactory = { oracle },
            trackerFactory = {
                BoundaryPlateauTracker(
                    requiredSamples = 99,
                    minimumDurationNanos = Long.MAX_VALUE,
                )
            },
            sampleIntervalMillis = 90L,
            nowNanos = { clock.get() },
            sleepMillis = { millis ->
                clock.addAndGet(millis * 1_000_000L)
            },
        )

        val started = controller.start(
            token = 92L,
            displayId = 2,
            layerStack = 9,
            edge = BoundaryWatchController.EDGE_RIGHT,
            authority = PointerBoundaryAuthority.COMPOSITOR,
        )
        assertNull(started.errorCode)

        controller.onPointerMove(
            10,
            0,
            PointerBoundaryAuthority.COMPOSITOR,
        )
        assertTrue(
            "fresh return-intent sample missing",
            oracle.second.await(1, TimeUnit.SECONDS),
        )
        assertTrue(
            "single cadence grace sample missing",
            oracle.third.await(1, TimeUnit.SECONDS),
        )
        assertFalse(
            "worker must retire after the one grace sample",
            oracle.fourth.await(100, TimeUnit.MILLISECONDS),
        )

        // The first worker has now retired. A new pointer move starts another
        // worker; it must still honor the previous worker's global sample
        // timestamp instead of sampling immediately.
        controller.onPointerMove(
            10,
            0,
            PointerBoundaryAuthority.COMPOSITOR,
        )
        assertTrue(
            "restarted worker sample missing",
            oracle.fourth.await(1, TimeUnit.SECONDS),
        )

        assertEquals(
            listOf(
                0L,
                90_000_000L,
                180_000_000L,
                270_000_000L,
            ),
            oracle.sampleTimes(),
        )
        controller.close()
    }

    @Test
    fun oneMissingIntentCadenceGetsExactlyOneGraceSample() {
        val output = ByteArrayOutputStream()
        val writer = WriterLock(FrameWriter(output))
        val clock = AtomicLong(0L)
        val oracle = GraceSampleOracle(clock)
        val controller = BoundaryWatchController(
            writer = writer,
            log = Logger(writer),
            oracleFactory = { oracle },
            trackerFactory = {
                BoundaryPlateauTracker(
                    requiredSamples = 99,
                    minimumDurationNanos = Long.MAX_VALUE,
                )
            },
            sampleIntervalMillis = 90L,
            nowNanos = { clock.get() },
            sleepMillis = { millis ->
                clock.addAndGet(millis * 1_000_000L)
            },
        )

        val started = controller.start(
            token = 93L,
            displayId = 2,
            layerStack = 9,
            edge = BoundaryWatchController.EDGE_RIGHT,
            authority = PointerBoundaryAuthority.COMPOSITOR,
        )
        assertNull(started.errorCode)

        controller.onPointerMove(
            10,
            0,
            PointerBoundaryAuthority.COMPOSITOR,
        )

        assertTrue(
            "fresh + one grace sample were not both observed",
            oracle.third.await(1, TimeUnit.SECONDS),
        )
        assertFalse(
            "worker must retire after one cadence gap without fresh intent",
            oracle.fourth.await(100, TimeUnit.MILLISECONDS),
        )
        assertEquals(
            listOf(
                0L,
                90_000_000L,
                180_000_000L,
            ),
            oracle.sampleTimes(),
        )
        controller.close()
    }

    @Test
    fun backendFailoverInvalidatesActiveCompositorWatchImmediately() {
        val output = ByteArrayOutputStream()
        val writer = WriterLock(FrameWriter(output))
        val controller = BoundaryWatchController(
            writer = writer,
            log = Logger(writer),
            oracleFactory = { FixedOracle() },
        )

        val started = controller.start(
            token = 91L,
            displayId = 2,
            layerStack = 9,
            edge = BoundaryWatchController.EDGE_RIGHT,
            authority = PointerBoundaryAuthority.COMPOSITOR,
        )
        assertNull(started.errorCode)

        controller.onPointerAuthorityObserved(PointerBoundaryAuthority.DELIVERED_COORDINATES)

        val frame = FrameReader(ByteArrayInputStream(output.toByteArray())).readFrame()
        requireNotNull(frame)
        assertEquals(Protocol.TYPE_BOUNDARY_WATCH_ERROR, frame.type)
        val payload = ByteBuffer.wrap(frame.payload).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(91L, payload.long)
        assertEquals(
            BoundaryWatchController.ERROR_BACKEND_CHANGED,
            payload.get().toInt() and 0xFF,
        )
        controller.close()
    }

    @Test
    fun unrelatedDisplayChangeDoesNotPoisonSelectedDisplayGeneration() {
        val output = ByteArrayOutputStream()
        val writer = WriterLock(FrameWriter(output))
        val controller = BoundaryWatchController(
            writer = writer,
            log = Logger(writer),
            oracleFactory = { FixedOracle() },
        )

        controller.invalidateForDisplayChange(3)
        val started = controller.start(
            token = 88L,
            displayId = 2,
            layerStack = 9,
            edge = BoundaryWatchController.EDGE_RIGHT,
            authority = PointerBoundaryAuthority.COMPOSITOR,
        )

        assertNull(started.errorCode)
        controller.close()
    }

    private class CadenceOracle(
        private val clock: AtomicLong,
    ) : BoundarySpriteOracle {
        val second = CountDownLatch(1)
        val third = CountDownLatch(1)
        val fourth = CountDownLatch(1)
        private val lock = Any()
        private val samples = mutableListOf<Long>()

        override fun sample(
            layerStack: Int
        ): SurfaceFlingerSpritePosition {
            val count = synchronized(lock) {
                samples += clock.get()
                samples.size
            }
            if (count == 2) second.countDown()
            if (count == 3) third.countDown()
            if (count == 4) fourth.countDown()
            return SurfaceFlingerSpritePosition(
                name = "Sprite#0",
                layerStack = layerStack,
                x = 100.0,
                y = 50.0,
            )
        }

        fun sampleTimes(): List<Long> =
            synchronized(lock) { samples.toList() }
    }

    private class GraceSampleOracle(
        private val clock: AtomicLong,
    ) : BoundarySpriteOracle {
        val third = CountDownLatch(1)
        val fourth = CountDownLatch(1)
        private val lock = Any()
        private val samples = mutableListOf<Long>()

        override fun sample(
            layerStack: Int
        ): SurfaceFlingerSpritePosition {
            val count = synchronized(lock) {
                samples += clock.get()
                samples.size
            }
            if (count == 3) third.countDown()
            if (count == 4) fourth.countDown()
            return SurfaceFlingerSpritePosition(
                name = "Sprite#0",
                layerStack = layerStack,
                x = 100.0,
                y = 50.0,
            )
        }

        fun sampleTimes(): List<Long> =
            synchronized(lock) { samples.toList() }
    }

    private class ReversalRaceOracle : BoundarySpriteOracle {
        val oldSampleEntered = CountDownLatch(1)
        val releaseOldSample = CountDownLatch(1)
        val freshSampleEntered = CountDownLatch(1)
        val releaseFreshSample = CountDownLatch(1)
        private var samples = 0

        @Synchronized
        override fun sample(layerStack: Int): SurfaceFlingerSpritePosition {
            samples++
            when (samples) {
                2 -> {
                    oldSampleEntered.countDown()
                    check(releaseOldSample.await(1, TimeUnit.SECONDS)) {
                        "old sample was not released"
                    }
                }
                3 -> {
                    freshSampleEntered.countDown()
                    check(releaseFreshSample.await(1, TimeUnit.SECONDS)) {
                        "fresh sample was not released"
                    }
                }
            }
            return SurfaceFlingerSpritePosition(
                name = "Sprite#0",
                layerStack = layerStack,
                x = 100.0,
                y = 50.0,
            )
        }
    }

    private class FixedOracle : BoundarySpriteOracle {
        override fun sample(layerStack: Int): SurfaceFlingerSpritePosition =
            SurfaceFlingerSpritePosition(
                name = "Sprite#0",
                layerStack = layerStack,
                x = 100.0,
                y = 50.0,
            )
    }

    private class BlockingOracle : BoundarySpriteOracle {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)

        override fun sample(layerStack: Int): SurfaceFlingerSpritePosition {
            entered.countDown()
            check(release.await(1, TimeUnit.SECONDS)) { "preflight was not released" }
            return SurfaceFlingerSpritePosition(
                name = "Sprite#0",
                layerStack = layerStack,
                x = 100.0,
                y = 50.0,
            )
        }
    }
}
