package dev.yab.browser.ui

import kotlin.math.max
import kotlin.math.min

/** Current Phone PageMenuMorph geometry. Coordinates are logical points in the host's root.
 * Native font measurement, material and SwiftUI's presented spring frames are separate evidence. */
internal data class PageMenuRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    val right get() = x + width
    val bottom get() = y + height
    val centerY get() = y + height / 2
    fun valid() = listOf(x, y, width, height).all(Double::isFinite) && width > 0 && height > 0 &&
        width <= 100_000 && height <= 100_000 && kotlin.math.abs(x) <= 100_000 && kotlin.math.abs(y) <= 100_000
    fun mix(to: PageMenuRect, t: Double) = PageMenuRect(lerp(x, to.x, t), lerp(y, to.y, t),
        lerp(width, to.width, t), lerp(height, to.height, t))
}

internal data class BrowserPageMenuGeometry(
    val width: Double,
    val height: Double,
    val safeTop: Double,
    val plate: PageMenuRect,
    val menuBody: Double,
    val siteBody: Double = 520.0,
    val certificateBody: Double = 300.0,
    /** Measured semibold title widths, including the current native font's tracking. */
    val hostTitleWidth: Double = 0.0,
    val certificateTitleWidth: Double = 0.0,
    val field: PageMenuRect? = null,
) {
    init {
        require(listOf(width, height, safeTop, menuBody, siteBody, certificateBody, hostTitleWidth,
            certificateTitleWidth).all(Double::isFinite) && width >= 160 && height > safeTop + 32 &&
            safeTop >= 0 && menuBody >= 0 && siteBody >= 0 && certificateBody >= 0 &&
            hostTitleWidth >= 0 && certificateTitleWidth >= 0 && plate.valid() && (field == null || field.valid()))
    }

    fun pose(frame: PageMenuFrame, reduced: Boolean): BrowserPageMenuPose {
        val site = clamp(frame.site); val certificate = clamp(frame.certificate); val toField = clamp(frame.toField)
        val fullWidth = width - 16
        val bottom = height - 8
        val bodyHeight = lerp(78 + menuBody, lerp(78 + siteBody, 78 + certificateBody, certificate), site)
        val sheetHeight = min(bodyHeight, bottom - safeTop - 24)
        val top = bottom - sheetHeight
        val travel = max(1.0, plate.centerY - (top + 14 + 24))
        val progress = if (reduced) 1.0 else clamp(frame.progress - frame.drag / travel)
        var sheet = plate.mix(PageMenuRect(8.0, top, fullWidth, sheetHeight), progress)
        var row = plate.mix(PageMenuRect(22.0, top + 14, fullWidth - 28, 48.0), progress)
        val words = lerp(hostTitleWidth, certificateTitleWidth, certificate)
        val headerWidth = min(fullWidth - 2 * (14 + 44 + 8), max(150.0, words + 24))
        row = row.copy(x = lerp(row.x, 8 + (fullWidth - headerWidth) / 2, site),
            width = lerp(row.width, headerWidth, site))
        var radius = lerp(plate.height / 2, 38.0, progress)
        if (toField > 0) {
            // There is no fabricated keyboard/field destination. Capture its actual layout first.
            val target = requireNotNull(field) { "The menu-to-field destination must be measured" }
            sheet = sheet.mix(target, toField); row = row.mix(target, toField)
            radius = lerp(radius, target.height / 2, toField)
        }
        val fade = if (reduced) clamp(frame.progress) else 1.0
        return BrowserPageMenuPose(progress, sheet, row, radius, travel, fade,
            if (reduced) (1 - clamp(frame.progress)) * 40 else 0.0, site, certificate, toField,
            .22 * progress * fade * (1 - toField), fade * (1 - clamp((toField - .75) / .25)),
            1 - clamp(toField / .35), -20 * clamp(toField / .35),
            1 - clamp((toField - .65) / .35), 1 - clamp(toField / .25),
            max(0.0, height - 8 - safeTop - 24 - 78), reduced, frame.shown, field)
    }
}

/** A body measurement can refine the same captured layout. A changed viewport/plate origin cannot
 * silently retarget a retained menu or its exit action; capture a new owner generation instead. */
internal class BrowserPageMenuLayoutLease {
    private data class Origin(val width: Double, val height: Double, val safeTop: Double, val plate: PageMenuRect)
    private var origin: Origin? = null
    var valid: Boolean = true; private set
    fun accept(geometry: BrowserPageMenuGeometry): Boolean {
        val next = Origin(geometry.width, geometry.height, geometry.safeTop, geometry.plate)
        if (origin == null) origin = next else if (origin != next) valid = false
        return valid
    }
}

internal data class BrowserPageMenuPose(val progress: Double, val sheet: PageMenuRect, val row: PageMenuRect,
    val radius: Double, val travel: Double, val fade: Double, val sink: Double, val site: Double,
    val certificate: Double, val toField: Double, val scrim: Double, val opacity: Double,
    val bodyOpacity: Double, val bodyOffset: Double, val rowOpacity: Double, val backOpacity: Double,
    val bodyRoom: Double, val reduced: Boolean, val shown: Boolean, val measuredField: PageMenuRect? = null) {
    fun block(index: Int) = if (reduced) 1.0 else if (shown) clamp((progress - .5 - index * .05) / .3)
        else clamp((progress - .6) / .2)
    val extras get() = clamp((progress - .45) / .4) * (1 - clamp(site * 2))
    val plateLines get() = 1 - clamp(progress / .3)
    val hostRoom get() = max(0.0, row.width - lerp(lerp(88.0, 178.0, progress), 12.0, site))
    val headerBack get() = PageMenuRect(sheet.x + 16, sheet.y + 16, 44.0, 44.0)
    val headerBackOpacity get() = clamp((site - .3) / .5) * backOpacity
    val headerBackScale get() = .8 + .2 * site
    val sideScale get() = 1 - .3 * clamp(progress / .35)
    val sideOpacity get() = 1 - clamp(progress / .35)
    fun sideOffset(direction: Int) = direction * 14 * clamp(progress / .35)
}

private fun lerp(a: Double, b: Double, t: Double) = a + (b - a) * t
private fun clamp(value: Double) = value.coerceIn(0.0, 1.0)
