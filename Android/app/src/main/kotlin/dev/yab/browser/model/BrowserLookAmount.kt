package dev.yab.browser.model

import kotlin.math.*

internal enum class BrowserLookAmountKind(val title: String) { GRAIN("Grain"), DRAWINGS("Drawings") }
internal enum class BrowserLookAmountHaptic { NONE, STEP, END }
internal data class BrowserLookAmountChange(val value: Double, val haptic: BrowserLookAmountHaptic)

/** One immutable caller owner supplies current=true per operation. A refused owner never revives. */
internal class BrowserLookAmountController(val kind: BrowserLookAmountKind, initial: Double) {
    var shown = BrowserLookAmount.unit(initial); private set
    var held = false; private set
    var active = false; private set
    var revoked = false; private set
    private var last: Double? = null

    fun project(value: Double) { if (!active && !revoked) shown = BrowserLookAmount.unit(value) }
    fun accept(owned: Boolean): Boolean {
        if (!owned) revoke()
        return !revoked
    }
    fun begin(owned: Boolean, touching: Boolean): Boolean {
        if (!accept(owned) || active) return false
        active = true; held = touching; last = shown
        return true
    }
    fun change(raw: Double, owned: Boolean): BrowserLookAmountChange? {
        if (!accept(owned) || !active || !raw.isFinite()) return null
        val value = BrowserLookAmount.changedValue(kind, raw)
        val old = last ?: shown
        val haptic = if (value == old) BrowserLookAmountHaptic.NONE
            else if (value == 0.0 || value == 1.0) BrowserLookAmountHaptic.END
            else if (BrowserLookAmount.crossed(old, value)) BrowserLookAmountHaptic.STEP
            else BrowserLookAmountHaptic.NONE
        last = value; shown = value
        return BrowserLookAmountChange(value, haptic)
    }
    /** Both a genuine release and native CANCEL end the source transaction once, without rollback. */
    fun finish(owned: Boolean): Boolean {
        if (!accept(owned) || !active) return false
        active = false; held = false; last = null
        return true
    }
    fun revoke() { revoked = true; active = false; held = false; last = null }
}

/** Exact source numbers from Phone SpaceLookEditor.swift493–691, in logical points/dp. */
internal object BrowserLookAmount {
    const val HEIGHT = 48.0
    const val TRACK_INSET = 7.0
    const val PILL_WIDTH = 14.0
    const val PILL_SHADOW_PAD = 4.0
    const val PILL_NORMAL_HEIGHT = 34.0
    const val PILL_HELD_HEIGHT = 38.0
    const val BUBBLE_FADE_MILLIS = 140L
    data class Grain(val x: Double, val y: Double, val radius: Double)
    data class Track(val left: Double, val width: Double, val middle: Double, val pillX: Double, val pillHeight: Double)
    data class Bubble(val x: Double, val y: Double, val width: Double, val height: Double)
    fun unit(value: Double) = if (value.isFinite()) value.coerceIn(0.0, 1.0) else 0.0
    fun changedValue(kind: BrowserLookAmountKind, raw: Double): Double {
        val value = unit(raw)
        return if (kind == BrowserLookAmountKind.GRAIN) floor(value * 20 + .5) / 20 else value
    }
    fun percent(value: Double) = floor(unit(value) * 100 + .5).toInt()
    fun bubbleText(kind: BrowserLookAmountKind, value: Double): String =
        if (kind == BrowserLookAmountKind.GRAIN && percent(value) == 0) "No grain" else "${kind.title} ${percent(value)}%"
    fun crossed(a: Double, b: Double, step: Double = .1): Boolean {
        if (!a.isFinite() || !b.isFinite() || !step.isFinite() || step <= 0) return false
        return ceil(min(a, b) / step - 1e-9) <= floor(max(a, b) / step + 1e-9)
    }
    fun track(width: Double, height: Double, value: Double, held: Boolean): Track? {
        if (!width.isFinite() || !height.isFinite() || width < 2 * TRACK_INSET || height <= 0) return null
        return Track(TRACK_INSET, max(1.0, width - 2 * TRACK_INSET), height / 2,
            TRACK_INSET + unit(value) * (width - 2 * TRACK_INSET), if (held) PILL_HELD_HEIGHT else PILL_NORMAL_HEIGHT)
    }
    fun bubble(width: Double, value: Double, plateWidth: Double, plateHeight: Double): Bubble? {
        if (!width.isFinite() || !plateWidth.isFinite() || !plateHeight.isFinite() || width <= 0 || plateWidth <= 0 || plateHeight <= 0) return null
        val x = TRACK_INSET + unit(value) * (width - 2 * TRACK_INSET)
        return Bubble(min(max(0.0, x - plateWidth / 2), width - plateWidth), -8 - plateHeight / 2, plateWidth, plateHeight)
    }
    fun crosses(): List<Double> = (0 until 21).map { it / 20.0 }
    fun grains(): List<Grain> {
        var seed = 0x9E3779B97F4A7C15uL.toLong()
        fun next(): Double {
            seed = seed * 6364136223846793005L + 1442695040888963407L
            return (seed ushr 33).toDouble() / 2147483648.0
        }
        return buildList {
            while (size < 170) {
                val x = next()
                if (next() < .12 + x * .88) add(Grain(x, next() * 2 - 1, .8 + next() * .6))
            }
        }
    }
}
