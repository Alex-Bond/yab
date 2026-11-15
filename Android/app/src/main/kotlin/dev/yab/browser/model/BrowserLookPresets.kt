package dev.yab.browser.model

/** Current Phone SpaceLookEditor.swift: five pages of nine, with at most two linked colors. */
internal object BrowserLookPresets {
    data class Preset(val main: Long, val colors: List<Long> = emptyList())
    private fun color(rgb: Long) = 0xFF000000L or rgb
    private fun flat(vararg values: Long) = values.map { Preset(color(it)) }
    private fun linked(main: Long, a: Long, b: Long) = Preset(color(main), listOf(color(a), color(b)))
    val pages = listOf(
        flat(0xF2E9E3, 0xEC8FBB, 0xA0689A, 0xE54C6E, 0xF37C5A, 0xF3D85E, 0x44FE96, 0x74BFD6, 0x666587),
        listOf(linked(0xF2E9E3, 0xF1E2E7, 0xEFF2E5), linked(0xEC8FBB, 0xE68CE7, 0xE9AA9C), linked(0xA0689A, 0x9F6A80, 0x886E9D),
            linked(0xF37C5A, 0xF23B97, 0xEDF349), linked(0xF3ED6E, 0xF6BB6D, 0xFAA68E), linked(0xB7FF79, 0xDDEB78, 0xE3BD78),
            linked(0x72F2E6, 0x69E7B9, 0x8C95E0), linked(0x938EDC, 0x8DABDA, 0x8DBCD0), linked(0x666587, 0x7D5F88, 0x628087)),
        flat(0xFEFBFA, 0xFFE9F3, 0xF1D1EC, 0xFFCBD1, 0xFFE0D3, 0xFFF9E5, 0xDEFDEB, 0xDCF3FC, 0xC5C6E5),
        flat(0x4E3A5A, 0x693558, 0x8F4042, 0xB16D40, 0xD7B35D, 0xCDCCA4, 0x7AA982, 0x226149, 0x26456B),
        flat(0xFFFFFF, 0xE5E5E5, 0xCCCCCC, 0xB2B2B2, 0x808080, 0x666666, 0x333333, 0x1A1A1A, 0x000000),
    )
    fun place(look: BrowserSpaceLook): Pair<Int, Int>? = pages.withIndex().firstNotNullOfOrNull { (page, presets) ->
        presets.indexOfFirst { it.main == look.primary && it.colors == look.colors }.takeIf { it >= 0 }?.let { page to it }
    }
}
