package dev.yab.browser.ui

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.math.abs

internal enum class FieldPageKind { PRIVATE, CHATS, SPACE }
internal data class FieldPage(val key: String, val name: String, val kind: FieldPageKind, val space: String? = null)

/** Animation time comes only from the caller's frame clock. An idle interval cannot become
 * a first-frame jump, and a controlled clock is never compared with System.nanoTime. */
internal class BrowserFieldPageClock {
    private var previous: Long? = null
    private var time = 1L
    fun event(running: Boolean): Long { if (!running) previous = null; return time }
    fun frame(nanos: Long): Long {
        previous?.let { time += (nanos - it).coerceAtLeast(0) }
        previous = nanos
        return time
    }
}

/** Page choice is presentation only. It cannot select a native tab, reveal Private or navigate. */
internal class BrowserFieldPageSelection(pages: List<FieldPage>, ordinary: String?, privately: Boolean) {
    var pages: List<FieldPage> = pages; private set
    var lastOrdinary: String? = ordinary; private set
    var target: String = if (privately) PRIVATE else ordinaryKey(ordinary); private set
    fun configure(next: List<FieldPage>, ordinary: String?) {
        pages = next
        if (next.any { it.space == ordinary && it.kind == FieldPageKind.SPACE }) lastOrdinary = ordinary
        if (next.none { it.key == target }) target = ordinaryKey(lastOrdinary)
    }
    fun eyes(privately: Boolean): String {
        target = if (privately && pages.any { it.key == PRIVATE }) PRIVATE else ordinaryKey(lastOrdinary)
        return target
    }
    fun picked(key: String): FieldPage? = pages.singleOrNull { it.key == key }?.also {
        target = it.key
        if (it.kind == FieldPageKind.SPACE) lastOrdinary = it.space
    }
    private fun ordinaryKey(id: String?) = pages.firstOrNull { it.kind == FieldPageKind.SPACE && it.space == id }?.key
        ?: pages.firstOrNull { it.kind == FieldPageKind.SPACE }?.key ?: pages.firstOrNull()?.key.orEmpty()
    companion object {
        const val PRIVATE = "yab.newtab.private"
        const val CHATS = "yab.newtab.chats"
        fun space(id: String) = "space:$id"
    }
}

/** Phone FieldModel.setPrivate uses eyes200ms; interruption starts at the current drawn tint. */
internal class BrowserFieldPrivacyInk(privately: Boolean) {
    private var from = if (privately) 1.0 else 0.0
    var value = from; private set
    private var target = from
    private var start = 0L
    private var clock = 0L
    private var reduced = false
    var running = false; private set
    fun target(privately: Boolean, now: Long, reduced: Boolean, animations: Boolean) {
        advance(now)
        val wanted = if (privately) 1.0 else 0.0
        if (wanted == target && this.reduced == reduced && animations) return
        from = value; target = wanted; start = clock; this.reduced = reduced
        running = animations && abs(from - target) > .000001
        if (!running) value = target
    }
    fun advance(now: Long): Double {
        clock = maxOf(clock, now)
        if (!running) return value
        val q = ((clock - start) / 200_000_000.0).coerceIn(0.0, 1.0)
        val t = if (reduced) fieldPrivacyCurve(q, .42, 0.0, .58, 1.0) else fieldPrivacyCurve(q, .4, 0.0, .6, 1.0)
        value = from + (target - from) * t
        if (q == 1.0) { value = target; running = false }
        return value
    }
}

internal enum class FieldPrivatePhase { LOCKED, TRYING, OPENING, REVEALING, REVEALED, REVOKED }
internal class FieldPrivateAttempt internal constructor(internal val generation: Long)
internal data class FieldPrivateFrame(val phase: FieldPrivatePhase, val shackle: Double = 0.0,
    val words: Double = 1.0, val glide: Double = 0.0, val list: Double = 0.0,
    val failed: Boolean = false, val running: Boolean = false)

/** Source PrivateNewTab lifetime. The caller must independently guard owner/lifecycle and
 * actual native authorization before accepting a result or drawing any private row. */
internal class BrowserFieldPrivatePresentation(initiallyRevealed: Boolean) {
    private val mutable = MutableStateFlow(FieldPrivateFrame(if (initiallyRevealed) FieldPrivatePhase.REVEALED else FieldPrivatePhase.LOCKED,
        shackle = if (initiallyRevealed) 1.0 else 0.0, words = if (initiallyRevealed) 0.0 else 1.0,
        glide = if (initiallyRevealed) 1.0 else 0.0, list = if (initiallyRevealed) 1.0 else 0.0))
    val frame = mutable.asStateFlow()
    private var generation = 0L
    private var attempt: FieldPrivateAttempt? = null
    private var clock = 0L
    private var lastFrame = 0L
    private var wordsStart = 0L
    private var wordsFrom = frame.value.words
    private var wordsTarget = wordsFrom
    private var glide = frame.value.glide * 1000
    private var glideVelocity = 0.0
    private var shackle = frame.value.shackle * 1000
    private var shackleVelocity = 0.0
    private var openedAt = 0L
    private var listStart = 0L
    private var list = frame.value.list * 1000
    private var listVelocity = 0.0
    private var hasTabs = false

