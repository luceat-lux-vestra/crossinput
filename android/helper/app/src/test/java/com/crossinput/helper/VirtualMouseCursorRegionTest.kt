package com.crossinput.helper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VirtualMouseCursorRegionTest {
    @Test
    fun classifiesInteriorAndEdgesWithoutExposingCoordinates() {
        assertEquals("interior", VirtualMouseCursorRegion.classify(960f, 540f, 1920, 1080))
        assertEquals("left", VirtualMouseCursorRegion.classify(0f, 540f, 1920, 1080))
        assertEquals("right", VirtualMouseCursorRegion.classify(1919f, 540f, 1920, 1080))
        assertEquals("top", VirtualMouseCursorRegion.classify(960f, 0f, 1920, 1080))
        assertEquals("bottom", VirtualMouseCursorRegion.classify(960f, 1079f, 1920, 1080))
        assertEquals("right+bottom", VirtualMouseCursorRegion.classify(1919f, 1079f, 1920, 1080))
    }

    @Test
    fun rejectsInvalidOrOutOfDisplaySamples() {
        assertNull(VirtualMouseCursorRegion.classify(Float.NaN, 0f, 1920, 1080))
        assertNull(VirtualMouseCursorRegion.classify(-1f, 0f, 1920, 1080))
        assertNull(VirtualMouseCursorRegion.classify(1920f, 0f, 1920, 1080))
        assertNull(VirtualMouseCursorRegion.classify(0f, 1080f, 1920, 1080))
        assertNull(VirtualMouseCursorRegion.classify(0f, 0f, 0, 1080))
    }

    @Test
    fun thresholdIsInclusiveAndRejectsNegativeConfiguration() {
        assertEquals("left", VirtualMouseCursorRegion.classify(16f, 500f, 1920, 1080))
        assertEquals("interior", VirtualMouseCursorRegion.classify(17f, 500f, 1920, 1080))
        assertNull(VirtualMouseCursorRegion.classify(10f, 10f, 1920, 1080, -1))
    }
}
