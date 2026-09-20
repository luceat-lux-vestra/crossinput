package com.crossinput.helper

import org.junit.Assert.assertEquals
import org.junit.Test

class RemoteBoundaryAlignmentTest {
    @Test
    fun horizontalEdgesUseDisplayWidthAndCorrectSign() {
        assertEquals(-30_720 to 0, RemoteBoundaryAlignment.movement(RemoteBoundary.LEFT, 1920, 1080))
        assertEquals(30_720 to 0, RemoteBoundaryAlignment.movement(RemoteBoundary.RIGHT, 1920, 1080))
    }

    @Test
    fun verticalEdgesUseDisplayHeightAndCorrectSign() {
        assertEquals(0 to -17_280, RemoteBoundaryAlignment.movement(RemoteBoundary.TOP, 1920, 1080))
        assertEquals(0 to 17_280, RemoteBoundaryAlignment.movement(RemoteBoundary.BOTTOM, 1920, 1080))
    }

    @Test
    fun smallDisplaysStillUseConservativeMinimum() {
        assertEquals(8_192 to 0, RemoteBoundaryAlignment.movement(RemoteBoundary.RIGHT, 320, 240))
    }

    @Test
    fun extremeDimensionsStayWithinUhidSplitBudget() {
        assertEquals(120_000 to 0, RemoteBoundaryAlignment.movement(RemoteBoundary.RIGHT, 20_000, 10_000))
    }
}