    fun request(now: Long, animations: Boolean): FieldPrivateAttempt? {
        advance(now)
        if (frame.value.phase != FieldPrivatePhase.LOCKED) return null
        generation++
        val token = FieldPrivateAttempt(generation); attempt = token
        wordsFrom = frame.value.words; wordsTarget = 0.0; wordsStart = clock
        mutable.value = frame.value.copy(phase = FieldPrivatePhase.TRYING, failed = false, running = animations)
        if (!animations) { glide = 1000.0; mutable.value = frame.value.copy(words = 0.0, glide = 1.0) }
        return token
    }
    fun received(token: FieldPrivateAttempt, allowed: Boolean, now: Long, tabs: Boolean, animations: Boolean): Boolean {
        if (attempt !== token || token.generation != generation || frame.value.phase != FieldPrivatePhase.TRYING) return false
        advance(now); attempt = null; hasTabs = tabs
        if (!allowed) {
            wordsFrom = frame.value.words; wordsTarget = 1.0; wordsStart = clock
            mutable.value = frame.value.copy(phase = FieldPrivatePhase.LOCKED, failed = true, running = animations)
            if (!animations) { glide = 0.0; mutable.value = frame.value.copy(words = 1.0, glide = 0.0) }
            return true
        }
        openedAt = clock
        mutable.value = frame.value.copy(phase = FieldPrivatePhase.OPENING, running = animations)
        if (!animations) { shackle = 1000.0; list = 1000.0; mutable.value = FieldPrivateFrame(FieldPrivatePhase.REVEALED, 1.0, 0.0, 1.0, 1.0) }
        return true
    }
    /** An already-authorized external unlock follows the same shackle/hold transition. */
    fun authorized(now: Long, tabs: Boolean, animations: Boolean) {
        when (frame.value.phase) {
            FieldPrivatePhase.LOCKED -> request(now, animations)?.let { received(it, true, now, tabs, animations) }
            FieldPrivatePhase.TRYING -> attempt?.let { received(it, true, now, tabs, animations) }
            else -> Unit
        }
    }
    fun lock() {
        generation++; attempt = null
        wordsFrom = 1.0; wordsTarget = 1.0; glide = 0.0; glideVelocity = 0.0
        shackle = 0.0; shackleVelocity = 0.0; list = 0.0; listVelocity = 0.0
        mutable.value = FieldPrivateFrame(FieldPrivatePhase.LOCKED)
    }
    fun revoke() { lock(); mutable.value = FieldPrivateFrame(FieldPrivatePhase.REVOKED, words = 0.0) }
    fun advance(now: Long): FieldPrivateFrame {
        clock = maxOf(clock, now)
        val dt = if (lastFrame == 0L) 0.0 else ((clock - lastFrame) / 1e9).coerceAtLeast(0.0)
        lastFrame = clock
        var f = frame.value
        if (!f.running || f.phase == FieldPrivatePhase.REVOKED || f.phase == FieldPrivatePhase.REVEALED) return f
        val wordQ = ((clock - wordsStart) / 150_000_000.0).coerceIn(0.0, 1.0)
        val words = wordsFrom + (wordsTarget - wordsFrom) * fieldPrivacyCurve(wordQ, .2, .8, .2, 1.0)
        val going = f.phase != FieldPrivatePhase.LOCKED
        val g = browserStepSpring(glide, if (going) 1000.0 else 0.0, glideVelocity, .34, 1.0, dt)
        glide = g.value; glideVelocity = g.velocity
        var shackleSettled = true
        if (f.phase == FieldPrivatePhase.OPENING || f.phase == FieldPrivatePhase.REVEALING) {
            val step = browserStepSpring(shackle, 1000.0, shackleVelocity, .24, .64, dt)
            shackle = step.value; shackleVelocity = step.velocity; shackleSettled = step.settled
        }
        // .24 response ×1.25 (underdamped Motion.duration) + .1 source openHold.
        if (f.phase == FieldPrivatePhase.OPENING && clock - openedAt >= 400_000_000L) {
            listStart = clock; f = f.copy(phase = FieldPrivatePhase.REVEALING)
        }
        var listSettled = true
        if (f.phase == FieldPrivatePhase.REVEALING) {
            if (hasTabs) {
                val step = browserStepSpring(list, 1000.0, listVelocity, .34, 1.0, dt)
                list = step.value; listVelocity = step.velocity; listSettled = step.settled
            } else {
                val q = ((clock - listStart) / 300_000_000.0).coerceIn(0.0, 1.0)
                list = 1000 * fieldPrivacyCurve(q, .2, .8, .2, 1.0); listSettled = q == 1.0
            }
            if (listSettled) f = f.copy(phase = FieldPrivatePhase.REVEALED)
        }
        val moving = when (f.phase) {
            FieldPrivatePhase.LOCKED, FieldPrivatePhase.TRYING -> !g.settled || wordQ < 1.0
            FieldPrivatePhase.OPENING -> true
            FieldPrivatePhase.REVEALING -> !listSettled || !shackleSettled
            else -> false
        }
        mutable.value = f.copy(words = words, glide = glide / 1000, shackle = shackle / 1000, list = list / 1000, running = moving)
        return frame.value
    }
}

private fun fieldPrivacyCurve(x: Double, x1: Double, y1: Double, x2: Double, y2: Double): Double {
    if (x <= 0 || x >= 1) return x.coerceIn(0.0, 1.0)
    fun at(a: Double, b: Double, t: Double): Double { val u = 1 - t; return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t }
    var low = 0.0; var high = 1.0
    repeat(40) { val t = (low + high) / 2; if (at(x1, x2, t) < x) low = t else high = t }
    return at(y1, y2, (low + high) / 2)
}
