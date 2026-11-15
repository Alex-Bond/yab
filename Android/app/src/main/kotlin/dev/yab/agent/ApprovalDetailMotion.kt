package dev.yab.agent

internal object ApprovalFade {
    fun easeInOut(x: Double): Double {
        var low = 0.0; var high = 1.0
        repeat(24) {
            val t = (low + high) / 2
            val curveX = 3 * (1 - t) * (1 - t) * t * .42 + 3 * (1 - t) * t * t * .58 + t * t * t
            if (curveX < x) low = t else high = t
        }
        val t = (low + high) / 2
        return 3 * (1 - t) * t * t + t * t * t
    }
}

/** The row/window and thumbnail/picture coordinates from current AssistantApprovalLayer.swift. */
internal object ApprovalDetailGeometry {
    private fun clamp(value: Double) = value.coerceIn(0.0, 1.0)
    fun window(from: ApprovalRect, open: ApprovalRect, progress: Double, pull: Double = 0.0): ApprovalRect =
        from.mix(open, progress).let { it.copy(y = it.y + ApprovalMetrics.band(pull)) }
    fun windowScale(pull: Double) = 1 - (pull.coerceAtLeast(0.0) / 2400).coerceAtMost(.12)
    fun windowWords(progress: Double) = clamp((progress - .08) / .3)
    fun windowGhost(progress: Double) = (1 - progress / .33).coerceAtLeast(0.0)
    fun windowGround(progress: Double) = clamp(progress / .3)
    fun fitPicture(screenWidth: Double, screenHeight: Double, safeTop: Double, image: Boolean,
        originalWidth: Int? = null, originalHeight: Int? = null): ApprovalRect {
        require(listOf(screenWidth, screenHeight, safeTop).all(Double::isFinite))
        val aspect = if (originalWidth != null && originalHeight != null && originalWidth > 0 && originalHeight > 0)
            originalWidth.toDouble() / originalHeight else if (image) 1.0 else 8.5 / 11
        val top = safeTop + 56; val available = (screenHeight - top - 40).coerceAtLeast(1.0)
        val width = minOf((screenWidth - 32).coerceAtLeast(1.0), available * aspect)
        val height = width / aspect
        return ApprovalRect((screenWidth - width) / 2, top + (available - height) / 2, width, height)
    }
    fun picture(from: ApprovalRect, fit: ApprovalRect, progress: Double, drag: Double = 0.0): ApprovalRect {
        val rect = from.mix(fit, progress)
        val scale = 1 - (drag.coerceAtLeast(0.0) / 1200).coerceAtMost(.3)
        return ApprovalRect(rect.x + rect.width * (1 - scale) / 2, rect.y + drag, rect.width * scale, rect.height * scale)
    }
    fun pictureBlack(progress: Double, drag: Double) = clamp(progress) * (1 - clamp(drag.coerceAtLeast(0.0) / 400))
    fun pictureHeader(progress: Double, drag: Double) = ((progress - .6) / .4).coerceAtLeast(0.0) * if (drag > 4) 0 else 1
    fun rubber(distance: Double, span: Double): Double {
        val sign = if (distance < 0) -1 else 1
        return sign * (1 - 1 / (kotlin.math.abs(distance) * .55 / span + 1)) * span
    }
}

internal enum class ApprovalDetailKind { MAIL, PICTURE }
internal data class ApprovalDetailTarget(val owner: ApprovalPresentationKey, val kind: ApprovalDetailKind,
    val anchor: String, val index: Int, val file: ApprovalFile? = null, val preview: ApprovalPreview? = null,
    val from: ApprovalRect? = null, val paper: Boolean = false)
internal data class ApprovalDetailFrame(val target: ApprovalDetailTarget? = null, val opening: Boolean = false,
    val progress: Double = 0.0, val opacity: Double = 1.0, val drag: Double = 0.0, val running: Boolean = false)
internal class ApprovalDetailDragToken internal constructor(internal val target: ApprovalDetailTarget)

/** Shared detail lifetime survives an Activity, but never a changed question, epoch or account. */
internal class ApprovalDetailPresentation {
    private var target: ApprovalDetailTarget? = null
    private var opening = false
    private var reduced = false
    private var elapsed = 0.0
    private var fadeFrom = 0.0
    private var fade = 1.0
    private var dragBase: Double? = null
    private var dragToken: ApprovalDetailDragToken? = null
    private val progress = ApprovalSpringValue(0.0, unit = true)
    private val drag = ApprovalSpringValue(0.0)
    private val mutable = kotlinx.coroutines.flow.MutableStateFlow(ApprovalDetailFrame())
    val frame: kotlinx.coroutines.flow.StateFlow<ApprovalDetailFrame> = mutable

