package dev.yab.agent

import kotlin.math.abs
import kotlin.math.roundToInt
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal enum class ApprovalWindowGesture { PAGE, SCROLL, PULL }
internal data class ApprovalWindowPageFrame(val page: Double = 0.0, val selected: Int = 0,
    val scroll: Double = 0.0, val gesture: ApprovalWindowGesture? = null, val running: Boolean = false)
internal class ApprovalWindowDragToken internal constructor(internal val owner: ApprovalPresentationKey)

/** Phone's page/scroll springs belong to the displayed question, rather than a recreated view. */
internal class ApprovalWindowPages {
    private var owner: ApprovalPresentationKey? = null
    private var count = 0
    private var reduced = false
    private var width = 1.0
    private var viewport = 1.0
    private var content = 0.0
    private var pageStart = 0.0
    private var scrollStart = 0.0
    private var gesture: ApprovalWindowGesture? = null
    private var dragToken: ApprovalWindowDragToken? = null
    private val page = ApprovalSpringValue(0.0, unit = true)
    private val scroll = ApprovalSpringValue(0.0)
    private val mutable = MutableStateFlow(ApprovalWindowPageFrame())
    val frame = mutable.asStateFlow()
    private val maxScroll get() = (content - viewport).coerceAtLeast(0.0)

