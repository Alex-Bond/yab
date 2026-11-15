package dev.yab.browser.ui

import kotlin.math.*

/** Current Phone TabGalleryLayout/TabGalleryMotion, evaluated at the caller's frame time. */
internal data class GalleryRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    val right get() = x + width
    val bottom get() = y + height
    fun contains(px: Double, py: Double) = px >= x && px < right && py >= y && py < bottom
    fun shifted(dy: Double) = copy(y = y + dy)
    fun mix(to: GalleryRect, progress: Double) = GalleryRect(
        galleryMix(x, to.x, progress), galleryMix(y, to.y, progress),
        galleryMix(width, to.width, progress), galleryMix(height, to.height, progress))
}

internal fun galleryMix(from: Double, to: Double, progress: Double) = from + (to - from) * progress
internal fun galleryRubber(value: Double, span: Double): Double =
    sign(value) * span * (1 - 1 / (abs(value) * .55 / span + 1))

/** Phone's ground is opaque through content.maxY; only the chrome band follows bar. */
internal data class GalleryGroundMask(val contentBottom: Double, val lowerHeight: Double, val lowerOpacity: Double)

internal data class GallerySpring(val response: Double, val damping: Double) {
    fun value(seconds: Double): Double {
        if (seconds <= 0) return 0.0
        val natural = 2 * PI / response
        if (damping < 1) {
            val damped = natural * sqrt(1 - damping * damping)
            return 1 - exp(-damping * natural * seconds) *
                (cos(damped * seconds) + damping * natural / damped * sin(damped * seconds))
        }
        return 1 - (1 + natural * seconds) * exp(-natural * seconds)
    }
}

internal object GalleryTiming {
    val pageToCard = GallerySpring(.235, .92)
    val cardToStack = GallerySpring(.22, .88)
    val stackToCard = GallerySpring(.29, .94)
    val cardToPage = GallerySpring(.305, .94)
    const val openDuration = .5
    const val closeDuration = .45
    fun bar(seconds: Double): Double {
        val x = (seconds / .19).coerceIn(0.0, 1.0)
        fun bezier(a: Double, b: Double, t: Double) = 3 * (1 - t).pow(2) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        var low = 0.0
        var high = 1.0
        repeat(40) {
            val t = (low + high) / 2
            if (bezier(0.0, .58, t) < x) low = t else high = t
        }
        return bezier(0.0, 1.0, (low + high) / 2)
    }
}

