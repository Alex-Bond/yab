package dev.yab.browser.ui

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.TweenSpec
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring as composeSpring
import androidx.compose.animation.core.tween
import kotlin.math.PI
import kotlin.math.ceil

/** Named from the current iPhone source. Matching numbers still needs presented-frame proof. */
internal object BrowserMotion {
    val easeOut = CubicBezierEasing(0.2f, 0.8f, 0.2f, 1f)
    val easeIn = CubicBezierEasing(0.4f, 0f, 0.8f, 0.4f)
    val chromeCurve = CubicBezierEasing(0.4f, 0f, 0.2f, 1f)

    fun chromeFold(reduced: Boolean): FiniteAnimationSpec<Float> =
        if (reduced) snap() else tween(300, easing = chromeCurve)

    /** SwiftUI response is the undamped period, not a Compose stiffness constant. */
    fun space(reduced: Boolean): FiniteAnimationSpec<Float> =
        if (reduced) snap() else spring(response = 0.2f)

    fun spring(response: Float, damping: Float = 1f): SpringSpec<Float> {
        require(response > 0f && response.isFinite() && damping > 0f && damping.isFinite())
        val frequency = 2.0 * PI / response
        return composeSpring(dampingRatio = damping, stiffness = (frequency * frequency).toFloat(), visibilityThreshold = 0.04f)
    }

    fun <T> springLayout(response: Float, damping: Float = 1f): SpringSpec<T> {
        require(response > 0f && response.isFinite() && damping > 0f && damping.isFinite())
        val frequency = 2.0 * PI / response
        return composeSpring(dampingRatio = damping, stiffness = (frequency * frequency).toFloat())
    }

    fun <T> rowPlacement(reduced: Boolean): FiniteAnimationSpec<T> =
        if (reduced) snap() else tween(340, delayMillis = 40, easing = easeOut)

    /** A folder's rows on the Mac's clock (Folders.clock): coming out, going in. */
    fun <T> folderRows(opening: Boolean, reduced: Boolean): FiniteAnimationSpec<T> =
        if (reduced) snap() else if (opening) tween(220, easing = easeOut) else tween(140, easing = CubicBezierEasing(0f, 0f, 0.58f, 1f))

    fun rowIn(reduced: Boolean): FiniteAnimationSpec<Float> =
        if (reduced) snap() else tween(260, delayMillis = 60, easing = easeOut)

    fun rowOut(reduced: Boolean): FiniteAnimationSpec<Float> =
        if (reduced) snap() else tween(130, easing = easeIn)

    fun <T> toastIn(): TweenSpec<T> = tween(350, easing = CubicBezierEasing(0.3f, 1.3f, 0.4f, 1f))
    fun <T> toastOut(): TweenSpec<T> = tween(200, easing = easeIn)
}

/** Keep the direction anchor across subpoint scroll samples, as ChromeState.scrolled does. */
internal class BrowserChromeFold {
    private var lastScroll = 0f
    var folded = false
        private set

    fun scrolled(y: Float): Boolean {
        if (!y.isFinite()) return folded
        if (kotlin.math.abs(y - lastScroll) <= 3f && y >= 20f) return folded
        if (y > 50f && y - lastScroll > 3f) folded = true
        else if (lastScroll - y > 3f || y < 20f) folded = false
        lastScroll = y
        return folded
    }

    fun unfold(): Boolean {
        lastScroll = 0f
        folded = false
        return false
    }
}

/** One progress controls all plate geometry. Reversing a fold starts at its current pose. */
internal data class BrowserChromePose(val progress: Float, val viewport: Float, val wordsWidth: Float) {
    private val p = progress.coerceIn(0f, 1f)
    val plateWidth: Float get() = mix((viewport - 162f).coerceAtLeast(62f), (ceil(wordsWidth.toDouble()).toFloat() + 44f).coerceIn(62f, 158f))
    val plateHeight: Float get() = mix(48f, 31f)
    val bottom: Float get() = mix(28f, 16f)
    val labelSize: Float get() = mix(16f, 13f)
    val sideOpacity: Float get() = 1f - p
    val sideScale: Float get() = mix(1f, 0.8f)
    val sideSlide: Float get() = 26f * p
    private fun mix(from: Float, to: Float) = from + (to - from) * p
}
