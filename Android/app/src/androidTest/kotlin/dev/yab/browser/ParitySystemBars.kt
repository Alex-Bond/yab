package dev.yab.browser

import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalContext
import androidx.core.view.WindowInsetsControllerCompat
import dev.yab.browser.model.BrowserAppearance

/** Component hosts adopt the same contrast as MainActivity; captures remain native. */
@Composable internal fun ParitySystemBars(appearance: BrowserAppearance) {
    val context = LocalContext.current
    val activity = generateSequence(context) { (it as? android.content.ContextWrapper)?.baseContext }
        .filterIsInstance<android.app.Activity>().firstOrNull()
    SideEffect { activity?.let {
        WindowInsetsControllerCompat(it.window, it.window.decorView).apply {
            isAppearanceLightStatusBars = appearance != BrowserAppearance.DARK
            isAppearanceLightNavigationBars = appearance != BrowserAppearance.DARK
        }
    } }
}
