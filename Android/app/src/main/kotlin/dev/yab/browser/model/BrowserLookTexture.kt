package dev.yab.browser.model

import kotlin.math.*

/** Deterministic Phone LookDrawings.swift geometry. Contains no Android, owner or cached pixels. */
internal object BrowserLookTexture {
    const val DRAWING_SIDE = 320.0
    const val GRAIN_PIXELS = 128
    const val GRAIN_POINTS = 64.0
    const val STROKE_POINTS = 1.3
    enum class Set { BROWSER, LIFE }
    enum class Glyph {
        GLOBE, CURSOR, MAIL, BOOKMARK, KEY, LOCK, SEARCH, COMMAND, TAB, DOWNLOAD, PUZZLE, COMPASS,
        BOLT, PENCIL, STAR, CUP, HEART, CAT, MOON, NOTE, PLANET, CLOUD, PLANE, SPARKLE, PLAY, SQUIGGLE, PLUS,
    }
    data class Item(val glyph: Glyph, val x: Double, val y: Double, val size: Double, val angle: Double)
    sealed interface Part {
        data class Move(val x: Double, val y: Double) : Part
        data class Line(val x: Double, val y: Double) : Part
        data class Quad(val cx: Double, val cy: Double, val x: Double, val y: Double) : Part
        data class Cubic(val cx1: Double, val cy1: Double, val cx2: Double, val cy2: Double, val x: Double, val y: Double) : Part
        data class Oval(val x: Double, val y: Double, val width: Double, val height: Double, val rotation: Double = 0.0) : Part
        data class Box(val x: Double, val y: Double, val width: Double, val height: Double, val radius: Double = 0.0) : Part
        data class Arc(val x: Double, val y: Double, val radius: Double, val start: Double, val end: Double, val clockwise: Boolean = false) : Part
        data object Close : Part
    }
    private val browser = listOf(Glyph.GLOBE, Glyph.CURSOR, Glyph.MAIL, Glyph.BOOKMARK, Glyph.KEY, Glyph.LOCK,
        Glyph.SEARCH, Glyph.COMMAND, Glyph.TAB, Glyph.DOWNLOAD, Glyph.PUZZLE, Glyph.COMPASS, Glyph.BOLT, Glyph.PENCIL, Glyph.STAR)
    private val life = listOf(Glyph.CUP, Glyph.HEART, Glyph.CAT, Glyph.MOON, Glyph.NOTE, Glyph.PLANET,
        Glyph.CLOUD, Glyph.PLANE, Glyph.SPARKLE, Glyph.STAR, Glyph.PLAY, Glyph.GLOBE)
    private val small = listOf(Glyph.SQUIGGLE, Glyph.PLUS, Glyph.SPARKLE)
    fun set(raw: String): Set? = when (raw) { "browser" -> Set.BROWSER; "life" -> Set.LIFE; else -> null }
    private fun unit(value: Double) = if (value.isFinite()) value.coerceIn(0.0, 1.0) else 0.0
    fun grainOpacity(amount: Double) = unit(amount) * .2
    fun drawingOpacity(strength: Double, white: Boolean) = if (white) .015 + .17 * unit(strength) else .02 + .2 * unit(strength)
    fun whiteInk(ground: Long): Boolean = (.299 * ((ground shr 16) and 255) +
        .587 * ((ground shr 8) and 255) + .114 * (ground and 255)) / 255 < .6

    /** UInt32 xorshift. JVM Int wrapping and unsigned shift retain the original bit pattern. */
    fun nextGrain(seed: Int): Int {
        var value = seed
        value = value xor (value shl 13); value = value xor (value ushr 17); value = value xor (value shl 5)
        return value
    }
    /** RGBA premultiplied-last bytes, exactly as the source's CGImage input. Fresh array per call. */
    fun grain(seed: Int = 0x2545F491): ByteArray {
        val result = ByteArray(GRAIN_PIXELS * GRAIN_PIXELS * 4)
        var state = seed
        repeat(GRAIN_PIXELS * GRAIN_PIXELS) { pixel ->
            state = nextGrain(state)
            val alpha = (state ushr 8) and 255
            val value = if ((state and 1) == 0) 0 else alpha
            val index = pixel * 4
            result[index] = value.toByte(); result[index + 1] = value.toByte(); result[index + 2] = value.toByte()
            result[index + 3] = alpha.toByte()
        }
        return result
    }

