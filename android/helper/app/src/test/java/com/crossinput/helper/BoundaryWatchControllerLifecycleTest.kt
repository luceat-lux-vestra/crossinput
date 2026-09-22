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
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BoundaryWatchControllerLifecycleTest {
    @Test
    fun displayChangeDuringPreflightRejectsStaleReady() {
        val output = ByteArrayOutputStream()
        val writer = WriterLock(FrameWriter(output))
        val oracle = BlockingOracle()
        val controller = BoundaryWatchController(writer, Logger(writer)) { oracle }
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
        val controller = BoundaryWatchController(writer, Logger(writer)) {
            FixedOracle()
        }

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
    fun backendFailoverInvalidatesActiveCompositorWatchImmediately() {
        val output = ByteArrayOutputStream()
        val writer = WriterLock(FrameWriter(output))
        val controller = BoundaryWatchController(writer, Logger(writer)) {
            FixedOracle()
        }

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
        val controller = BoundaryWatchController(writer, Logger(writer)) {
            FixedOracle()
        }

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
