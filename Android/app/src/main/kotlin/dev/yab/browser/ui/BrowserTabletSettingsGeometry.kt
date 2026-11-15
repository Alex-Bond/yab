package dev.yab.browser.ui

import androidx.compose.runtime.staticCompositionLocalOf
import kotlin.math.min
import kotlin.math.roundToInt

/** Physical target layout, before the retained sheet's flight or finger translation. */
internal data class SettingsSheetFrame(val tablet: Boolean, val x: Int, val y: Int,
    val width: Int, val height: Int)
internal data class SettingsRootOrigin(val x: Float, val y: Float)
internal data class SettingsSheetInputFrame(val sheet: SettingsSheetFrame, val root: SettingsRootOrigin?)
internal data class SettingsViewport(val frame: SettingsSheetInputFrame, val keyboardOverlapPx: Double)

/** Drawing and gesture geometry only. This projection never grants a Settings action lease. */
internal val LocalSettingsViewport = staticCompositionLocalOf<SettingsViewport?> { null }

internal object BrowserTabletSettingsGeometry {
    fun frame(widthPx: Int, heightPx: Int, density: Double, smallestScreenWidthDp: Int): SettingsSheetFrame {
        require(widthPx >= 0 && heightPx >= 0 && density.isFinite() && density > 0)
        // The existing Android device policy is AndroidSyncBridge's smallestWidth >= 600.
        // The actual own viewport must additionally fit Phone's regular 700-point minimum.
        val tablet = smallestScreenWidthDp >= 600 && min(widthPx, heightPx) / density >= 700
        if (!tablet) return SettingsSheetFrame(false, 0, 0, widthPx, heightPx)
        val width = (min(600.0, widthPx / density - 48) * density).roundToInt().coerceAtLeast(1)
        val height = (min(760.0, heightPx / density - 80) * density).roundToInt().coerceAtLeast(1)
        return SettingsSheetFrame(true, ((widthPx - width) / 2.0).roundToInt(),
            ((heightPx - height) / 2.0).roundToInt(), width, height)
    }

    /** Insets and positionInWindow share window coordinates. A pane's bottom is not
     * the window's bottom. Drag/flight translation is deliberately absent here. */
    fun keyboardOverlap(frame: SettingsSheetFrame, root: SettingsRootOrigin?,
        windowHeightPx: Int, imeBottomPx: Int): Double {
        if (!frame.tablet || root == null || !root.y.isFinite() || windowHeightPx <= 0 || imeBottomPx <= 0) return 0.0
        val keyboardTop = windowHeightPx.toDouble() - imeBottomPx
        return (root.y + frame.y + frame.height - keyboardTop).coerceIn(0.0, frame.height.toDouble())
    }
}