internal data class GalleryLayout(
    val width: Double,
    val height: Double,
    val count: Int,
    val statusBar: Double = 54.0,
    val chromeBottom: Double = 28.0,
    val stackButton: GalleryRect? = null,
) {
    val page get() = GalleryRect(0.0, 0.0, width, height)
    val contentHeight get() = max(1.0, height - chromeBottom - 48 - statusBar)
    fun groundMask(bar: Double): GalleryGroundMask {
        val visibleHeight = height.coerceAtLeast(0.0)
        val boundary = (statusBar + contentHeight).coerceIn(0.0, visibleHeight)
        return GalleryGroundMask(boundary, visibleHeight - boundary, bar.coerceIn(0.0, 1.0))
    }
    val contentTop get() = if (height > 0) statusBar / height else 0.0
    val initialFocus get() = max(0, count - 2).toDouble()
    val maxFocus get() = max(0, count - 1).toDouble()
    val step get() = max(1.0, (.7781 - .2147) * width)
    val plus get() = GalleryRect((width - 96) / 2, height - chromeBottom - 48, 96.0, 48.0)
    val circle get() = stackButton ?: GalleryRect(width - 26 - 48, height - chromeBottom - 48, 48.0, 48.0)
    val front get() = GalleryRect(circle.x + 24 + 2 - 11, circle.y + 24 - 1 - 12, 22.0, 24.0)
    val back get() = GalleryRect(circle.x + 24 - 4 - 11, circle.y + 24 + 2 - 12, 22.0, 24.0)

    fun rect(depth: Double, last: Double = 0.0): GalleryRect {
        val table = listOf(Triple(-1.0, .7781, .780), Triple(0.0, .2147, .7714),
            Triple(1.0, .0301, .755), Triple(2.0, -.0253, .709), Triple(3.0, -.0573, .663))
        var index = 0
        while (index < table.size - 2 && depth > table[index + 1].first) index++
        val a = table[index]
        val b = table[index + 1]
        val t = (depth - a.first) / (b.first - a.first)
        var left = galleryMix(a.second, b.second, t)
        val cardHeight = galleryMix(a.third, b.third, t) * contentHeight
        val cardWidth = cardHeight * width / max(1.0, height - statusBar)
        if (last > 0 && depth > -1 && depth < 1) {
            val centered = (width - cardWidth) / 2 / width
            left += (centered - left) * last * (1 - abs(depth))
        }
        val x = left * width
        val y = .5148 * height - cardHeight / 2
        // CGRect getters standardize negative extrapolated sizes far offscreen.
        return GalleryRect(min(x, x + cardWidth), min(y, y + cardHeight), abs(cardWidth), abs(cardHeight))
    }

    fun last(focus: Double) = if (count < 2) 1.0 else (focus - (count - 2)).coerceIn(0.0, 1.0)
    fun card(index: Int, focus: Double) = rect(focus - index, last(focus))
    fun draws(index: Int, focus: Double) = (focus - index) > -1.5 && (focus - index) <= 4
    fun titleWidth(index: Int, focus: Double): Double {
        val own = card(index, focus)
        val start = own.x + 18 + 20 + 6.5
        val end = if (index + 1 < count) card(index + 1, focus).x + 18 else own.right
        return max(0.0, min(end, own.right) - 16 - start)
    }
    fun resisted(focus: Double): Double = when {
        focus < 0 -> galleryRubber(focus * step, 60.0) / step
        focus > maxFocus -> maxFocus + galleryRubber((focus - maxFocus) * step, 60.0) / step
        else -> focus
    }
    fun hit(x: Double, y: Double, focus: Double): Int? =
        (0 until count).reversed().firstOrNull { card(it, focus).contains(x, y) }

    companion object {
        fun settle(from: Double, moved: Double, thrown: Double): Double {
            // Swift rounds halfway away from zero; kotlin.round uses ties to even.
            val start = from.roundAway()
            val flung = thrown - start
            val dragged = moved - start
            if (abs(flung) < .15 && abs(dragged) < 1.0 / 3) return start
            val way = if ((if (abs(flung) >= .15) flung else dragged) > 0) 1 else -1
            return start + way * max(1.0, abs(flung).roundAway())
        }
        fun veil(depth: Double) = when {
            depth <= 0 -> 0.0
            depth <= 1 -> .2 * depth
            depth <= 2 -> .2 + .15 * (depth - 1)
            else -> .35
        }
        fun icon(depth: Double) = when {
            depth <= 1 -> 1.0
            depth <= 2 -> 1 - .6 * (depth - 1)
            depth <= 3 -> .4 * (3 - depth)
            else -> 0.0
        }
    }
}

internal fun Double.roundAway() = sign(this) * floor(abs(this) + .5)

internal data class GalleryPose(
    val rect: GalleryRect,
    val angle: Double = 0.0,
    val radius: Double = 0.0,
    val cropTop: Double = 0.0,
    val opacity: Double = 1.0,
    val veil: Double = 0.0,
    val icon: Double = 1.0,
    val title: Double = 0.0,
    val labelScale: Double = 1.0,
    val titleWidth: Double = 0.0,
    val rim: Double = 0.0,
    val z: Double = 0.0,
)

internal enum class GalleryRole { CHOSEN, FRONT, BACK, OTHER }
internal data class GalleryClosing(val count: Int, val chosen: Int) {
    val remaining = (0 until count).reversed().filter { it != chosen }
    val front = remaining.firstOrNull()
    val back = remaining.getOrNull(1)
    val rises = chosen == count - 1
    fun role(index: Int) = when {
        index == chosen -> GalleryRole.CHOSEN
        index == front && index > chosen -> GalleryRole.FRONT
        index == back && index > chosen -> GalleryRole.BACK
        else -> GalleryRole.OTHER
    }
    val seated get() = listOfNotNull(front?.let { it to GalleryRole.FRONT }, back?.let { it to GalleryRole.BACK })
        .filter { role(it.first) == GalleryRole.OTHER }
}

internal object GalleryMotion {
    fun rise(rises: Boolean, seconds: Double) = if (rises) 104 * (1 - GalleryTiming.cardToStack.value(seconds)) else 0.0

    fun seated(role: GalleryRole, rises: Boolean, layout: GalleryLayout, seconds: Double): GalleryPose {
        val front = role == GalleryRole.FRONT
        val shown = if (rises) 1.0 else GalleryTiming.cardToStack.value(seconds).coerceIn(0.0, 1.0)
        return GalleryPose((if (front) layout.front else layout.back).shifted(rise(rises, seconds)),
            angle = if (front) 8.0 else -12.0, radius = 4.0, cropTop = layout.contentTop,
            opacity = (if (front) 1.0 else .87) * shown, veil = if (front) 0.0 else .08,
            icon = 0.0, rim = 1.0, z = if (front) -1.0 else -2.0)
    }

