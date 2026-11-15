package dev.yab.browser.icons

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.BrowserTab
import java.io.File
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray

/** Only public same-origin, cookie-free RAM images are eligible for network/cache use. */
internal class AndroidSiteIcons(context: Context, private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    accepts: (SiteIconOrigin) -> Boolean = { true }) {
    private val assets = context.applicationContext.assets
    private val http = SiteIconHttp()
    /** In the cache folder, so a site whose icon only its page declares keeps it across launches. */
    private val keptFolder = File(context.applicationContext.cacheDir, "SiteIcons")
        .takeIf { SiteIconOrigin.from("https://example.com")?.let(accepts) == true }
    private val repository = SiteIconRepository(scope, { address, origin -> if (accepts(origin)) http.fetch(address, origin) else null }, ::decode,
        weight = { it.allocationByteCount },
        discover = { origin -> if (accepts(origin)) http.home(origin)?.let(origin::declaredIcons).orEmpty() else emptyList() },
        keep = ::keep)
    private val restored = AtomicBoolean(false)
    internal val pictures: StateFlow<Map<SiteIconOrigin, Bitmap>> get() = repository.pictures
    private val bundles = mutableMapOf<String, Bitmap?>()
    private val rasters = TabIconRenderCache<Bitmap>()
    private val hostKeys: Map<String, String> by lazy {
        val contents = assets.open("favicons/favicons.json").bufferedReader().use { it.readText() }
        val entries = JSONArray(contents)
        buildMap { repeat(entries.length()) { i ->
            val entry = entries.getJSONObject(i); putIfAbsent(entry.getString("host"), entry.getString("key"))
        } }
    }
    private val keyHosts by lazy { hostKeys.entries.associate { it.value to it.key } }

    suspend fun load(page: String, declared: String? = null, isPrivate: Boolean): Boolean = repository.load(page, declared, isPrivate)
    internal fun read(page: String, declared: String?, isPrivate: Boolean) {
        if (isPrivate) return
        scope.launch { repository.load(page, declared, false) }
    }

    /** Selected-space loading never visits tabs and never opens a Private URL. */
    suspend fun prefetch(space: BrowserSpace): Unit = coroutineScope {
        if (space.isPrivate) return@coroutineScope
        val pages = space.tabs.asSequence().filterNot { it.isPrivate || it.isBlank || it.url.startsWith("mailto:", true) }
            .mapNotNull { tab -> SiteIconOrigin.from(tab.url)?.let { it to tab.url } }.distinctBy { it.first }.map { it.second }.take(256).toList()
        // Four workers bound queued work as well as simultaneous requests.
        (0 until minOf(4, pages.size)).map { worker -> async {
            var index = worker
            while (index < pages.size) { repository.load(pages[index], null, false); index += 4 }
        } }.awaitAll()
        Unit
    }
    suspend fun removeAll() {
        repository.removeAll(); synchronized(rasters) { rasters.clear() }
        withContext(Dispatchers.IO) { keptFolder?.deleteRecursively() }
    }

    private fun keptFile(origin: SiteIconOrigin) = keptFolder?.let { File(it, URLEncoder.encode(origin.address, "UTF-8")) }
    private fun keep(origin: SiteIconOrigin, bytes: ByteArray) {
        val file = keptFile(origin) ?: return
        scope.launch(Dispatchers.IO) { runCatching {
            file.parentFile?.mkdirs()
            val written = File.createTempFile("icon", null, file.parentFile)
            written.writeBytes(bytes)
            if (!written.renameTo(file)) written.delete()
        } }
    }

    /** Icons from earlier launches, read once as the app starts. */
    suspend fun restoreKept() {
        if (!restored.compareAndSet(false, true)) return
        val kept = withContext(Dispatchers.IO) { buildMap {
            keptFolder?.listFiles().orEmpty().filter { it.length() <= 1_048_576 }.take(256).forEach { file ->
                val origin = runCatching { SiteIconOrigin.from(URLDecoder.decode(file.name, "UTF-8")) }.getOrNull() ?: return@forEach
                decode(file.readBytes())?.let { put(origin, it) }
            }
        } }
        repository.restore(kept)
    }

