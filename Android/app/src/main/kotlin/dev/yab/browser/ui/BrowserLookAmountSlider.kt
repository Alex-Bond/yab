package dev.yab.browser.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color as NativeColor
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.IBinder
import android.util.TypedValue
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import android.widget.SeekBar
import android.widget.TextView
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.ViewCompat
import dev.yab.browser.model.*
import kotlin.math.roundToInt

/** Owner is the original editor lease. Callbacks are never rebound to a later owner's token. */
@Composable
internal fun BrowserLookAmountSlider(owner: Any, kind: BrowserLookAmountKind, value: Double,
    current: () -> Boolean, change: (Double) -> Unit, ended: () -> Unit, modifier: Modifier = Modifier) {
    val dark = MaterialTheme.colorScheme.background.luminance() < .5f
    key(owner, kind) {
        AndroidView(modifier = modifier.widthIn(min = 44.dp).height(48.dp),
            factory = { LookAmountNativeView(it, kind, value, current, change, ended) },
            update = { it.project(value, dark) }, onReset = null, onRelease = { it.release() })
    }
}

/** Native pointer, key and accessibility range handling; custom source track/pill underneath. */
// The host uses a platform Material theme. This native control owns its track and thumb;
// AppCompat delegate tinting is intentionally unused.
@SuppressLint("AppCompatCustomView")
private class LookAmountNativeView(context: Context, private val kind: BrowserLookAmountKind, initial: Double,
    private val originalCurrent: () -> Boolean, private val originalChange: (Double) -> Unit,
    private val originalEnded: () -> Unit) : FrameLayout(context) {
    private val state = BrowserLookAmountController(kind, initial)
    private val density = resources.displayMetrics.density
    private val dots = if (kind == BrowserLookAmountKind.GRAIN) BrowserLookAmount.grains() else emptyList()
    private val pen = Paint(Paint.ANTI_ALIAS_FLAG)
    private var dark = false
    private var bubbleHeld = false
    private var originalWindow: IBinder? = null
    private var touchWindow: IBinder? = null
    private var touchBounds: Rect? = null
    private val label = TextView(context).apply {
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        isClickable = false; isFocusable = false; includeFontPadding = false
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
        typeface = Typeface.create(Typeface.MONOSPACE, 500, false)
        setPadding(dp(6.0), dp(2.0), dp(6.0), dp(2.0)); alpha = 0f
    }
    private val slider = object : SeekBar(context) {
        override fun onTouchEvent(event: MotionEvent): Boolean {
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                if (!inputAllowed()) return false
                touchWindow = windowToken
                touchBounds = Rect().takeIf { getGlobalVisibleRect(it) && !it.isEmpty }
                if (touchBounds == null || !state.begin(sourceOwned(), touching = true)) return false
                hold(true)
            } else if (touchWindow == null) return false
            if (event.pointerCount != 1 || !inputAllowed() || !sameTouchWindow()) {
                val cancel = MotionEvent.obtain(event).apply { action = MotionEvent.ACTION_CANCEL }
                try { super.onTouchEvent(cancel) } finally { cancel.recycle(); finish(); clearTouch() }
                return false
            }
            return try { super.onTouchEvent(event) }
            finally {
                if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
                    finish(); clearTouch()
                }
            }
        }
        override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean =
            if (!inputAllowed() || state.held) false else super.onKeyDown(keyCode, event)

        override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
            if (!inputAllowed() || state.held) return false
            if (action == AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.id) {
                if (arguments == null || !arguments.containsKey(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE)) return false
                @Suppress("DEPRECATION")
                val value = arguments.get(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE) as? Float ?: return false
                if (!value.isFinite() || value !in 0f..1f) return false
                return accessibilityValue(value.toDouble())
            }
            return super.performAccessibilityAction(action, arguments)
        }
        override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
            super.onInitializeAccessibilityNodeInfo(info)
            val enabled = sourceOwned() && windowAvailable()
            info.isEnabled = enabled
            info.rangeInfo = AccessibilityNodeInfo.RangeInfo.obtain(AccessibilityNodeInfo.RangeInfo.RANGE_TYPE_FLOAT, 0f, 1f, state.shown.toFloat())
            if (!enabled) {
                info.removeAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS)
                info.removeAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_FORWARD)
                info.removeAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_BACKWARD)
            }
        }
    }.apply {
        max = MAX_PROGRESS
        keyProgressIncrement = MAX_PROGRESS / 20
        progressDrawable = ColorDrawable(NativeColor.TRANSPARENT)
        tickMark = null; splitTrack = false
        thumb = Pill(density)
        //AbsSeekBar subtracts thumbWidth then adds twice this offset to the travel.
        //With the22dp shadow image/offset11, its center is7 + value*(width-14).
        thumbOffset = dp((BrowserLookAmount.PILL_WIDTH + 2 * BrowserLookAmount.PILL_SHADOW_PAD) / 2)
        setPadding(dp(BrowserLookAmount.TRACK_INSET), 0, dp(BrowserLookAmount.TRACK_INSET), 0)
        layoutDirection = View.LAYOUT_DIRECTION_LTR //The source's custom coordinates progress left to right.
        background = null
        contentDescription = kind.title
        setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onStartTrackingTouch(seekBar: SeekBar) {
                if (!state.active && inputAllowed()) { state.begin(sourceOwned(), touching = true); hold(true) }
            }
            override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                if (!fromUser) return
                if (!inputAllowed()) return
                val discrete = !state.held
                if (!state.active && !state.begin(sourceOwned(), touching = false)) return
                changed(progress.toDouble() / MAX_PROGRESS)
                if (discrete) finish()
            }
            override fun onStopTrackingTouch(seekBar: SeekBar) { finish() }
        })
    }

    init {
        setWillNotDraw(false); clipChildren = false; clipToPadding = false
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        addView(slider, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        addView(label, LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        project(initial, false)
    }

    /** Projection cannot replace callback authority and never resets an active native drag. */
    fun project(value: Double, dark: Boolean) {
        this.dark = dark
        if (sourceOwned()) state.project(value)
        if (!state.active) slider.progress = (state.shown * MAX_PROGRESS).roundToInt()
        refreshEnabled(); refresh()
    }
    private fun sourceAvailable() = !state.revoked && runCatching(originalCurrent).getOrDefault(false)
    private fun sourceOwned() = state.accept(sourceAvailable())
    private fun windowAvailable() = isAttachedToWindow && hasWindowFocus() && originalWindow != null && windowToken === originalWindow
    private fun inputAllowed() = sourceOwned() && windowAvailable() && width > 0 && height > 0
    private fun refreshEnabled() {
        slider.isEnabled = sourceOwned() && windowAvailable()
        if (state.revoked) hold(false)
    }
    private fun sameTouchWindow(): Boolean {
        val now = Rect()
        return touchWindow === windowToken && touchWindow === originalWindow &&
            slider.getGlobalVisibleRect(now) && now == touchBounds
    }
    private fun clearTouch() { touchWindow = null; touchBounds = null }
    private fun changed(value: Double) {
        if (!inputAllowed()) return
        val accepted = state.change(value, sourceOwned()) ?: return
        if (accepted.haptic != BrowserLookAmountHaptic.NONE && sourceOwned()) slider.performHapticFeedback(
            if (accepted.haptic == BrowserLookAmountHaptic.END) HapticFeedbackConstants.CONTEXT_CLICK else HapticFeedbackConstants.CLOCK_TICK)
        if (sourceOwned()) originalChange(accepted.value)
        refresh()
    }
    private fun accessibilityValue(value: Double): Boolean {
        if (!inputAllowed() || !state.begin(sourceOwned(), touching = false)) return false
        changed(value)
        if (!state.revoked) slider.progress = (state.shown * MAX_PROGRESS).roundToInt()
        finish()
        return !state.revoked
    }
    private fun finish() {
        val dispatch = state.finish(sourceOwned())
        hold(false)
        if (dispatch && sourceOwned()) originalEnded()
    }
    private fun hold(on: Boolean) {
        val next = on && !state.revoked
        if (next != bubbleHeld) {
            bubbleHeld = next
            label.animate().cancel()
            label.animate().alpha(if (next) 1f else 0f).setDuration(BrowserLookAmount.BUBBLE_FADE_MILLIS).start()
        }
        refresh()
    }
    private fun refresh() {
        label.text = BrowserLookAmount.bubbleText(kind, state.shown)
        label.setTextColor(if (dark) NativeColor.rgb(28, 28, 28) else NativeColor.WHITE)
        label.background = GradientDrawable().apply {
            setColor(if (dark) NativeColor.rgb(237, 237, 237) else NativeColor.rgb(23, 23, 23)); cornerRadius = dp(100.0).toFloat()
        }
        ViewCompat.setStateDescription(slider, "${BrowserLookAmount.percent(state.shown)}%")
        slider.thumb.invalidateSelf(); requestLayout(); invalidate()
    }
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (originalWindow == null) originalWindow = windowToken
        else if (windowToken !== originalWindow) state.revoke()
        post { if (!state.revoked) refreshEnabled() }
    }
    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        if (!hasWindowFocus) { finish(); clearTouch() }
        refreshEnabled()
    }
    override fun onDetachedFromWindow() { release(); super.onDetachedFromWindow() }
    fun release() {
        state.revoke(); clearTouch(); slider.isEnabled = false
        bubbleHeld = false; label.animate().cancel(); label.alpha = 0f
        slider.setOnSeekBarChangeListener(null)
    }
    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        slider.layout(0, 0, width, height)
        label.measure(MeasureSpec.UNSPECIFIED, MeasureSpec.UNSPECIFIED)
        val rect = BrowserLookAmount.bubble(width / density.toDouble(), state.shown,
            label.measuredWidth / density.toDouble(), label.measuredHeight / density.toDouble()) ?: return
        val x = dp(rect.x); val y = dp(rect.y)
        label.layout(x, y, x + label.measuredWidth, y + label.measuredHeight)
    }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val track = BrowserLookAmount.track(width / density.toDouble(), height / density.toDouble(), state.shown, state.held) ?: return
        val ink = if (dark) 237 else 23
        pen.color = NativeColor.rgb(ink, ink, ink)
        if (kind == BrowserLookAmountKind.GRAIN) {
            pen.style = Paint.Style.FILL
            for (dot in dots) {
                pen.alpha = ((if (dot.x <= state.shown) .72 else .16) * 255).roundToInt()
                canvas.drawCircle(((track.left + dot.x * track.width) * density).toFloat(),
                    ((track.middle + dot.y * 10) * density).toFloat(), (dot.radius * density).toFloat(), pen)
            }
        } else {
            pen.style = Paint.Style.STROKE; pen.strokeWidth = 1.2f * density; pen.strokeCap = Paint.Cap.ROUND
            for (x in BrowserLookAmount.crosses()) {
                pen.alpha = ((if (x <= state.shown) .72 else .16) * 255).roundToInt()
                val at = ((track.left + x * track.width) * density).toFloat(); val mid = (track.middle * density).toFloat()
                canvas.drawLine(at - 2.5f * density, mid, at + 2.5f * density, mid, pen)
                canvas.drawLine(at, mid - 2.5f * density, at, mid + 2.5f * density, pen)
            }
        }
    }
    private fun dp(value: Double) = (value * density).roundToInt()

    private class Pill(private val density: Float) : Drawable() {
        private val pen = Paint(Paint.ANTI_ALIAS_FLAG)
        private var held = false
        override fun getIntrinsicWidth() = ((BrowserLookAmount.PILL_WIDTH + 2 * BrowserLookAmount.PILL_SHADOW_PAD) * density).roundToInt()
        override fun getIntrinsicHeight() = ((BrowserLookAmount.PILL_HELD_HEIGHT + 2 * BrowserLookAmount.PILL_SHADOW_PAD) * density).roundToInt()
        override fun isStateful() = true
        override fun onStateChange(state: IntArray): Boolean {
            val next = android.R.attr.state_pressed in state
            if (next == held) return false
            held = next; invalidateSelf(); return true
        }
        override fun draw(canvas: Canvas) {
            val wide = (BrowserLookAmount.PILL_WIDTH * density).toFloat()
            val high = ((if (held) BrowserLookAmount.PILL_HELD_HEIGHT else BrowserLookAmount.PILL_NORMAL_HEIGHT) * density).toFloat()
            val rect = RectF(bounds.exactCenterX() - wide / 2, bounds.exactCenterY() - high / 2,
                bounds.exactCenterX() + wide / 2, bounds.exactCenterY() + high / 2)
            pen.style = Paint.Style.FILL; pen.color = NativeColor.WHITE
            pen.setShadowLayer(4 * density, 0f, density, 0x40000000); canvas.drawRoundRect(rect, wide / 2, wide / 2, pen)
            pen.clearShadowLayer(); pen.style = Paint.Style.STROKE; pen.strokeWidth = .5f * density; pen.color = 0x38000000
            rect.inset(.25f * density, .25f * density)
            canvas.drawRoundRect(rect, wide / 2 - .25f * density, wide / 2 - .25f * density, pen)
        }
        override fun setAlpha(alpha: Int) = Unit
        override fun setColorFilter(colorFilter: android.graphics.ColorFilter?) = Unit
        @Suppress("DEPRECATION") override fun getOpacity() = android.graphics.PixelFormat.TRANSLUCENT
    }
    companion object { private const val MAX_PROGRESS = 1_000_000 }
}
