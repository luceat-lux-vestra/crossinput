package com.crossinput.helper

internal data class SurfaceFlingerSpritePosition(
    val name: String,
    val layerStack: Int,
    val x: Double,
    val y: Double,
)

internal object SurfaceFlingerHwLayersParser {
    private val spriteBlock = Regex(
        pattern = """(?ms)^\+ BufferStateLayer \((Sprite#\d+)\).*?(?=^\+ |\z)""",
    )
    private val geometry = Regex(
        pattern = """layerStack=\s*(-?\d+).*?pos=\(\s*(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\)""",
        option = RegexOption.DOT_MATCHES_ALL,
    )

    fun parseSpritePositions(text: String): List<SurfaceFlingerSpritePosition> =
        spriteBlock.findAll(text).mapNotNull { blockMatch ->
            val detail = geometry.find(blockMatch.value) ?: return@mapNotNull null
            SurfaceFlingerSpritePosition(
                name = blockMatch.groupValues[1],
                layerStack = detail.groupValues[1].toInt(),
                x = detail.groupValues[2].toDouble(),
                y = detail.groupValues[3].toDouble(),
            )
        }.toList()
}