    fun reconcile(owner: ApprovalPresentationKey?, reduceMotion: Boolean) {
        if (target?.owner != owner) { clear(); return }
        if (reduced != reduceMotion) {
            // Settle only this model's held original gesture before its token is retired.
            dragToken?.let(::cancel)
            reduced = reduceMotion; dragToken = null; dragBase = null
            if (reduced) { progress.set(if (opening) 1.0 else 0.0); drag.set(0.0); fade = if (opening) 1.0 else 0.0 }
            publish()
        }
    }
    fun open(value: ApprovalDetailTarget, owner: ApprovalPresentationKey, reduceMotion: Boolean): Boolean {
        if (value.owner != owner || (target != null && opening)) return false
        val same = target == value
        val hadTarget = target != null
        target = value; opening = true; reduced = reduceMotion; elapsed = 0.0; fadeFrom = if (same) fade else 0.0; dragBase = null; dragToken = null
        drag.set(0.0)
        if (reduced) { progress.set(1.0); fade = fadeFrom }
        else { if (!hadTarget) progress.set(0.0); fade = 1.0; progress.animate(1.0, if (value.kind == ApprovalDetailKind.PICTURE) ApprovalTiming.picture else ApprovalTiming.window) }
        publish(); return true
    }
    fun close(owner: ApprovalPresentationKey, velocity: Double? = null): Boolean {
        val content = target ?: return false
        if (content.owner != owner || !opening) return false
        opening = false; elapsed = 0.0; fadeFrom = fade; dragBase = null; dragToken = null
        if (reduced) drag.set(0.0) else {
            val timing = if (content.kind == ApprovalDetailKind.PICTURE) ApprovalTiming.pictureBack else ApprovalTiming.window
            drag.animate(0.0, timing, velocity); progress.animate(0.0, timing)
        }
        publish(); return true
    }
    fun returnTo(owner: ApprovalPresentationKey, index: Int, anchor: String, from: ApprovalRect?) {
        val shown = target ?: return
        if (shown.owner != owner || !opening) return
        target = shown.copy(index = index, anchor = anchor, from = from ?: shown.from); dragToken = null; dragBase = null; publish()
    }
    fun beginDrag(owner: ApprovalPresentationKey): ApprovalDetailDragToken? {
        val shown = target ?: return null
        if (shown.owner != owner || !opening) return null
        val token = ApprovalDetailDragToken(shown); dragToken = token
        dragBase = drag.value; drag.set(drag.value)
        return token
    }
    fun gestureCurrent(token: ApprovalDetailDragToken): Boolean = dragToken === token && target == token.target && opening
    fun drag(owner: ApprovalPresentationKey, distance: Double, expected: ApprovalDetailDragToken? = null) {
        if (target?.owner != owner || !opening || expected != null && !gestureCurrent(expected) || !distance.isFinite()) return
        drag.set(distance + (dragBase ?: drag.value.also { dragBase = it }))
        publish()
    }
    fun releaseDrag(owner: ApprovalPresentationKey, velocity: Double, cancelled: Boolean = false, expected: ApprovalDetailDragToken? = null): Boolean {
        val content = target ?: return false
        if (content.owner != owner || !opening || expected != null && !gestureCurrent(expected) || !velocity.isFinite()) return false
        dragBase = null; dragToken = null
        val commits = !cancelled && when (content.kind) {
            ApprovalDetailKind.PICTURE -> drag.value > 120 || velocity > ApprovalMetrics.pullFlick
            ApprovalDetailKind.MAIL -> drag.value > ApprovalMetrics.pullClose || drag.value > 40 && velocity > ApprovalMetrics.pullFlick
        }
        if (commits) close(owner, velocity) else {
            if (reduced) drag.set(0.0) else drag.animate(0.0, ApprovalTiming.back, if (cancelled) 0.0 else velocity)
            publish()
        }
        return commits
    }
    /** Neutral cleanup is tied to an original gesture, not to whichever UI is current now. */
    fun cancel(token: ApprovalDetailDragToken): Boolean {
        if (!gestureCurrent(token)) return false
        releaseDrag(token.target.owner, 0.0, cancelled = true, expected = token)
        return true
    }
    fun advance(seconds: Double) {
        if (target == null || !seconds.isFinite() || seconds < 0) return
        elapsed += seconds
        if (reduced) {
            val share = ApprovalFade.easeInOut((elapsed / ApprovalTiming.fade).coerceIn(0.0, 1.0))
            fade = if (opening) fadeFrom + (1 - fadeFrom) * share else fadeFrom * (1 - share)
            if (!opening && elapsed >= ApprovalTiming.fade) { clear(); return }
        } else {
            progress.advance(seconds); drag.advance(seconds)
            if (!opening && !progress.moving) { clear(); return }
        }
        publish()
    }
    private fun clear() {
        target = null; opening = false; dragBase = null; dragToken = null
        progress.set(0.0); drag.set(0.0); fade = 1.0; elapsed = 0.0
        publish()
    }
    private fun publish() {
        mutable.value = ApprovalDetailFrame(target, opening, progress.value, fade, drag.value,
            target != null && if (reduced) elapsed < ApprovalTiming.fade else progress.moving || drag.moving)
    }
}
