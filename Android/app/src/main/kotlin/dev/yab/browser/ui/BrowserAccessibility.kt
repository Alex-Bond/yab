package dev.yab.browser.ui

import android.animation.ValueAnimator
import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.accessibility.AccessibilityManager
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import java.io.Closeable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

data class BrowserAccessibilityPreferences(val reduceMotion: Boolean = false, val spokenFeedback: Boolean = false) {
    fun duration(normalMillis: Int): Int = if (reduceMotion) 0 else normalMillis.coerceAtLeast(0)
}

/** Reads Android preferences only. It never enables services or changes system settings. */
class AndroidAccessibilityPreferences(context: Context) : Closeable {
    private val app = context.applicationContext
    private val accessibility = requireNotNull(app.getSystemService(AccessibilityManager::class.java))
    private val mutable = MutableStateFlow(read())
    val state: StateFlow<BrowserAccessibilityPreferences> = mutable
    private val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) { mutable.value = read() }
    }
    private val exploration = AccessibilityManager.TouchExplorationStateChangeListener { mutable.value = read() }
    init {
        app.contentResolver.registerContentObserver(Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE), false, observer)
        accessibility.addTouchExplorationStateChangeListener(exploration)
    }
    private fun read() = BrowserAccessibilityPreferences(
        reduceMotion = !ValueAnimator.areAnimatorsEnabled() || Settings.Global.getFloat(app.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) <= 0f,
        spokenFeedback = accessibility.isTouchExplorationEnabled)
    override fun close() {
        app.contentResolver.unregisterContentObserver(observer)
        accessibility.removeTouchExplorationStateChangeListener(exploration)
    }
}

val LocalBrowserAccessibility = staticCompositionLocalOf { BrowserAccessibilityPreferences() }

@Composable
fun BrowserAccessibility(content: @Composable () -> Unit) {
    val app = LocalContext.current.applicationContext
    val preferences = remember(app) { AndroidAccessibilityPreferences(app) }
    DisposableEffect(preferences) { onDispose { preferences.close() } }
    val state by preferences.state.collectAsState()
    CompositionLocalProvider(LocalBrowserAccessibility provides state, content = content)
}
