package dev.yab.browser.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import dev.yab.browser.icons.AndroidSiteIcons
import dev.yab.browser.model.BrowserTab

/** A renderer without an explicitly public scope can use only bundled/drawn pictures. */
internal data class BrowserSiteIconScope(val store: AndroidSiteIcons?, val privateSpace: Boolean = true)
internal val LocalBrowserSiteIcons = staticCompositionLocalOf { BrowserSiteIconScope(null) }

@Composable
internal fun BrowserFavicon(tab: BrowserTab, size: Dp, modifier: Modifier = Modifier, loads: Boolean = false) {
    val context = LocalContext.current.applicationContext
    val supplied = LocalBrowserSiteIcons.current
    // This default store never gets a loading callback, so fixture callers and
    // unscoped surfaces cannot silently initiate external requests.
    val fallback = remember(context) { AndroidSiteIcons.get(context) }
    val store = supplied.store ?: fallback
    val privateContent = supplied.privateSpace || tab.isPrivate
    val changes = if (!privateContent && supplied.store != null) {
        val pictures by store.pictures.collectAsState()
        pictures
    } else null
    // A page from history has no tab to fetch its icon for it.
    if (loads && !privateContent && supplied.store != null) LaunchedEffect(store, tab.url) { store.load(tab.url, null, false) }
    val density = LocalDensity.current.density
    val dark = MaterialTheme.colorScheme.background.luminance() < .5f
    val bitmap = remember(store, tab.url, tab.isPrivate, privateContent, size, density, dark, changes) {
        store.render(tab, size.value, density, dark, privateContent)
    }
    Image(bitmap.asImageBitmap(), contentDescription = null, modifier = modifier.size(size))
}