    fun rest(index: Int, layout: GalleryLayout, focus: Double): GalleryPose {
        val depth = focus - index
        val rect = layout.card(index, focus)
        return GalleryPose(rect, radius = rect.height * .0462, cropTop = layout.contentTop,
            veil = GalleryLayout.veil(depth), icon = GalleryLayout.icon(depth),
            title = max(0.0, 1 - abs(depth)), titleWidth = layout.titleWidth(index, focus), z = index.toDouble())
    }

    fun opening(index: Int, layout: GalleryLayout, seconds: Double): GalleryPose {
        val to = rest(index, layout, layout.initialFocus)
        val count = layout.count
        val p: Double
        var pose = when (index) {
            count - 1 -> {
                p = GalleryTiming.pageToCard.value(seconds)
                to.copy(rect = layout.page.mix(to.rect, p), radius = to.radius * p, cropTop = to.cropTop * p)
            }
            count - 2 -> {
                p = GalleryTiming.stackToCard.value(seconds - .02)
                to.copy(rect = layout.front.mix(to.rect, p), angle = galleryMix(8.0, 0.0, GalleryTiming.pageToCard.value(seconds)),
                    radius = galleryMix(4.0, to.radius, p), veil = to.veil * p)
            }
            count - 3 -> {
                p = GalleryTiming.stackToCard.value(seconds - .035)
                to.copy(rect = layout.back.mix(to.rect, p), angle = galleryMix(-12.0, 0.0, GalleryTiming.pageToCard.value(seconds - .015)),
                    radius = galleryMix(4.0, to.radius, p), veil = galleryMix(.08, to.veil, p), opacity = galleryMix(.87, 1.0, p))
            }
            else -> {
                p = GalleryTiming.stackToCard.value(seconds - .06)
                to.copy(rect = layout.back.mix(to.rect, p), angle = galleryMix(-12.0, 0.0, GalleryTiming.pageToCard.value(seconds - .04)),
                    radius = galleryMix(4.0, to.radius, p), opacity = ((seconds - .03) / .09).coerceIn(0.0, 1.0))
            }
        }
        if (index < count - 1) pose = pose.copy(rim = 1 - p.coerceIn(0.0, 1.0))
        val shown = (p / .55).coerceIn(0.0, 1.0)
        return pose.copy(icon = to.icon * shown * pose.opacity, title = to.title * shown,
            labelScale = if (to.rect.height > 0) min(1.5, pose.rect.height / to.rect.height) else 1.0)
    }

    fun closing(role: GalleryRole, from: GalleryPose, layout: GalleryLayout, seconds: Double): GalleryPose {
        val p: Double
        val pose = when (role) {
            GalleryRole.CHOSEN -> {
                p = GalleryTiming.cardToPage.value(seconds)
                from.copy(rect = from.rect.mix(layout.page, p), angle = from.angle * (1 - p),
                    radius = from.radius * (1 - p), cropTop = from.cropTop * (1 - p),
                    veil = from.veil * (1 - p), opacity = galleryMix(from.opacity, 1.0, p), rim = from.rim * (1 - p))
            }
            GalleryRole.FRONT, GalleryRole.BACK -> {
                p = GalleryTiming.cardToStack.value(seconds)
                val front = role == GalleryRole.FRONT
                from.copy(rect = from.rect.mix(if (front) layout.front else layout.back, p),
                    angle = galleryMix(from.angle, if (front) 8.0 else -12.0, p), radius = galleryMix(from.radius, 4.0, p),
                    cropTop = galleryMix(from.cropTop, layout.contentTop, p), veil = galleryMix(from.veil, if (front) 0.0 else .08, p),
                    opacity = galleryMix(from.opacity, if (front) 1.0 else .87, p), rim = galleryMix(from.rim, 1.0, p.coerceIn(0.0, 1.0)))
            }
            GalleryRole.OTHER -> {
                p = min(seconds / .1, 1.0)
                from.copy(opacity = from.opacity * (1 - p))
            }
        }
        val kept = 1 - (p / .6).coerceIn(0.0, 1.0)
        return pose.copy(icon = from.icon * kept, title = from.title * kept,
            labelScale = if (from.rect.height > 0) from.labelScale * pose.rect.height / from.rect.height else from.labelScale)
    }
}
