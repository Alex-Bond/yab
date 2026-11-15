package dev.yab.browser.ui

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas as NativeCanvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalDensity
import dev.yab.browser.model.BrowserLookTexture
import dev.yab.browser.model.BrowserSpaceLook
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.roundToInt

/** Decorative only. Original surfaces retain all layout, clipping, owner, input and semantics. */
@Composable
internal fun BrowserSpaceLookGrain(amount: Double, modifier: Modifier = Modifier) {
    val opacity = BrowserLookTexture.grainOpacity(amount).toFloat()
    if (opacity == 0f) return
    val density = LocalDensity.current.density
    val tile = remember { grainBitmap() }
    val paint = remember(tile, density) { tilePaint(tile, (BrowserLookTexture.GRAIN_POINTS * density).toFloat()) }
    Canvas(modifier) { drawTiledImage(paint, opacity) }
}

/** Both source overlays, for callers whose Phone surface actually uses LookDrawingsFill. */
@Composable
internal fun BrowserSpaceLookTexture(look: BrowserSpaceLook, ground: Long, modifier: Modifier = Modifier) {
    Box(modifier) {
        BrowserSpaceLookGrain(look.grain, Modifier.fillMaxSize())
        BrowserSpaceLookDrawings(look.drawings, look.drawingsStrength, ground, Modifier.fillMaxSize())
    }
}

/** Phone SpaceLookWash. Field/Gallery use their own ground plus grain, not this full wash. */
@Composable
internal fun BrowserSpaceLookWash(look: BrowserSpaceLook, dark: Boolean, modifier: Modifier = Modifier) {
    val argb = look.displayColors(dark).map { if (dark) it else BrowserSpaceLook.readable(it) }
    val colors = argb.map { Color(it) }
    val top = colors.first()
    val light = Color(top.red + (1 - top.red) * .35f, top.green + (1 - top.green) * .35f,
        top.blue + (1 - top.blue) * .35f)
    val gradient = Brush.verticalGradient(listOf(light) + colors)
    Box(modifier) {
        Canvas(Modifier.fillMaxSize()) {
            drawRect(gradient)
            if (dark) drawRect(Color.Black.copy(alpha = .45f))
        }
        BrowserSpaceLookTexture(look, argb.first(), Modifier.fillMaxSize())
    }
}

@Composable
internal fun BrowserSpaceLookDrawings(drawings: String, strength: Double, ground: Long, modifier: Modifier = Modifier) {
    val set = BrowserLookTexture.set(drawings) ?: return
    val white = BrowserLookTexture.whiteInk(ground)
    val opacity = BrowserLookTexture.drawingOpacity(strength, white).toFloat()
    val density = LocalDensity.current.density
    val items = remember(set) { BrowserLookTexture.layout(set).flatMap(BrowserLookTexture::copies) }
    val paths = remember { BrowserLookTexture.Glyph.entries.associateWith(::nativePath) }
    val tile = remember(set, white, density) { drawingBitmap(items, paths, white, density) }
    val paint = remember(tile, density) { tile?.let { tilePaint(it, (BrowserLookTexture.DRAWING_SIDE * density).toFloat()) } }
    Canvas(modifier) {
        if (paint != null) drawTiledImage(paint, opacity)
        else if (density.isFinite() && density > 0f) {
            // Unusual densities need no oversized raster or resolution-reducing substitute.
            // Draw the same paths/period directly inside each exact clipped tile.
            drawIntoCanvas { canvas ->
                val native = canvas.nativeCanvas
                val side = (BrowserLookTexture.DRAWING_SIDE * density).toFloat()
                val pen = drawingPaint(white).apply { alpha = (opacity * 255).roundToInt() }
                var y = 0f
                while (y < size.height) {
                    var x = 0f
                    while (x < size.width) {
                        val saved = native.save()
                        try {
                            native.translate(x, y); native.clipRect(0f, 0f, side, side); native.scale(density, density)
                            drawItems(native, items, paths, pen)
                        } finally { native.restoreToCount(saved) }
                        x += side
                    }
                    y += side
                }
            }
        }
    }
}

private fun grainBitmap(): Bitmap {
    val rgba = BrowserLookTexture.grain()
    val argb = IntArray(BrowserLookTexture.GRAIN_PIXELS * BrowserLookTexture.GRAIN_PIXELS) { pixel ->
        val alpha = rgba[pixel * 4 + 3].toInt() and 255
        // Bitmap.setPixels accepts straight ARGB and premultiplies internally. Passing the
        // already-premultiplied source RGB here would multiply white points by alpha twice.
        (alpha shl 24) or if ((rgba[pixel * 4].toInt() and 255) == 0) 0 else 0xFFFFFF
    }
    return Bitmap.createBitmap(argb, BrowserLookTexture.GRAIN_PIXELS, BrowserLookTexture.GRAIN_PIXELS, Bitmap.Config.ARGB_8888)
}

