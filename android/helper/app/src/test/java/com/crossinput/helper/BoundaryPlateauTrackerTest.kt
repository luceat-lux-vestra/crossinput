package com.crossinput.helper

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BoundaryPlateauTrackerTest {
    @Test
    fun noProgressAfterResetNeverConfirmsBoundary() {
        val tracker = BoundaryPlateauTracker(
            requiredSamples = 2,
            minimumDurationNanos = 0,
            minimumPlateauSeparation = 0,
        )
        tracker.reset(100.0)

        repeat(10) { index ->
            assertFalse(tracker.observe(100.0, index.toLong()))
        }
    }

    @Test
    fun sustainedPlateauRequiresSamplesAndDurationAfterForwardProgress() {
        val tracker = BoundaryPlateauTracker(
            requiredSamples = 3,
            minimumDurationNanos = 40,
            minimumPlateauSeparation = 0,
        )
        tracker.reset(100.0)

        assertFalse(tracker.observe(110.0, 0))
        assertFalse(tracker.observe(110.0, 20))
        assertTrue(tracker.observe(110.0, 40))
    }

    @Test
    fun productionGateRejectsSevenSamplesAndAcceptsEighth() {
        val tracker = BoundaryPlateauTracker()
        tracker.reset(100.0)

        val sevenSampleTimes = listOf(0L, 20_000_000L, 40_000_000L, 60_000_000L, 80_000_000L, 100_000_000L, 120_000_000L)
        sevenSampleTimes.forEachIndexed { index, now ->
            val progress = if (index == 0) 110.0 else 110.0
            assertFalse(tracker.observe(progress, now))
        }

        assertTrue(tracker.observe(110.0, 140_000_000L))
    }

    @Test
    fun finalPlateauMustDominateLongestInteriorPlateauByThreeSamples() {
        val tracker = BoundaryPlateauTracker(
            requiredSamples = 3,
            minimumDurationNanos = 0,
            minimumPlateauSeparation = 3,
        )
        tracker.reset(100.0)

        assertFalse(tracker.observe(110.0, 0))
        assertFalse(tracker.observe(110.0, 1))
        assertFalse(tracker.observe(110.0, 2))

        assertFalse(tracker.observe(120.0, 3))
        assertFalse(tracker.observe(120.0, 4))
        assertFalse(tracker.observe(120.0, 5))
        assertFalse(tracker.observe(120.0, 6))
        assertFalse(tracker.observe(120.0, 7))
        assertTrue(tracker.observe(120.0, 8))
    }

    @Test
    fun backwardObservationResetsMovementProofWindow() {
        val tracker = BoundaryPlateauTracker(
            requiredSamples = 3,
            minimumDurationNanos = 0,
            minimumPlateauSeparation = 0,
        )
        tracker.reset(100.0)

        assertFalse(tracker.observe(110.0, 0))
        assertFalse(tracker.observe(110.0, 1))
        assertFalse(tracker.observe(90.0, 2))

        assertFalse(tracker.observe(90.0, 3))
        assertFalse(tracker.observe(90.0, 4))
        assertFalse(tracker.observe(90.0, 5))

        assertFalse(tracker.observe(100.0, 6))
        assertFalse(tracker.observe(100.0, 7))
        assertTrue(tracker.observe(100.0, 8))
    }
}