    /** Signed Long overflow is the same modulo-2^64 update as Swift's &* / &+. */
    fun layout(set: Set): List<Item> {
        var seed = if (set == Set.BROWSER) 0x51A7E5EDL else 0x0B1FEDA7L
        fun next(): Double {
            seed = seed * 6364136223846793005L + 1442695040888963407L
            return (seed ushr 33).toDouble() / 2147483648.0
        }
        val big = if (set == Set.BROWSER) browser else life
        val items = ArrayList<Item>(140)
        repeat(5000) {
            if (items.size < 140) {
                val isBig = next() < .62
                val size = if (isBig) 8.5 + next() * 5.5 else 3.6 + next() * 2.6
                val x = next() * DRAWING_SIDE; val y = next() * DRAWING_SIDE
                if (items.all { other ->
                    val dx = min(abs(other.x - x), DRAWING_SIDE - abs(other.x - x))
                    val dy = min(abs(other.y - y), DRAWING_SIDE - abs(other.y - y))
                    val room = (other.size + size) * 1.15 + 5
                    dx * dx + dy * dy >= room * room
                }) {
                    val pool = if (isBig) big else small
                    val glyph = pool[min(pool.lastIndex, (next() * pool.size).toInt())]
                    items += Item(glyph, x, y, size, (next() - .5) * 1.1)
                }
            }
        }
        return items
    }

    /** Source copies crossing-edge drawings before clipping one seamless tile. */
    fun copies(item: Item): List<Item> = buildList {
        for (dx in listOf(-DRAWING_SIDE, 0.0, DRAWING_SIDE)) for (dy in listOf(-DRAWING_SIDE, 0.0, DRAWING_SIDE)) {
            val x = item.x + dx; val y = item.y + dy
            if (x > -item.size * 1.6 && x < DRAWING_SIDE + item.size * 1.6 &&
                y > -item.size * 1.6 && y < DRAWING_SIDE + item.size * 1.6) add(item.copy(x = x, y = y))
        }
    }

    /** CGPath angles use increasing radians for clockwise=false, in the source's y-down boxes. */
    fun arcSweep(arc: Part.Arc): Double {
        var sweep = arc.end - arc.start
        if (arc.clockwise) { while (sweep > 0) sweep -= 2 * PI; while (sweep < -2 * PI) sweep += 2 * PI }
        else { while (sweep < 0) sweep += 2 * PI; while (sweep > 2 * PI) sweep -= 2 * PI }
        return sweep
    }

