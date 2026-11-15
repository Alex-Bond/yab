package dev.yab.browser.model

import kotlin.math.pow
import kotlin.math.round
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName

@Serializable enum class ReaderTheme(val title: String) {
    @SerialName("original") ORIGINAL("Original"), @SerialName("quiet") QUIET("Quiet"),
    @SerialName("paper") PAPER("Paper"), @SerialName("bold") BOLD("Bold"),
    @SerialName("calm") CALM("Calm"), @SerialName("focus") FOCUS("Focus")
}
@Serializable enum class ReaderMode(val title: String) {
    @SerialName("auto") AUTO("Match device"), @SerialName("light") LIGHT("Light"), @SerialName("dark") DARK("Dark")
}
/** These are functional CSS families. Apple faces are not bundled Android assets. */
@Serializable enum class ReaderFont(val title: String, val css: String) {
    @SerialName("site") SITE("Original", ""),
    @SerialName("newYork") NEW_YORK("New York", "ui-serif, \"New York\", Georgia, serif"),
    @SerialName("charter") CHARTER("Charter", "Charter, Georgia, serif"),
    @SerialName("iowan") IOWAN("Iowan Old Style", "\"Iowan Old Style\", Georgia, serif"),
    @SerialName("palatino") PALATINO("Palatino", "Palatino, \"Palatino Linotype\", Georgia, serif"),
    @SerialName("athelas") ATHELAS("Athelas", "Athelas, Georgia, serif"),
    @SerialName("georgia") GEORGIA("Georgia", "Georgia, serif"),
    @SerialName("sfPro") SYSTEM("SF Pro", "system-ui, sans-serif")
}

@Serializable data class ReaderColors private constructor(val background: String, val text: String) {
    val dark: Boolean get() = luminance(background) < .179
    fun checked(): ReaderColors = Companion.invoke(background, text)
    companion object {
        private fun hex(value: String): String? = value.removePrefix("#").takeIf { Regex("[0-9a-fA-F]{6}").matches(it) }?.lowercase()?.let { "#$it" }
        operator fun invoke(background: String, text: String): ReaderColors {
            val ground = hex(background) ?: "#ffffff"
            val asked = hex(text) ?: "#171717"
            val ink = if (contrast(ground, asked) >= 4.5) asked else if (luminance(ground) < .179) "#ffffff" else "#000000"
            return ReaderColors(ground, ink)
        }
        private fun luminance(value: String): Double {
            val rgb = value.removePrefix("#").toLongOrNull(16) ?: return 0.0
            fun component(shift: Int): Double {
                val c = ((rgb shr shift) and 255) / 255.0
                return if (c <= .04045) c / 12.92 else ((c + .055) / 1.055).pow(2.4)
            }
            return component(16) * .2126 + component(8) * .7152 + component(0) * .0722
        }
        fun contrast(a: String, b: String): Double {
            val x = luminance(a); val y = luminance(b)
            return (maxOf(x, y) + .05) / (minOf(x, y) + .05)
        }
    }
}

