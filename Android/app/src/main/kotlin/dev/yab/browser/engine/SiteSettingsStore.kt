package dev.yab.browser.engine

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Locale
import java.util.UUID
import kotlin.math.roundToInt
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable enum class SitePermission { CAMERA, MICROPHONE }
@Serializable enum class SiteDecision { ASK, ALLOWED, OFF }

@Serializable
data class SitePreferences(
    val zoom: Double = 1.0,
    val desktop: Boolean = false,
    val permissions: Map<SitePermission, SiteDecision> = emptyMap(),
) {
    val empty: Boolean get() = kotlin.math.abs(zoom - 1) < 0.001 && !desktop && permissions.isEmpty()
}

data class SiteSettingsState(
    val sites: Map<String, SitePreferences> = emptyMap(),
    val privateSites: Map<String, SitePreferences> = emptyMap(),
    val error: String? = null,
)

/** Public host settings persist; Private neither reads nor writes that map. No executor is created. */
class SiteSettingsStore(private val file: File? = null, private val write: (() -> Unit) -> Unit = { it() }) {
    @Serializable private data class Disk(val schema: Int = 1, val sites: Map<String, SitePreferences> = emptyMap())
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val mutable = MutableStateFlow(load())
    val state = mutable.asStateFlow()

    fun site(host: String?, isPrivate: Boolean): SitePreferences = key(host)?.let {
        (if (isPrivate) mutable.value.privateSites else mutable.value.sites)[it]
    } ?: SitePreferences()

    fun setZoom(host: String?, isPrivate: Boolean, zoom: Double) {
        if (!zoom.isFinite()) return
        edit(host, isPrivate) { it.copy(zoom = zoom.coerceIn(zoomSteps.first(), zoomSteps.last())) }
    }
    fun setDesktop(host: String?, isPrivate: Boolean, desktop: Boolean) = edit(host, isPrivate) { it.copy(desktop = desktop) }
    fun setDecision(host: String?, isPrivate: Boolean, kind: SitePermission, decision: SiteDecision) =
        edit(host, isPrivate) { it.copy(permissions = it.permissions + (kind to decision)) }
    fun forget(host: String?, isPrivate: Boolean, kind: SitePermission) =
        edit(host, isPrivate) { it.copy(permissions = it.permissions - kind) }
    fun clear(host: String?, isPrivate: Boolean) = edit(host, isPrivate) { SitePreferences() }
    fun forgetPrivate() { mutable.update { it.copy(privateSites = emptyMap()) } }
    suspend fun flush() {
        val finished = CompletableDeferred<Unit>()
        write { finished.complete(Unit) }
        finished.await()
    }

    /** First request is remembered as Ask. Only explicit Site Settings choices can auto-allow. */
    fun asked(host: String?, isPrivate: Boolean, kinds: Set<SitePermission>): SiteDecision {
        if (kinds.isEmpty() || key(host) == null) return SiteDecision.ASK
        val saved = site(host, isPrivate).permissions
        edit(host, isPrivate) { it.copy(permissions = kinds.associateWith { kind -> saved[kind] ?: SiteDecision.ASK } + saved) }
        return when {
            kinds.any { saved[it] == SiteDecision.OFF } -> SiteDecision.OFF
            kinds.all { saved[it] == SiteDecision.ALLOWED } -> SiteDecision.ALLOWED
            else -> SiteDecision.ASK
        }
    }

    private fun edit(host: String?, isPrivate: Boolean, change: (SitePreferences) -> SitePreferences) {
        val key = key(host) ?: return
        val before = mutable.value
        val sites = if (isPrivate) before.privateSites else before.sites
        val changed = change(sites[key] ?: SitePreferences())
        val next = if (changed.empty) sites - key else sites + (key to changed)
        if (next == sites) return
        if (next.size > MAX_SITES) { mutable.update { it.copy(error = "Too many remembered sites. Forget an unused site's settings.") }; return }
        mutable.value = if (isPrivate) before.copy(privateSites = next) else before.copy(sites = next)
        if (!isPrivate) persist(next)
    }
    private fun load(): SiteSettingsState {
        val source = file ?: return SiteSettingsState()
        if (!source.exists()) return SiteSettingsState()
        return try {
            require(source.length() <= MAX_BYTES)
            val disk = json.decodeFromString<Disk>(source.readText())
            require(disk.schema == 1 && disk.sites.size <= MAX_SITES)
            require(disk.sites.all { (host, site) -> key(host) == host && site.zoom.isFinite() && site.zoom in 0.5..3.0 })
            SiteSettingsState(disk.sites.filterValues { !it.empty })
        } catch (_: Exception) { SiteSettingsState(error = "Remembered site settings could not be read. Sites will ask again.") }
    }
    private fun persist(sites: Map<String, SitePreferences>) {
        val target = file ?: return
        try { write {
            val temporary = File(target.parentFile, "${target.name}.${UUID.randomUUID()}.next")
            try {
                target.parentFile?.mkdirs()
                val text = json.encodeToString(Disk(sites = sites))
                require(text.toByteArray(Charsets.UTF_8).size <= MAX_BYTES)
                temporary.outputStream().use { stream -> stream.write(text.toByteArray(Charsets.UTF_8)); stream.fd.sync() }
                Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
                mutable.update { it.copy(error = null) }
            } catch (_: Exception) { mutable.update { it.copy(error = "Site settings could not be saved. This change lasts until the app closes.") } }
            finally { temporary.delete() }
        } } catch (_: Exception) { mutable.update { it.copy(error = "Site settings could not be saved. This change lasts until the app closes.") } }
    }

    companion object {
        val zoomSteps = listOf(0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.75, 2.0, 2.5, 3.0)
        fun key(host: String?): String? = host?.lowercase(Locale.ROOT)?.removePrefix("www.")?.takeIf(String::isNotEmpty)
        fun step(zoom: Double, direction: Int): Double? = if (direction > 0) zoomSteps.firstOrNull { it > zoom + 0.001 }
            else zoomSteps.lastOrNull { it < zoom - 0.001 }
        fun percent(zoom: Double): Int = (zoom * 100).roundToInt()
        private const val MAX_SITES = 10_000
        private const val MAX_BYTES = 2 * 1024 * 1024
    }
}

/** Native TLS observations only. RAM includes Private and is dropped with its document. */
data class SiteConnection(
    val secure: Boolean,
    val exception: Boolean,
    val host: String,
    val origin: String?,
    val securityMode: Int,
    val mixedActive: Int,
    val mixedPassive: Int,
    val subject: String?,
    val issuer: String?,
    val validFrom: Long?,
    val validUntil: Long?,
    val sha256: String?,
)
