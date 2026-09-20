package com.crossinput.helper

import org.junit.Assert.assertEquals
import org.junit.Test

class CursorBoundaryClassifierTest {
    @Test
    fun interiorHasNoBoundary() {
        assertEquals(
            emptySet<CursorBoundary>(),
            CursorBoundaryClassifier.classify(960f, 540f, 1920, 1080),
        )
    }

    @Test
    fun eachEdgeIsClassifiedWithoutRawCoordinatesLeavingTheProbe() {
        assertEquals(
            setOf(CursorBoundary.LEFT),
            CursorBoundaryClassifier.classify(0f, 540f, 1920, 1080),
        )
        assertEquals(
            setOf(CursorBoundary.RIGHT),
            CursorBoundaryClassifier.classify(1919f, 540f, 1920, 1080),
        )
        assertEquals(
            setOf(CursorBoundary.TOP),
            CursorBoundaryClassifier.classify(960f, 0f, 1920, 1080),
        )
        assertEquals(
            setOf(CursorBoundary.BOTTOM),
            CursorBoundaryClassifier.classify(960f, 1079f, 1920, 1080),
        )
    }

    @Test
    fun cornerReportsBothBoundaries() {
        assertEquals(
            setOf(CursorBoundary.RIGHT, CursorBoundary.BOTTOM),
            CursorBoundaryClassifier.classify(1919f, 1079f, 1920, 1080),
        )
    }

    @Test
    fun thresholdDoesNotMisclassifyInterior() {
        assertEquals(
            emptySet<CursorBoundary>(),
            CursorBoundaryClassifier.classify(17f, 17f, 1920, 1080, threshold = 16f),
        )
    }
}