private fun tilePaint(bitmap: Bitmap, logicalSidePx: Float): Paint {
    val shader = BitmapShader(bitmap, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT)
    shader.setLocalMatrix(Matrix().apply { setScale(logicalSidePx / bitmap.width, logicalSidePx / bitmap.height) })
    return Paint().apply { this.shader = shader; isFilterBitmap = false; isDither = false }
}

private fun DrawScope.drawTiledImage(paint: Paint, opacity: Float) {
    if (size.width <= 0 || size.height <= 0) return
    paint.alpha = (opacity * 255).roundToInt().coerceIn(0, 255)
    drawIntoCanvas { it.nativeCanvas.drawRect(0f, 0f, size.width, size.height, paint) }
}

private fun drawingPaint(white: Boolean) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = if (white) android.graphics.Color.WHITE else android.graphics.Color.BLACK
    style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
}

/** At most16MiB for this composition's current tile; published Bitmap lifetime belongs to GC. */
private fun drawingBitmap(items: List<BrowserLookTexture.Item>, paths: Map<BrowserLookTexture.Glyph, Path>, white: Boolean, density: Float): Bitmap? {
    if (!density.isFinite() || density <= 0) return null
    val requested = ceil(BrowserLookTexture.DRAWING_SIDE * density)
    if (requested > 2048) return null
    val side = requested.toInt().coerceAtLeast(1)
    val bitmap = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
    val canvas = NativeCanvas(bitmap)
    canvas.scale(density, density)
    drawItems(canvas, items, paths, drawingPaint(white))
    return bitmap
}

private fun drawItems(canvas: NativeCanvas, items: List<BrowserLookTexture.Item>, paths: Map<BrowserLookTexture.Glyph, Path>, paint: Paint) {
    for (item in items) {
        val saved = canvas.save()
        try {
            canvas.translate(item.x.toFloat(), item.y.toFloat())
            canvas.rotate((item.angle * 180 / PI).toFloat()); canvas.scale(item.size.toFloat(), item.size.toFloat())
            paint.strokeWidth = (BrowserLookTexture.STROKE_POINTS / item.size).toFloat()
            canvas.drawPath(paths.getValue(item.glyph), paint)
        } finally { canvas.restoreToCount(saved) }
    }
}

private fun nativePath(glyph: BrowserLookTexture.Glyph) = Path().apply {
    for (part in BrowserLookTexture.path(glyph)) when (part) {
        is BrowserLookTexture.Part.Move -> moveTo(part.x.toFloat(), part.y.toFloat())
        is BrowserLookTexture.Part.Line -> lineTo(part.x.toFloat(), part.y.toFloat())
        is BrowserLookTexture.Part.Quad -> quadTo(part.cx.toFloat(), part.cy.toFloat(), part.x.toFloat(), part.y.toFloat())
        is BrowserLookTexture.Part.Cubic -> cubicTo(part.cx1.toFloat(), part.cy1.toFloat(), part.cx2.toFloat(), part.cy2.toFloat(), part.x.toFloat(), part.y.toFloat())
        is BrowserLookTexture.Part.Box -> addRoundRect(RectF(part.x.toFloat(), part.y.toFloat(), (part.x + part.width).toFloat(), (part.y + part.height).toFloat()),
            part.radius.toFloat(), part.radius.toFloat(), Path.Direction.CW)
        is BrowserLookTexture.Part.Oval -> {
            val oval = Path().apply { addOval(RectF(part.x.toFloat(), part.y.toFloat(), (part.x + part.width).toFloat(), (part.y + part.height).toFloat()), Path.Direction.CW) }
            if (part.rotation != 0.0) oval.transform(Matrix().apply { setRotate((part.rotation * 180 / PI).toFloat()) })
            addPath(oval)
        }
        is BrowserLookTexture.Part.Arc -> arcTo(RectF((part.x - part.radius).toFloat(), (part.y - part.radius).toFloat(),
            (part.x + part.radius).toFloat(), (part.y + part.radius).toFloat()), (part.start * 180 / PI).toFloat(),
            (BrowserLookTexture.arcSweep(part) * 180 / PI).toFloat(), isEmpty)
        BrowserLookTexture.Part.Close -> close()
    }
}
