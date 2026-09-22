package com.crossinput.helper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class BoundaryStallAnalysisTest {
    @Test
    fun finalPlateauDominatesShortInteriorRepeats() {
        val metrics = BoundaryStallAnalysis.analyze(
            listOf(
                100.0,
                120.0,
                120.0,
                150.0,
                180.0,
                180.0,
                210.0,
                240.0,
                240.0,
                240.0,
                240.0,
                240.0,
                240.0,
            ),
        )

        assertNotNull(metrics)
        requireNotNull(metrics)
        assertEquals(6, metrics.finalPlateauSamples)
        assertEquals(2, metrics.longestInteriorPlateauSamples)
        assertEquals(240.0, metrics.maxX, 0.001)
    }

    @Test
    fun noMovementIsNotAnalyzable() {
        assertNull(
            BoundaryStallAnalysis.analyze(
                listOf(100.0, 100.0, 100.0, 100.0),
            ),
        )
    }

    @Test
    fun finalSingleSampleIsNotInventedAsLongPlateau() {
        val metrics = BoundaryStallAnalysis.analyze(
            listOf(100.0, 120.0, 140.0, 160.0),
        )

        assertNotNull(metrics)
        requireNotNull(metrics)
        assertEquals(1, metrics.finalPlateauSamples)
        assertEquals(1, metrics.longestInteriorPlateauSamples)
    }
}
