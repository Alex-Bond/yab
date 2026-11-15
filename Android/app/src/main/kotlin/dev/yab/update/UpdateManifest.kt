package dev.yab.update

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** One version the site offers. Every field has passed [UpdateManifest.parse]. */
@Serializable
data class UpdateOffer(val versionCode: Int, val versionName: String, val url: String, val sha256: String, val minSdk: Int)

/**
 * Where offers come from. The offer's own `url` must stand on [host]. The site's APK address is a
 * redirect to Blob storage, so a hop may also land on [redirectHostSuffix]; the SHA-256 and
 * Android's signature check decide whether those bytes are used.
 */
data class UpdateEndpoint(val manifestUrl: String, val host: String, val port: Int, val cleartext: Boolean = false,
    val redirectHostSuffix: String? = null) {
    private fun sameOrigin(url: HttpUrl) = url.host == host && url.port == port
    private fun secureEnough(url: HttpUrl) = (url.isHttps || cleartext) && url.username.isEmpty() && url.password.isEmpty()
    fun allowsDownload(url: HttpUrl) = secureEnough(url) && sameOrigin(url)
    fun allowsRedirect(url: HttpUrl) = secureEnough(url) &&
        (sameOrigin(url) || redirectHostSuffix != null && url.isHttps && url.host.endsWith(redirectHostSuffix))
}

object UpdateManifest {
    const val MAX_BYTES = 16 * 1024L
    private val sha256 = Regex("[0-9a-f]{64}")
    private val versionName = Regex("[0-9A-Za-z][0-9A-Za-z.+-]{0,63}")
    private val json = Json { isLenient = false }

    /** Null for anything that is not exactly the published shape, wrong types included. New keys are ignored. */
    fun parse(text: String, endpoint: UpdateEndpoint): UpdateOffer? {
        if (text.length > MAX_BYTES) return null
        val root = runCatching { json.parseToJsonElement(text) }.getOrNull() as? JsonObject ?: return null
        val offer = UpdateOffer(number(root, "versionCode") ?: return null, string(root, "versionName") ?: return null,
            string(root, "url") ?: return null, string(root, "sha256") ?: return null, number(root, "minSdk") ?: return null)
        val url = offer.url.toHttpUrlOrNull() ?: return null
        val valid = offer.versionCode > 0 && offer.minSdk in 1..1000 && versionName.matches(offer.versionName) &&
            sha256.matches(offer.sha256) && endpoint.allowsDownload(url)
        return offer.takeIf { valid }
    }

    private fun number(root: JsonObject, key: String) = (root[key] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
    private fun string(root: JsonObject, key: String) = (root[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
}

/** Which builds update themselves. Only the owner-signed release does; a debug build needs a local fixture. */
object UpdateChannel {
    const val PACKAGE = "dev.yab.android"
    const val OWNER_CERTIFICATE = "59ae46a10f4b2e1ff3b2ffd8de63b82cbe603efda34a3195f537fafaaba33ada"
    val PRODUCTION = UpdateEndpoint("https://yetanotherbrowser.com/android/latest.json", "yetanotherbrowser.com", 443,
        redirectHostSuffix = ".public.blob.vercel-storage.com")
    private val localHosts = setOf("10.0.2.2", "127.0.0.1", "localhost")

    fun resolve(debug: Boolean, packageName: String, certificates: List<String>, debugBase: String?): UpdateEndpoint? = when {
        debug -> debugBase?.let(::local)
        packageName == PACKAGE && OWNER_CERTIFICATE in certificates -> PRODUCTION
        else -> null
    }

    fun local(base: String): UpdateEndpoint? {
        val url = base.toHttpUrlOrNull()?.takeIf { it.host in localHosts } ?: return null
        return UpdateEndpoint(url.newBuilder().encodedPath("/android/latest.json").build().toString(), url.host, url.port, cleartext = true)
    }
}
