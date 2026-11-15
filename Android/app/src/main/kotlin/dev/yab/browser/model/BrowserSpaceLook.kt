package dev.yab.browser.model

import kotlinx.serialization.json.*
import kotlin.math.*

/** Value-preserving port of Phone SpaceLook. Untouched paint fields ride through edits. */
internal data class BrowserSpaceLook private constructor(val raw: JsonObject) {
    val primary: Long get() = parseHex(raw.string("color") ?: "") ?: DEFAULT_COLOR
    val colors: List<Long> get() = (raw["colors"] as? JsonArray)?.mapNotNull {
        (it as? JsonPrimitive)?.takeIf { value -> value.isString }?.content?.let(::parseHex)
    } ?: emptyList()
    val grain: Double get() = unit(raw.number("grainAmount") ?: if (raw.boolean("grain") == true) .35 else 0.0)
    val transparency: Double get() = unit(raw.number("transparency") ?: 0.0)
    val drawings: String get() = raw.string("drawings") ?: ""
    val drawingsStrength: Double get() = unit(raw.number("drawingsStrength") ?: .45)
    val wash: Long get() = mapRgb(primary) { roundComponent(it * .18 + 255 * .82) }
    val ground: Long get() = readable(primary)

    fun palette(main: Long, links: List<Long>): BrowserSpaceLook = update(mapOf(
        "swatch" to JsonPrimitive("custom"), "color" to JsonPrimitive(hex(main)),
        "colors" to JsonArray(links.take(2).map { JsonPrimitive(hex(it)) })))
    fun grain(value: Double): BrowserSpaceLook {
        val amount = unit(value)
        return update(mapOf("grain" to JsonPrimitive(amount > 0), "grainAmount" to JsonPrimitive(amount)))
    }
    fun transparency(value: Double) = update(mapOf("transparency" to JsonPrimitive(unit(value))))
    fun drawings(value: String) = update(mapOf("drawings" to JsonPrimitive(value)))
    fun drawingsStrength(value: Double) = update(mapOf("drawingsStrength" to JsonPrimitive(unit(value))))

    /** Apply only fields actually changed since opening, onto the latest remote paint. */
    fun mergingChanges(opened: BrowserSpaceLook, latest: BrowserSpaceLook?): BrowserSpaceLook {
        val merged = (latest?.raw ?: raw).toMutableMap()
        EDITABLE.forEach { key ->
            if (raw[key] != opened.raw[key]) {
                val value = raw[key]
                if (value == null) merged.remove(key) else merged[key] = value
            }
        }
        return valid(JsonObject(merged)) ?: this
    }

    fun displayColors(dark: Boolean): List<Long> {
        val pair = SWATCHES[raw.string("swatch")]
        val first = pair?.let { if (dark) it.second else it.first }
            ?: if (dark) SpaceLookColor.deepened(primary) else primary
        return listOf(first) + colors.map { if (dark) SpaceLookColor.deepened(it) else it }
    }

    private fun update(fields: Map<String, JsonElement>) = BrowserSpaceLook(JsonObject(raw + fields))