    fun open(key: ApprovalPresentationKey, itemCount: Int, index: Int, reduceMotion: Boolean = false) {
        require(itemCount > 0 && index in 0 until itemCount)
        owner = key; count = itemCount; content = 0.0; gesture = null; dragToken = null; reduced = reduceMotion
        page.set(index.toDouble()); scroll.set(0.0); publish()
    }
    fun reconcile(key: ApprovalPresentationKey?) {
        if (owner == key) return
        owner = null; count = 0; content = 0.0; gesture = null; dragToken = null
        page.set(0.0); scroll.set(0.0); publish()
    }
    fun measure(key: ApprovalPresentationKey, selected: Int, viewportWidth: Double, viewportHeight: Double, contentHeight: Double) {
        if (owner != key || selected != page.target.roundToInt() ||
            !listOf(viewportWidth, viewportHeight, contentHeight).all(Double::isFinite)) return
        width = viewportWidth.coerceAtLeast(1.0); viewport = viewportHeight.coerceAtLeast(1.0); content = contentHeight.coerceAtLeast(0.0)
    }
    fun begin(key: ApprovalPresentationKey): ApprovalWindowDragToken? {
        if (owner != key) return null
        val token = ApprovalWindowDragToken(key); dragToken = token
        gesture = null; pageStart = page.value; scrollStart = scroll.value
        // A regrab holds the live positions, including an unfinished return.
        page.set(page.value); scroll.set(scroll.value); publish(); return token
    }
    fun gestureCurrent(token: ApprovalWindowDragToken): Boolean = dragToken === token && owner == token.owner
    fun drag(key: ApprovalPresentationKey, dx: Double, dy: Double, expected: ApprovalWindowDragToken? = null): ApprovalWindowGesture? {
        if (owner != key || expected != null && !gestureCurrent(expected) || !dx.isFinite() || !dy.isFinite()) return null
        if (gesture == null) gesture = when {
            abs(dx) > abs(dy) && count > 1 -> ApprovalWindowGesture.PAGE
            dy > 0 && scroll.value <= .5 -> ApprovalWindowGesture.PULL
            else -> ApprovalWindowGesture.SCROLL
        }
        when (gesture) {
            ApprovalWindowGesture.PAGE -> {
                val end = (count - 1).coerceAtLeast(0).toDouble()
                val p = pageStart - dx / width
                page.set(when { p < 0 -> -ApprovalDetailGeometry.rubber(-p * width, 120.0) / width
                    p > end -> end + ApprovalDetailGeometry.rubber((p - end) * width, 120.0) / width
                    else -> p })
            }
            ApprovalWindowGesture.SCROLL -> {
                val s = scrollStart - dy
                scroll.set(when { s < 0 -> -ApprovalDetailGeometry.rubber(-s, 300.0)
                    s > maxScroll -> maxScroll + ApprovalDetailGeometry.rubber(s - maxScroll, 300.0)
                    else -> s })
            }
            else -> Unit
        }
        publish(); return gesture
    }
    /** A pull is finished by the window lifetime; page/scroll never submit an approval. */
    fun end(key: ApprovalPresentationKey, vx: Double, vy: Double, cancelled: Boolean = false, expected: ApprovalWindowDragToken? = null): Boolean {
        if (owner != key || expected != null && !gestureCurrent(expected) || !vx.isFinite() || !vy.isFinite()) return false
        dragToken = null
        val pulling = gesture == ApprovalWindowGesture.PULL
        when (gesture) {
            ApprovalWindowGesture.PAGE -> {
                val from = pageStart.roundToInt().coerceIn(0, count - 1)
                val moved = page.value - from
                val to = when {
                    cancelled -> from
                    moved > .25 || vx < -500 -> (from + 1).coerceAtMost(count - 1)
                    moved < -.25 || vx > 500 -> (from - 1).coerceAtLeast(0)
                    else -> from
                }
                if (to != from) { scroll.set(0.0); content = 0.0 }
                if (reduced) page.set(to.toDouble()) else page.animate(to.toDouble(), ApprovalTiming.page, if (cancelled) 0.0 else -vx / width)
            }
            ApprovalWindowGesture.SCROLL -> {
                val destination = (scroll.value - if (cancelled) 0.0 else vy * .32).coerceIn(0.0, maxScroll)
                if (reduced) scroll.set(destination) else scroll.animate(destination, ApprovalTiming.scroll, if (cancelled) 0.0 else -vy)
            }
            else -> Unit
        }
        gesture = null; publish(); return pulling
    }
    /** A retired handler may only return its own still-active gesture, never commit it. */
    fun cancel(token: ApprovalWindowDragToken): Boolean {
        if (!gestureCurrent(token)) return false
        end(token.owner, 0.0, 0.0, cancelled = true, expected = token)
        return true
    }
    fun goTo(key: ApprovalPresentationKey, index: Int, reduceMotion: Boolean = false) {
        if (owner != key || index !in 0 until count) return
        gesture = null; dragToken = null; scroll.set(0.0); content = 0.0
        if (reduced || reduceMotion) page.set(index.toDouble()) else page.animate(index.toDouble(), ApprovalTiming.page)
        publish()
    }
    fun advance(seconds: Double) {
        if (owner == null || !seconds.isFinite() || seconds < 0) return
        page.advance(seconds); scroll.advance(seconds); publish()
    }
    private fun publish() {
        mutable.value = ApprovalWindowPageFrame(page.value, page.target.roundToInt().coerceIn(0, (count - 1).coerceAtLeast(0)),
            scroll.value, gesture, page.moving || scroll.moving)
    }
}

/** Exact current layout frames, not guessed row locations or file identifiers used as authority. */
internal class ApprovalDetailAnchors {
    private var owner: ApprovalPresentationKey? = null
    private val mutable = MutableStateFlow<Map<String, ApprovalRect>>(emptyMap())
    val frames = mutable.asStateFlow()
    fun reconcile(key: ApprovalPresentationKey?) {
        if (owner != key) { owner = key; mutable.value = emptyMap() }
    }
    fun put(key: ApprovalPresentationKey, anchor: String, rect: ApprovalRect) {
        if (owner != key || anchor.length > 256 || !listOf(rect.x, rect.y, rect.width, rect.height).all { it.isFinite() && abs(it) <= 1_000_000 } ||
            rect.width <= 0 || rect.height <= 0 || (anchor !in mutable.value && mutable.value.size >= 128)) return
        if (mutable.value[anchor] != rect) mutable.value = mutable.value + (anchor to rect)
    }
    fun remove(key: ApprovalPresentationKey, anchor: String, rect: ApprovalRect) {
        if (owner == key && mutable.value[anchor] == rect) mutable.value = mutable.value - anchor
    }
}
