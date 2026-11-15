package dev.yab.browser.ui

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.geometry.Rect

/** Optional scoped layout observation. It is neither a presentation fence nor a test clock. */
internal data class BrowserChromeFrame(val uptimeNanos: Long, val boundsPx: Rect, val density: Float)

internal val LocalBrowserChromeObserver = staticCompositionLocalOf<((BrowserChromeFrame) -> Unit)?> { null }
