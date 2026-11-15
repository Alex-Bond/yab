package dev.yab.browser.ui

import kotlin.math.max
import kotlin.math.min

/** Current Phone FieldGeometry scalar contract. Native font and presented-frame parity are separate. */
internal data class FieldRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    val right get() = x + width
    val bottom get() = y + height
    fun mix(to: FieldRect, progress: Double) = FieldRect(x + (to.x - x) * progress, y + (to.y - y) * progress,
        width + (to.width - width) * progress, height + (to.height - height) * progress)
}

internal data class BrowserFieldGeometry(val width: Double, val height: Double, val keyboard: Double,
    val textScale: Double = 1.0, val lineHeight: Double = 20.3, val resting: Boolean = false,
    val statusTop: Double = 54.0, val newTab: Boolean = true) {
    init { require(listOf(width, height, keyboard, textScale, lineHeight, statusTop).all(Double::isFinite) &&
        width >= 80 && height >= 0 && keyboard >= 0 && textScale > 0 && lineHeight >= 0 && statusTop >= 0) }
    val keyboardTop get() = height - if (resting && newTab) 32.0 else keyboard
    val field: FieldRect get() {
        val h = max(48.0, max(48.0 * textScale, lineHeight + 16.0))
        return FieldRect(8.0, keyboardTop - 8.0 - h, max(0.0, width - 16.0 - h - 7.0), h)
    }
    val close get() = FieldRect(field.right + 7.0, field.y, field.height, field.height)
    val cardBottom get() = field.y - 10.0
    val cardWidth get() = width - 16.0
    val newTabBottom get() = keyboardTop - 8.0
    val spacesBottom get() = if (resting && newTab) height else keyboardTop
    val spacesFieldExtra get() = max(0.0, spacesBottom - field.y + 10.0 - 66.0)
    val newTabWidth get() = width - 16.0
    val newTabMaxHeight get() = max(0.0, min(502.0, newTabBottom - statusTop - 2.0))
    val plate get() = FieldRect(81.0, height - 28.0 - 48.0, max(0.0, width - 162.0), 48.0)
    val stack get() = FieldRect(width - 26.0 - 48.0, height - 28.0 - 48.0, 48.0, 48.0)
}

internal data class BrowserFieldPose(val geometry: BrowserFieldGeometry, val origin: FieldRect,
    val closeOrigin: FieldRect, val progress: Double, val cards: Double, val contents: Double,
    val retainedPill: FieldRect? = null) {
    val pill get() = retainedPill ?: origin.mix(geometry.field, progress)
    val radius get() = pill.height / 2
    val close get() = closeOrigin.mix(geometry.close, progress)
    val closeGlyph get() = contents * ((progress - 0.3) / 0.5).coerceIn(0.0, 1.0)
    val eyes get() = ((progress - 0.55) / 0.45).coerceIn(0.0, 1.0)
    val rowsDrop get() = (1 - cards) * 10.0
}

/** A reversal starts at the currently drawn rectangle, including an interrupted + opening. */
internal data class FieldMorphSegment(val from: FieldRect, val start: Double, val end: Double) {
    fun at(target: FieldRect, progress: Double): FieldRect {
        val fraction = if (kotlin.math.abs(end - start) < 1e-8) 1.0 else ((progress - start) / (end - start)).coerceIn(0.0, 1.0)
        return from.mix(target, fraction)
    }
}