    internal fun key(tab: BrowserTab): String {
        if (tab.url.startsWith("mailto:", true)) return "mail"
        // PageFixtures.liveTab and non-fixture SyncMapping use the real host as
        // icon identity. A live github.com must not inherit fixture-only "github"
        // roundness, and orbit.com must not become the prototype's purple tile.
        return SiteIconOrigin.from(tab.url)?.host ?: if (tab.isBlank) "globe" else tab.host.lowercase(Locale.ROOT).ifEmpty { "globe" }
    }
    internal fun render(tab: BrowserTab, sizeDp: Float, density: Float, dark: Boolean, privateSpace: Boolean): Bitmap {
        require(sizeDp.isFinite() && sizeDp > 0 && sizeDp <= 128 && density.isFinite() && density > 0)
        val key = key(tab)
        val privateContent = privateSpace || tab.isPrivate
        val source = image(tab, privateSpace)
        val pixels = (sizeDp * density).roundToInt().coerceIn(1, 512)
        val cacheKey = "$key|${sourceHost(tab)}|$privateContent|$sizeDp|$density|$dark|$pixels"
        return synchronized(rasters) { rasters.image(cacheKey, source) { draw(key, source, sizeDp, pixels, density, dark) } }
    }
    internal fun image(tab: BrowserTab, privateSpace: Boolean): Bitmap? =
        repository.image(tab.url, privateSpace || tab.isPrivate) ?: bundled(key(tab), sourceHost(tab))
    private fun sourceHost(tab: BrowserTab) = SiteIconOrigin.from(tab.url)?.host ?: tab.host
    internal val rasterCount get() = synchronized(rasters) { rasters.renders }
    private fun bundled(key: String, host: String): Bitmap? = synchronized(bundles) {
        val cacheKey = "$key|$host"
        if (bundles.containsKey(cacheKey)) return@synchronized bundles[cacheKey]
        val names = listOfNotNull(keyHosts[key], key, host).filter(String::isNotEmpty)
        val image = names.firstNotNullOfOrNull { name ->
            if (!name.matches(Regex("[A-Za-z0-9._-]{1,253}"))) null
            else listOf("png", "webp", "jpg").firstNotNullOfOrNull { extension ->
                runCatching { assets.open("favicons/$name.$extension").use { decode(it.readBytes()) } }.getOrNull()
            }
        }
        if (bundles.size >= 256) bundles.clear()
        bundles[cacheKey] = image
        image
    }
    private fun draw(key: String, image: Bitmap?, sizeDp: Float, side: Int, density: Float, dark: Boolean): Bitmap {
        val result = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(result); val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        val rect = RectF(0f, 0f, side.toFloat(), side.toFloat())
        val radius = if (image != null && key in setOf("github", "lumen", "nordbutik", "google")) side / 2f else side * .23f
        canvas.clipPath(Path().apply { addRoundRect(rect, radius, radius, Path.Direction.CW) })
        if (key == "mail") {
            paint.color = Color.rgb(142, 142, 147); paint.style = Paint.Style.STROKE; paint.strokeWidth = side / 12f
            val margin = side * .12f
            canvas.drawRoundRect(RectF(margin, side * .23f, side - margin, side * .77f), side * .07f, side * .07f, paint)
            canvas.drawPath(Path().apply { moveTo(margin, side * .26f); lineTo(side * .5f, side * .54f); lineTo(side - margin, side * .26f) }, paint)
        } else if (key == "face") {
            paint.color = if (dark) Color.WHITE else Color.BLACK; paint.style = Paint.Style.STROKE; paint.strokeWidth = side / 12f; paint.strokeCap = Paint.Cap.ROUND
            canvas.drawCircle(side * .5f, side * .5f, side * .375f, paint)
            for (x in listOf(9.5f, 14.5f)) canvas.drawLine(side * x / 24, side * 9.75f / 24, side * x / 24, side * 12.25f / 24, paint)
        } else if (image != null) {
            if (dark && darkMark(image)) { paint.color = Color.WHITE; canvas.drawRect(rect, paint) }
            val scale = max(side.toFloat() / image.width, side.toFloat() / image.height)
            val w = image.width * scale; val h = image.height * scale
            canvas.drawBitmap(image, null, RectF((side - w) / 2, (side - h) / 2, (side + w) / 2, (side + h) / 2), paint)
        } else {
            val tile = tiles[key] ?: (0xFF8E8E93.toInt() to key.take(1).uppercase(Locale.ROOT))
            paint.color = tile.first; canvas.drawRect(rect, paint)
            if (tile.first == Color.WHITE) {
                paint.color = 0x1F000000; paint.style = Paint.Style.STROKE; paint.strokeWidth = density
                canvas.drawRoundRect(RectF(density / 2, density / 2, side - density / 2, side - density / 2), radius, radius, paint)
                paint.style = Paint.Style.FILL
            }
            paint.color = if (tile.first == Color.WHITE) 0xFF111111.toInt() else Color.WHITE
            paint.typeface = Typeface.create("sans-serif", Typeface.BOLD); paint.textAlign = Paint.Align.CENTER
            paint.textSize = (sizeDp * .5f).roundToInt() * density
            val width = paint.measureText(tile.second)
            if (width > side * .9f) paint.textSize *= max(.5f, side * .9f / width)
            canvas.drawText(tile.second, side / 2f, side / 2f - (paint.fontMetrics.ascent + paint.fontMetrics.descent) / 2, paint)
        }
        return result
    }
    private fun darkMark(image: Bitmap): Boolean {
        val sample = Bitmap.createBitmap(12, 12, Bitmap.Config.ARGB_8888)
        Canvas(sample).drawBitmap(image, null, RectF(0f, 0f, 12f, 12f), Paint(Paint.FILTER_BITMAP_FLAG))
        var clear = 0; var shown = 0.0; var light = 0.0
        repeat(12) { y -> repeat(12) { x ->
            val color = sample.getPixel(x, y); val alpha = Color.alpha(color) / 255.0
            if (alpha < .1) clear++ else {
                shown += alpha
                light += alpha * (.299 * Color.red(color) + .587 * Color.green(color) + .114 * Color.blue(color)) / 255
            }
        } }
        sample.recycle()
        return clear >= 18 && shown > 0 && light / shown < .25
    }
    companion object {
        @Volatile private var shared: AndroidSiteIcons? = null
        internal fun get(context: Context): AndroidSiteIcons = shared ?: synchronized(this) {
            shared ?: AndroidSiteIcons(context.applicationContext).also { shared = it }
        }
        private val tiles = mapOf("orbit" to (0xFF5B47E0.toInt() to "O"), "paul" to (0xFFB31B1B.toInt() to "PG"),
            "rams" to (Color.WHITE to "W"), "nng" to (0xFF1B1B1B.toInt() to "N"), "tap" to (0xFFE2001A.toInt() to "T"),
            "linnea" to (0xFF8C6E4E.toInt() to "L"), "skandi" to (0xFF2F4A3A.toInt() to "S"), "llm" to (0xFFFF0033.toInt() to ""))
        internal fun decode(bytes: ByteArray): Bitmap? {
            if (bytes.isEmpty() || bytes.size > 1_048_576) return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            if (runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds) }.isFailure) return null
            if (bounds.outWidth !in 1..16_384 || bounds.outHeight !in 1..16_384) return null
            var sample = 1
            while (max(bounds.outWidth, bounds.outHeight) / sample > 256) sample *= 2
            return runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
                BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888 }) }.getOrNull()
        }
    }
}
