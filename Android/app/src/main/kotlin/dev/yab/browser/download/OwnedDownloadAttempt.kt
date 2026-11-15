package dev.yab.browser.download

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** Authority comes from a native held-image action, never from an extension message or URL. */
data class OwnedDownloadSource(
    val tab: String,
    val profile: String,
    val document: String,
    val privateOrigin: Boolean,
    val account: String?,
    val accountEpoch: Long,
)

data class OwnedDownloadFrame(
    val bridge: String,
    val document: String,
    val tab: Long,
    val frame: Long,
    val cookieStore: String,
    val privateOrigin: Boolean,
)

data class OwnedDownloadRequest(
    val id: String,
    val url: String,
    val method: String,
    val type: String,
    val tab: Long,
    val frame: Long,
    val parentFrame: Long,
    val parentDocument: String,
    val cookieStore: String,
    val privateOrigin: Boolean,
)

/** Main-thread state machine. The runtime additionally binds this to exact native port/session objects. */
class OwnedDownloadAttempt(
    val token: String,
    val stamp: String,
    val source: OwnedDownloadSource,
    image: String,
    val deadline: Long,
) {
    enum class Phase { ARMED, PREPARED, BOUND, REQUESTED, STAMPED, DELIVERED, CLOSED }
    val target = requireNotNull(resourceUrl(image)) { "Only an HTTP(S) image can be saved" }
    var phase = Phase.ARMED; private set
    var frame: OwnedDownloadFrame? = null; private set
    var request: OwnedDownloadRequest? = null; private set
    private var prepared: Pair<String, Long>? = null

    init {
        require(token.matches(TOKEN) && stamp.matches(TOKEN) && token != stamp)
        require(source.tab.isNotBlank() && source.profile.isNotBlank() && source.document.isNotBlank())
    }

    fun current(now: Long, currentSource: OwnedDownloadSource): Boolean = phase != Phase.CLOSED && source == currentSource &&
        (phase == Phase.DELIVERED || now in 0..deadline)

    fun prepare(bridge: String, child: Long, now: Long, currentSource: OwnedDownloadSource): Boolean {
        if (phase != Phase.ARMED || !current(now, currentSource) || !bridge.matches(TOKEN) || child <= 0) return false
        prepared = bridge to child; phase = Phase.PREPARED; return true
    }

    fun bind(value: OwnedDownloadFrame, now: Long, currentSource: OwnedDownloadSource): Boolean {
        if (phase != Phase.PREPARED || !current(now, currentSource) || prepared != (value.bridge to value.frame) ||
            value.tab < 0 || !value.document.matches(TOKEN) || value.cookieStore != GeckoImageCookieStores.tab(source.profile, source.privateOrigin) ||
            value.privateOrigin != source.privateOrigin) return false
        frame = value; phase = Phase.BOUND; return true
    }

    fun claim(value: OwnedDownloadRequest, now: Long, currentSource: OwnedDownloadSource): Boolean {
        val bound = frame ?: return false
        if (phase != Phase.BOUND || !current(now, currentSource) || value.id.length !in 1..128 || value.method != "GET" ||
            value.type != "sub_frame" || resourceUrl(value.url) != target || value.tab != bound.tab || value.frame != bound.frame ||
            value.parentFrame != 0L || value.parentDocument != bound.document || value.cookieStore != GeckoImageCookieStores.request(source.privateOrigin) ||
            value.privateOrigin != bound.privateOrigin) return false
        request = value; phase = Phase.REQUESTED; return true
    }

    /** Redirects, unknown methods and non-image responses are deliberately unsupported in this first path. */
    fun stamp(id: String, url: String, status: Int, mime: String, now: Long, currentSource: OwnedDownloadSource): Boolean {
        if (phase != Phase.REQUESTED || !current(now, currentSource) || request?.id != id || resourceUrl(url) != target ||
            status != 200 || !isImageMime(mime)) return false
        phase = Phase.STAMPED; return true
    }

    fun deliver(value: String, url: String, redirected: Boolean, now: Long, currentSource: OwnedDownloadSource): Boolean {
        if (phase != Phase.STAMPED || !current(now, currentSource) || value != stamp || resourceUrl(url) != target || redirected) return false
        phase = Phase.DELIVERED; return true
    }

    fun close() { phase = Phase.CLOSED }

    companion object {
        val TOKEN = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
        private val IMAGE_MIME = Regex("image/[A-Za-z0-9!#$&^_.+-]+", RegexOption.IGNORE_CASE)
        const val RESPONSE_STAMP = "x-yab-owned-image"
        fun isImageMime(value: String): Boolean = value.substringBefore(';').trim().matches(IMAGE_MIME)
        fun resourceUrl(value: String): String? {
            if (value.length !in 1..16_384) return null
            val parsed = value.toHttpUrlOrNull() ?: return null
            if (parsed.username.isNotEmpty() || parsed.password.isNotEmpty()) return null
            return parsed.newBuilder().fragment(null).build().toString()
        }
    }
}