    fun path(glyph: Glyph): List<Part> = buildList {
        fun line(vararg coordinates: Double, closed: Boolean = false) {
            add(Part.Move(coordinates[0], coordinates[1]))
            for (i in 2 until coordinates.size step 2) add(Part.Line(coordinates[i], coordinates[i + 1]))
            if (closed) add(Part.Close)
        }
        fun circle(x: Double, y: Double, radius: Double) = add(Part.Oval(x - radius, y - radius, radius * 2, radius * 2))
        when (glyph) {
            Glyph.GLOBE -> { circle(0.0, 0.0, 1.0); add(Part.Oval(-.45, -1.0, .9, 2.0)); line(-1.0, 0.0, 1.0, 0.0) }
            Glyph.CURSOR -> line(-.55, -1.0, -.55, .6, -.18, .25, .15, .95, .42, .83, .1, .15, .55, .12, closed = true)
            Glyph.MAIL -> { add(Part.Box(-1.0, -.65, 2.0, 1.3, .18)); line(-.95, -.55, 0.0, .12, .95, -.55) }
            Glyph.BOOKMARK -> line(-.55, -1.0, .55, -1.0, .55, 1.0, 0.0, .55, -.55, 1.0, closed = true)
            Glyph.KEY -> { circle(-.5, 0.0, .42); line(-.08, 0.0, 1.0, 0.0); line(.68, 0.0, .68, .35); line(.92, 0.0, .92, .28) }
            Glyph.LOCK -> {
                add(Part.Box(-.7, -.1, 1.4, 1.05, .2)); add(Part.Move(-.45, -.1)); add(Part.Line(-.45, -.4))
                add(Part.Arc(0.0, -.4, .45, PI, 0.0)); add(Part.Line(.45, -.1))
            }
            Glyph.SEARCH -> { circle(-.2, -.2, .6); line(.23, .23, .95, .95) }
            Glyph.COMMAND -> {
                val o = .38; val r = .3; val c = o + r * .62
                add(Part.Box(-o, -o, o * 2, o * 2))
                for ((u, v) in listOf(-1.0 to -1.0, 1.0 to -1.0, 1.0 to 1.0, -1.0 to 1.0)) circle(u * c, v * c, r)
            }
            Glyph.TAB -> line(-1.0, .55, -.6, .55, -.6, -.4, -.4, -.55, .4, -.55, .6, -.4, .6, .55, 1.0, .55)
            Glyph.DOWNLOAD -> { line(0.0, -1.0, 0.0, .35); line(-.45, -.1, 0.0, .35, .45, -.1); line(-.9, .5, -.9, .9, .9, .9, .9, .5) }
            Glyph.PUZZLE -> {
                add(Part.Move(-.8, -.8)); add(Part.Line(-.2, -.8)); add(Part.Arc(0.0, -.8, .2, PI, 0.0))
                add(Part.Line(.8, -.8)); add(Part.Line(.8, -.2)); add(Part.Arc(.8, 0.0, .2, -PI / 2, PI / 2))
                add(Part.Line(.8, .8)); add(Part.Line(-.8, .8)); add(Part.Close)
            }
            Glyph.COMPASS -> { circle(0.0, 0.0, 1.0); line(0.0, -.7, .22, 0.0, 0.0, .7, -.22, 0.0, closed = true) }
            Glyph.BOLT -> line(.15, -1.0, -.55, .12, -.02, .12, -.18, 1.0, .6, -.22, .06, -.22, closed = true)
            Glyph.PENCIL -> line(-.9, .9, -.75, .45, .6, -.9, .9, -.6, -.45, .75, closed = true)
            Glyph.STAR -> {
                repeat(10) { i ->
                    val r = if (i % 2 == 1) .42 else 1.0; val angle = -PI / 2 + i * PI / 5
                    add(if (i == 0) Part.Move(cos(angle) * r, sin(angle) * r) else Part.Line(cos(angle) * r, sin(angle) * r))
                }; add(Part.Close)
            }
            Glyph.CUP -> {
                line(-.65, -.1, -.55, .85, .45, .85, .55, -.1, closed = true)
                add(Part.Move(.52, .1)); add(Part.Arc(.68, .35, .25, -PI / 2, PI / 2))
                add(Part.Move(-.3, -.35)); add(Part.Cubic(-.45, -.55, -.15, -.7, -.3, -.95))
            }
            Glyph.HEART -> {
                add(Part.Move(0.0, .85)); add(Part.Cubic(-1.2, 0.0, -.7, -1.0, 0.0, -.4))
                add(Part.Cubic(.7, -1.0, 1.2, 0.0, 0.0, .85))
            }
            Glyph.CAT -> {
                add(Part.Move(-.8, -.2)); add(Part.Line(-.75, -.95)); add(Part.Line(-.3, -.55)); add(Part.Quad(0.0, -.65, .3, -.55))
                add(Part.Line(.75, -.95)); add(Part.Line(.8, -.2)); add(Part.Cubic(.95, .6, .4, .85, 0.0, .85))
                add(Part.Cubic(-.4, .85, -.95, .6, -.8, -.2)); line(-.35, .3, -1.05, .2); line(.35, .3, 1.05, .2)
            }
            Glyph.MOON -> {
                add(Part.Arc(0.0, 0.0, .9, PI * .35, PI * 1.65))
                add(Part.Arc(.45, -.05, .72, PI * 1.45, PI * .55, clockwise = true)); add(Part.Close)
            }
            Glyph.NOTE -> { add(Part.Oval(-.72, .41, .64, .48)); line(-.1, .6, -.1, -1.0); add(Part.Quad(.3, -.6, .55, -.55)) }
            Glyph.PLANET -> { circle(0.0, 0.0, .55); add(Part.Oval(-1.05, -.3, 2.1, .6, -.35)) }
            Glyph.CLOUD -> {
                add(Part.Move(-.55, .55)); add(Part.Arc(-.5, .15, .4, PI * .5, PI * 1.5))
                add(Part.Arc(0.0, -.15, .5, PI * 1.15, PI * 1.9)); add(Part.Arc(.55, .15, .4, PI * 1.5, PI * .5)); add(Part.Close)
            }
            Glyph.PLANE -> { line(-1.0, -.05, 1.0, -.8, .35, .9, .02, .18, closed = true); line(.02, .18, 1.0, -.8) }
            Glyph.SPARKLE -> {
                add(Part.Move(0.0, -1.0)); add(Part.Quad(.12, -.12, 1.0, 0.0)); add(Part.Quad(.12, .12, 0.0, 1.0))
                add(Part.Quad(-.12, .12, -1.0, 0.0)); add(Part.Quad(-.12, -.12, 0.0, -1.0))
            }
            Glyph.PLAY -> { add(Part.Box(-1.0, -.68, 2.0, 1.36, .38)); line(-.25, -.35, .4, 0.0, -.25, .35, closed = true) }
            Glyph.SQUIGGLE -> repeat(17) { i ->
                val t = i / 16.0; val x = -1 + t * 2; val y = sin(t * PI * 3) * .32
                add(if (i == 0) Part.Move(x, y) else Part.Line(x, y))
            }
            Glyph.PLUS -> { line(-.6, 0.0, .6, 0.0); line(0.0, -.6, 0.0, .6) }
        }
    }
}
