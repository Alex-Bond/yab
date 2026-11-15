package dev.yab.browser.engine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Only public compositor snapshots enter the app-private cache. Never used for OS recents. */
data class TabThumbnail(val bitmap: Bitmap, val url: String, val profileId: String, val document: String)

class TabThumbnails(private val maximum: Int = 18, private val disk: PublicThumbnailDiskCache? = null,
    private val io: (() -> Unit) -> Unit = { it() }, private val main: (() -> Unit) -> Unit = { it() }) {
    private val recent = linkedMapOf<String, TabThumbnail>()
    private val mutable = MutableStateFlow<Map<String, TabThumbnail>>(emptyMap())
    val state: StateFlow<Map<String, TabThumbnail>> = mutable.asStateFlow()
    private var owners = emptyMap<String, ThumbnailOwner>()
    private val generations = mutableMapOf<String, Long>()
    private var generation = 0L
    private val attempted = mutableSetOf<String>()
    private var closed = false

    internal fun reconcile(current: List<ThumbnailOwner>) {
        if (closed) return
        val next = current.filterNot(ThumbnailOwner::isPrivate).associateBy(ThumbnailOwner::tab)
        if (owners == next) return
        (owners.keys + next.keys).filter { owners[it] != next[it] }.forEach { id ->
            generations[id] = ++generation; attempted.remove(id); recent.remove(id)
        }
        owners = next
        generations.keys.retainAll(next.keys); attempted.retainAll(next.keys)
        mutable.value = recent.toMap()
        io { runCatching { disk?.reconcile(next.values) } }
        // Restore a bounded decoded working set. The remaining public JPEGs stay on disk.
        current.filterNot(ThumbnailOwner::isPrivate).take(maximum).forEach(::load)
    }
    internal fun request(owner: ThumbnailOwner) {
        if (!closed && owners[owner.tab] == owner && !owner.isPrivate) load(owner)
    }
    private fun load(owner: ThumbnailOwner) {
        val cache = disk ?: return
        if (owner.tab in recent || !attempted.add(owner.tab)) return
        val generation = generations[owner.tab] ?: 0
        io {
            val stored = runCatching { cache.get(owner) }.getOrNull()
            val bitmap = stored?.let {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(it.jpeg, 0, it.jpeg.size, bounds)
                if (bounds.outWidth !in 1..360 || bounds.outHeight !in 1..640) null
                else BitmapFactory.decodeByteArray(it.jpeg, 0, it.jpeg.size)
            }
            main {
                if (bitmap != null && stored != null) {
                    if (closed || owners[owner.tab] != owner || (generations[owner.tab] ?: 0) != generation) bitmap.recycle()
                    else insert(owner.tab, TabThumbnail(bitmap, owner.url, owner.profile, stored.capture.document))
                }
            }
        }
    }

    internal fun put(id: String, bitmap: Bitmap, url: String, profileId: String, document: String, session: String) {
        put(id, bitmap, url, profileId, document, session, preserveSource = false)
    }
    /** Downscale a still-published history frame without recycling its renderer-owned source. */
    internal fun putFromPublished(id: String, bitmap: Bitmap, url: String, profileId: String, document: String, session: String): Boolean =
        put(id, bitmap, url, profileId, document, session, preserveSource = true)
    private fun put(id: String, bitmap: Bitmap, url: String, profileId: String, document: String, session: String, preserveSource: Boolean): Boolean {
        val owner = ThumbnailOwner(id, profileId, url)
        if (closed || owners[id] != owner || bitmap.width < 1 || bitmap.height < 1) { if (!preserveSource) bitmap.recycle(); return false }
        val scale = minOf(1.0, 360.0 / bitmap.width, 640.0 / bitmap.height)
        var small = Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).toInt().coerceAtLeast(1),
            (bitmap.height * scale).toInt().coerceAtLeast(1), true)
        if (small === bitmap) small = bitmap.copy(Bitmap.Config.ARGB_8888, false) ?: run {
            if (!preserveSource) bitmap.recycle()
            return false
        }
        if (small !== bitmap && !preserveSource) bitmap.recycle()
        val capture = ThumbnailCapture(owner, session, document)
        generations[id] = ++generation
        insert(id, TabThumbnail(small, url, profileId, document))
        // FIFO generation barriers are supplied by remove/reconcile on the same serial IO writer.
        io { runCatching { ByteArrayOutputStream().use { output ->
            if (small.compress(Bitmap.CompressFormat.JPEG, 76, output)) disk?.put(capture, output.toByteArray())
        } } }
        return true
    }
    private fun insert(id: String, thumbnail: TabThumbnail) {
        recent.remove(id)
        recent[id] = thumbnail
        while (recent.size > maximum) {
            val evicted = recent.keys.first()
            recent.remove(evicted); attempted.remove(evicted)
        }
        mutable.value = recent.toMap()
    }

    internal fun remove(id: String) {
        generations[id] = ++generation; attempted.add(id)
        if (recent.remove(id) != null) mutable.value = recent.toMap()
        io { runCatching { disk?.remove(id) } }
    }
    internal fun purgeProfiles(profiles: Set<String>) {
        owners.values.filter { it.profile in profiles }.forEach { remove(it.tab) }
        io { runCatching { disk?.purgeProfiles(profiles) } }
    }
    internal fun invalidateOwnership() {
        clear(); owners = emptyMap()
        io { runCatching { disk?.clear() } }
    }
    internal fun clear() {
        owners.keys.forEach { generations[it] = ++generation }
        attempted.clear(); recent.clear(); mutable.value = emptyMap()
    }
    /** Engine disposal drops pending callbacks while preserving valid public cache files. */
    internal fun close() { clear(); closed = true; owners = emptyMap(); generations.clear() }
}