data class ReaderLook(val size: Int = 4, val line: Double = 1.6, val letter: Int = 0, val word: Int = 0,
    val margins: Int = 0, val justify: Boolean = false, val font: ReaderFont = ReaderFont.SITE,
    val bold: Boolean = false, val colors: ReaderColors? = null) {
    val points: Int get() = sizes[size.coerceIn(sizes.indices)]
    companion object { val sizes = listOf(14, 15, 16, 17, 18, 20, 22, 24, 26, 28) }
}
data class ReaderThemeSpec(val theme: ReaderTheme, val light: ReaderColors, val dark: ReaderColors,
    val weight: Int, val look: ReaderLook) {
    companion object {
        val ordered = listOf(
            ReaderThemeSpec(ReaderTheme.ORIGINAL, ReaderColors("#ffffff", "#1d1d1f"), ReaderColors("#1c1c1e", "#e8e8ea"), 400, ReaderLook()),
            ReaderThemeSpec(ReaderTheme.QUIET, ReaderColors("#f2f1ee", "#5a5852"), ReaderColors("#111111", "#8e8b85"), 400, ReaderLook(line = 1.7, font = ReaderFont.NEW_YORK)),
            ReaderThemeSpec(ReaderTheme.PAPER, ReaderColors("#f7f3ea", "#2a2620"), ReaderColors("#252320", "#ddd6c8"), 400, ReaderLook(line = 1.7, justify = true, font = ReaderFont.CHARTER)),
            ReaderThemeSpec(ReaderTheme.BOLD, ReaderColors("#ffffff", "#000000"), ReaderColors("#000000", "#ffffff"), 700, ReaderLook(size = 5, line = 1.55, letter = 1, font = ReaderFont.SYSTEM)),
            ReaderThemeSpec(ReaderTheme.CALM, ReaderColors("#efe4cf", "#4a3b28"), ReaderColors("#3a332b", "#ebe0cd"), 400, ReaderLook(size = 5, line = 1.75, word = 4, font = ReaderFont.IOWAN)),
            ReaderThemeSpec(ReaderTheme.FOCUS, ReaderColors("#fffdf6", "#1d1b16"), ReaderColors("#17160f", "#f2edd9"), 500, ReaderLook(size = 5, line = 1.8, margins = -10, font = ReaderFont.ATHELAS)))
        fun of(theme: ReaderTheme) = ordered.first { it.theme == theme }
    }
}
@Serializable data class ReaderEdit(val size: Int? = null, val line: Double? = null, val letter: Int? = null,
    val word: Int? = null, val margins: Int? = null, val justify: Boolean? = null, val font: ReaderFont? = null,
    val bold: Boolean? = null, val colors: ReaderColors? = null) {
    fun apply(base: ReaderLook) = base.copy(size = size?.coerceIn(ReaderLook.sizes.indices) ?: base.size,
        line = line?.takeIf(Double::isFinite)?.coerceIn(1.3, 2.1) ?: base.line,
        letter = letter?.coerceIn(-3, 10) ?: base.letter, word = word?.coerceIn(0, 40) ?: base.word,
        margins = margins?.coerceIn(-30, 30) ?: base.margins, justify = justify ?: base.justify,
        font = font ?: base.font, bold = bold ?: base.bold, colors = colors?.checked() ?: base.colors)
    companion object {
        fun between(next: ReaderLook, base: ReaderLook) = ReaderEdit(
            next.size.takeIf { it != base.size }, next.line.takeIf { kotlin.math.abs(it - base.line) >= .001 },
            next.letter.takeIf { it != base.letter }, next.word.takeIf { it != base.word }, next.margins.takeIf { it != base.margins },
            next.justify.takeIf { it != base.justify }, next.font.takeIf { it != base.font }, next.bold.takeIf { it != base.bold },
            next.colors.takeIf { it != base.colors })
    }
}

@Serializable data class ReaderPreferences(val theme: ReaderTheme = ReaderTheme.ORIGINAL,
    val mode: ReaderMode = ReaderMode.AUTO, val wide: Boolean = false, val edits: Map<ReaderTheme, ReaderEdit> = emptyMap()) {
    val spec get() = ReaderThemeSpec.of(theme)
    val look get() = edits[theme]?.apply(spec.look) ?: spec.look
    fun edited(id: ReaderTheme) = edits[id]?.let { it != ReaderEdit() } == true
    fun change(change: (ReaderLook) -> ReaderLook): ReaderPreferences {
        val next = change(look)
        val bounded = ReaderEdit.between(next, spec.look).apply(spec.look)
        val edit = ReaderEdit.between(bounded, spec.look)
        return copy(edits = if (edit == ReaderEdit()) edits - theme else edits + (theme to edit))
    }
    fun step(direction: Int) = change { it.copy(size = (it.size + direction).coerceIn(ReaderLook.sizes.indices)) }
    fun reset() = copy(edits = edits - theme)
    fun dark(system: Boolean) = when (mode) { ReaderMode.AUTO -> system; ReaderMode.LIGHT -> false; ReaderMode.DARK -> true }
    fun colors(dark: Boolean) = look.colors ?: if (dark) spec.dark else spec.light
    fun normalized() = copy(edits = edits.mapNotNull { (id, edit) ->
        val base = ReaderThemeSpec.of(id).look
        ReaderEdit.between(edit.apply(base), base).takeIf { it != ReaderEdit() }?.let { id to it }
    }.toMap())
    val payload: ReaderStylePayload get() {
        val look = look
        return ReaderStylePayload(mode.name.lowercase(), colors(false), colors(true), look.font.css,
            if (look.bold) 700 else spec.weight, look.points, look.line, look.letter / 100.0, look.word / 100.0,
            round((if (wide) 48.0 else 38.0) * (1 - look.margins / 100.0) * 100) / 100,
            look.justify, look.margins)
    }
}
/** Presentation-only values, not a page/input capability. No CSS string is accepted from a site. */
data class ReaderStylePayload(val mode: String, val day: ReaderColors, val night: ReaderColors, val font: String,
    val weight: Int, val size: Int, val line: Double, val letter: Double, val word: Double, val width: Double,
    val justify: Boolean, val margins: Int)
