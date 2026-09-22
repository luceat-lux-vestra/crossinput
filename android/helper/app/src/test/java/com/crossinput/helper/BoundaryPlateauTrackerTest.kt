package com.crossinput.helper

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BoundaryPlateauTrackerTest {
    @Test
    fun sustainedPlateauRequiresSamplesAndDuration() {
        val tracker = BoundaryPlateauTracker(requiredSamples = 3, minimumDurationNanos = 40)
        tracker.reset(100.0)

        assertFalse(tracker.observe(100.0, 0))
        assertFalse(tracker.observe(100.0, 20))
        assertTrue(tracker.observe(100.0, 40))
    }

    @Test
    fun forwardProgressResetsPlateauCandidate() {
        val tracker = BoundaryPlateauTracker(requiredSamples = 3, minimumDurationNanos = 40)
        tracker.reset(100.0)

        assertFalse(tracker.observe(100.0, 0))
        assertFalse(tracker.observe(110.0, 20))
        assertFalse(tracker.observe(110.0, 40))
        assertFalse(tracker.observe(110.0, 60))
        assertTrue(tracker.observe(110.0, 80))
    }

    @Test
    fun backwardObservationResetsInsteadOfTriggering() {
        val tracker = BoundaryPlateauTracker(requiredSamples = 2, minimumDurationNanos = 1)
        tracker.reset(100.0)

        assertFalse(tracker.observe(90.0, 10))
        assertFalse(tracker.observe(90.0, 20))
        assertTrue(tracker.observe(90.0, 21))
    }
}
