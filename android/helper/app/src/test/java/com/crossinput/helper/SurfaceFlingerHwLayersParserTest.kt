package com.crossinput.helper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SurfaceFlingerHwLayersParserTest {
    @Test
    fun parsesSpriteGeometryIncludingNegativeCoordinates() {
        val dump = """
            + BufferStateLayer (Sprite#0) id=34379 uid=1000
              Region VisibleRegion (this=0 count=0)
                  layerStack=   2, z=   361000, pos=( -3.000,502.704), size=(  32,  32)
                  parent=none
            + ContainerLayer (Root#1) id=34313 uid=1000
        """.trimIndent()

        assertEquals(
            listOf(
                SurfaceFlingerSpritePosition(
                    name = "Sprite#0",
                    layerStack = 2,
                    x = -3.0,
                    y = 502.704,
                ),
            ),
            SurfaceFlingerHwLayersParser.parseSpritePositions(dump),
        )
    }

    @Test
    fun parsesMultipleSpriteLayersWithoutChoosingA_Display() {
        val dump = """
            + BufferStateLayer (Sprite#0) id=1 uid=1000
                layerStack=0, z=1, pos=(10.5,20.25), size=(32,32)
            + BufferStateLayer (Sprite#1) id=2 uid=1000
                layerStack=2, z=1, pos=(1508.24,487.303), size=(32,32)
        """.trimIndent()

        val positions = SurfaceFlingerHwLayersParser.parseSpritePositions(dump)

        assertEquals(2, positions.size)
        assertTrue(positions.any { it.name == "Sprite#0" && it.layerStack == 0 })
        assertTrue(positions.any { it.name == "Sprite#1" && it.layerStack == 2 })
    }

    @Test
    fun ignoresSpriteWithoutGeometryInsteadOfInventingPosition() {
        val dump = """
            + BufferStateLayer (Sprite#0) id=1 uid=1000
              Region VisibleRegion (this=0 count=0)
            + ContainerLayer (Root#1) id=2 uid=1000
        """.trimIndent()

        assertTrue(SurfaceFlingerHwLayersParser.parseSpritePositions(dump).isEmpty())
    }
}
