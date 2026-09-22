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

        repeat(7) { index ->
            assertFalse(tracker.observe(110.0, index * 20_000_000L))
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
    fun durationWindowRestartsAfterBackwardObservation() {
        val tracker = BoundaryPlateauTracker(
            requiredSamples = 3,
            minimumDurationNanos = 10,
            minimumPlateauSeparation = 0,
        )
        tracker.reset(100.0)

        assertFalse(tracker.observe(110.0, 0))
        assertFalse(tracker.observe(110.0, 5))
        assertFalse(tracker.observe(90.0, 6))

        assertFalse(tracker.observe(110.0, 100))
        assertFalse(tracker.observe(110.0, 105))
        assertFalse(tracker.observe(110.0, 106))
        assertTrue(tracker.observe(110.0, 110))
    }

    @Test
    fun backwardObservationKeepsHighWatermarkAndRecordsInteriorPlateau() {
        val tracker = BoundaryPlateauTracker(
            requiredSamples = 3,
            minimumDurationNanos = 0,
            minimumPlateauSeparation = 3,
        )
        tracker.reset(100.0)

        assertFalse(tracker.observe(110.0, 0))
        assertFalse(tracker.observe(110.0, 1))
        assertFalse(tracker.observe(110.0, 2))

        assertFalse(tracker.observe(90.0, 3))
        assertFalse(tracker.observe(90.0, 4))
        assertFalse(tracker.observe(100.0, 5))

        assertFalse(tracker.observe(110.0, 6))
        assertFalse(tracker.observe(110.0, 7))
        assertFalse(tracker.observe(110.0, 8))
        assertFalse(tracker.observe(110.0, 9))
        assertFalse(tracker.observe(110.0, 10))
        assertTrue(tracker.observe(110.0, 11))
    }
}
