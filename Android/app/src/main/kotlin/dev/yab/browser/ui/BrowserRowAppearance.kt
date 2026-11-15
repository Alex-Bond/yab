package dev.yab.browser.ui

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/** Field privacy has its own dark surface even when the application theme is light. */
internal val LocalBrowserRowInk = staticCompositionLocalOf<Color?> { null }