    companion object {
        const val DEFAULT_COLOR: Long = 0xFFA8C3A0
        private val EDITABLE = listOf("swatch", "color", "colors", "grain", "grainAmount", "transparency", "drawings", "drawingsStrength")
        private val SWATCHES = mapOf(
            "gray" to (0xFFE3E3E5L to 0xFF202022L), "paper" to (0xFFECEAE4L to 0xFF1F1E1CL),
            "coral" to (0xFFF2837CL to 0xFF55282AL), "peach" to (0xFFF5BB8CL to 0xFF553823L),
            "sage" to (0xFFA8C3A0L to 0xFF28372AL), "sky" to (0xFF8DB6E6L to 0xFF1D304BL),
            "lavender" to (0xFFB6A6E6L to 0xFF2E274CL), "rose" to (0xFFEEA2C4L to 0xFF4C2338L),
            "graphite" to (0xFF3B3B3EL to 0xFF18181AL), "plain" to (0xFFFFFFFFL to 0xFF0F0F0FL))

        fun from(raw: JsonObject?, fallback: Long = DEFAULT_COLOR): BrowserSpaceLook = valid(raw) ?: BrowserSpaceLook(buildJsonObject {
            put("swatch", "custom"); put("color", hex(fallback)); put("grain", true)
            put("grainAmount", .35); put("transparency", 0)
        })
        private fun valid(raw: JsonObject?): BrowserSpaceLook? = raw?.takeIf {
            it.string("swatch") != null && parseHex(it.string("color") ?: "") != null
        }?.let { BrowserSpaceLook(JsonObject(it.toMap())) }
        fun unit(value: Double): Double = if (!value.isFinite() || value <= 0.0) 0.0 else min(1.0, value)
        fun hex(argb: Long): String = "#%06X".format(argb and 0xFFFFFF)
        fun parseHex(value: String): Long? {
            val digits = value.removePrefix("#")
            if (!digits.matches(Regex("[0-9a-fA-F]{6}"))) return null
            return 0xFF000000L or digits.toLong(16)
        }
        fun readable(argb: Long): Long {
            val r = component(argb, 16); val g = component(argb, 8); val b = component(argb, 0)
            val luminance = (.299 * r + .587 * g + .114 * b) / 255
            if (luminance >= .62) return opaque(argb)
            val t = (.62 - luminance) / (1 - luminance)
            return mapRgb(argb) { roundComponent(it + (255 - it) * t) }
        }
        internal fun component(argb: Long, shift: Int): Int = ((argb shr shift) and 255).toInt()
        internal fun opaque(argb: Long): Long = 0xFF000000L or (argb and 0xFFFFFF)
        internal fun rgb(r: Int, g: Int, b: Int): Long = 0xFF000000L or (r.toLong() shl 16) or (g.toLong() shl 8) or b.toLong()
        internal fun roundComponent(value: Double): Int = floor(value + .5).toInt().coerceIn(0, 255)
        private fun mapRgb(argb: Long, transform: (Double) -> Int): Long = rgb(
            transform(component(argb, 16).toDouble()), transform(component(argb, 8).toDouble()), transform(component(argb, 0).toDouble()))
        private fun JsonObject.string(key: String) = (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content
        private fun JsonObject.number(key: String) = (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull
        private fun JsonObject.boolean(key: String) = (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull
    }
}

/** Phone's gamut-limited OKLCH field. Coordinates are normalized, not UI pixels. */
internal class SpaceLookColor(lightness: Double, reach: Double, hue: Double) {
    val lightness = BrowserSpaceLook.unit(lightness)
    val reach = BrowserSpaceLook.unit(reach)
    val hue = turn(hue)
    val rgb: Long get() = rgb(lightness, chroma(lightness, hue) * reach, hue)
    val pointX: Double get() = .5 + cos(hue) * reach * .42
    val pointY: Double get() = .5 + sin(hue) * reach * .42
    fun move(x: Double, y: Double): SpaceLookColor {
        if (!x.isFinite() || !y.isFinite()) return this
        val dx = x - .5; val dy = y - .5; val distance = hypot(dx, dy)
        return SpaceLookColor(lightness, min(1.0, distance / .42), if (distance > .0001) atan2(dy, dx) else hue)
    }
    override fun equals(other: Any?) = other is SpaceLookColor && lightness == other.lightness && reach == other.reach && hue == other.hue
    override fun hashCode() = 31 * (31 * lightness.hashCode() + reach.hashCode()) + hue.hashCode()

    companion object {
        fun fromRgb(argb: Long): SpaceLookColor {
            val (light, c, hue) = lch(argb)
            val bounded = BrowserSpaceLook.unit(light)
            return SpaceLookColor(bounded, c / max(.001, chroma(bounded, hue)), hue)
        }
        fun turn(hue: Double): Double {
            if (!hue.isFinite()) return 0.0
            val result = hue % (2 * PI)
            return if (result < 0) result + 2 * PI else if (result == 0.0) 0.0 else result
        }
        fun deepened(argb: Long): Long {
            val (l, c, h) = lch(argb)
            val light = if (c < .02) (l * .3).coerceIn(.2, .24) else (l * .45).coerceIn(.2, .35)
            return rgb(light, c * .6, h)
        }
        fun filled(argb: Long): Long {
            val (_, c, h) = lch(argb); val light = .52
            return rgb(light, if (c < .012) .01 else min(chroma(light, h) * .5, max(.05, c * 1.6)), h)
        }
        private fun lch(argb: Long): Triple<Double, Double, Double> {
            fun linear(shift: Int): Double {
                val x = BrowserSpaceLook.component(argb, shift) / 255.0
                return if (x <= .04045) x / 12.92 else ((x + .055) / 1.055).pow(2.4)
            }
            val r = linear(16); val g = linear(8); val b = linear(0)
            val l = Math.cbrt(.4122214708*r + .5363325363*g + .0514459929*b)
            val m = Math.cbrt(.2119034982*r + .6806995451*g + .1073969566*b)
            val s = Math.cbrt(.0883024619*r + .2817188376*g + .6299787005*b)
            val a = 1.9779984951*l - 2.4285922050*m + .4505937099*s
            val z = .0259040371*l + .7827717662*m - .8086757660*s
            return Triple(.2104542553*l + .7936177850*m - .0040720468*s, hypot(a, z), atan2(z, a))
        }
        private fun linear(l: Double, c: Double, h: Double): DoubleArray {
            val a = c * cos(h); val b = c * sin(h)
            val x = (l + .3963377774*a + .2158037573*b).pow(3)
            val y = (l - .1055613458*a - .0638541728*b).pow(3)
            val z = (l - .0894841775*a - 1.2914855480*b).pow(3)
            return doubleArrayOf(4.0767416621*x - 3.3077115913*y + .2309699292*z,
                -1.2684380046*x + 2.6097574011*y - .3413193965*z,
                -.0041960863*x - .7034186147*y + 1.7076147010*z)
        }
        private fun rgb(l: Double, c: Double, h: Double): Long {
            val components = linear(l, c, h).map { value ->
                val x = value.coerceIn(0.0, 1.0)
                val gamma = if (x <= .0031308) 12.92*x else 1.055*x.pow(1 / 2.4) - .055
                BrowserSpaceLook.roundComponent(gamma * 255)
            }
            return BrowserSpaceLook.rgb(components[0], components[1], components[2])
        }
        private fun chroma(l: Double, h: Double): Double {
            var low = 0.0; var high = .37
            repeat(14) {
                val mid = (low + high) / 2
                if (linear(l, mid, h).all { it >= -.0001 && it <= 1.0001 }) low = mid else high = mid
            }
            return low
        }
    }
}

internal class SpaceLookHarmony(links: List<Link> = emptyList()) {
    data class Link(val hue: Double, val reach: Double = 0.0, val lightness: Double = 0.0)
    val links = links.take(2).toList()
    constructor(primary: SpaceLookColor, colors: List<Long>): this(colors.take(2).map {
        val color = SpaceLookColor.fromRgb(it)
        Link(SpaceLookColor.turn(color.hue - primary.hue), color.reach - primary.reach, color.lightness - primary.lightness)
    })
    fun colors(primary: SpaceLookColor): List<SpaceLookColor> = links.map {
        SpaceLookColor(primary.lightness + it.lightness, primary.reach + it.reach, primary.hue + it.hue)
    }
    fun move(index: Int, x: Double, y: Double, primary: SpaceLookColor): SpaceLookHarmony {
        if (index !in links.indices || !x.isFinite() || !y.isFinite()) return this
        val moved = colors(primary)[index].move(x, y)
        return SpaceLookHarmony(links.mapIndexed { i, link -> if (i != index) link else link.copy(
            hue = SpaceLookColor.turn(moved.hue - primary.hue), reach = moved.reach - primary.reach) })
    }
    companion object {
        fun suggested(extras: Int) = SpaceLookHarmony(when (extras) {
            1 -> listOf(Link(PI)); 2 -> listOf(Link(2*PI/3), Link(4*PI/3)); else -> emptyList()
        })
    }
}
