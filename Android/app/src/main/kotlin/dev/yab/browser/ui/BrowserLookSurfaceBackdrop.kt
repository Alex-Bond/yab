package dev.yab.browser.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.BrowserSpaceLook
import kotlinx.serialization.json.JsonPrimitive

/** A legacy/invalid paint stays a legacy tint. Reading a surface never normalizes or writes
 * its raw paint, and Private never reads a public look through this helper. */
internal fun browserSurfaceLook(space: BrowserSpace): BrowserSpaceLook? {
    if (space.isPrivate) return null
    val raw = space.look ?: return null
    if ((raw["swatch"] as? JsonPrimitive)?.isString != true) return null
    val color = (raw["color"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
    if (BrowserSpaceLook.parseHex(color) == null) return null
    return BrowserSpaceLook.from(raw)
}

internal fun browserSurfaceRgb(argb: Long) = BrowserSpacesRgb(
    ((argb shr 16) and 255).toDouble(), ((argb shr 8) and 255).toDouble(), (argb and 255).toDouble())

internal data class BrowserLookSurfacePaint(val tint: BrowserSpacesRgb, val grain: Double)
internal fun browserSpaceSurface(space: BrowserSpace?): BrowserLookSurfacePaint {
    if (space?.isPrivate == true) return BrowserLookSurfacePaint(BrowserSpacesRgb(28.0, 28.0, 32.0), 0.0)
    val look = space?.let(::browserSurfaceLook)
    return BrowserLookSurfacePaint(browserSurfaceRgb(look?.ground ?: space?.color ?: 0xFFEEE9E2), look?.grain ?: 0.0)
}

/** NewTabSpaces.wash and TabGalleryGround share this order: gradient, dark veil, then grain.
 * They do not draw LookDrawings. Bounds, clipping, owner checks and input stay with callers. */
@Composable
internal fun BrowserLookSurfaceBackdrop(wash: BrowserSpacesWash, grain: Double, modifier: Modifier = Modifier) {
    fun color(rgb: BrowserSpacesRgb) = Color((rgb.red / 255).toFloat(), (rgb.green / 255).toFloat(), (rgb.blue / 255).toFloat())
    Box(modifier.background(Brush.verticalGradient(listOf(color(wash.head), color(wash.foot))))) {
        if (wash.darkOverlay > 0) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = wash.darkOverlay.toFloat())))
        if (grain > 0) BrowserSpaceLookGrain(grain, Modifier.fillMaxSize())
    }
}
