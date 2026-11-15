package dev.yab.browser.icons

import java.net.URI
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** Public icon authority includes scheme and effective port, never just a hostname. */
internal data class SiteIconOrigin private constructor(val scheme: String, val host: String, val port: Int) {
    val address: String get() {
        val name = if (':' in host) "[$host]" else host
        val suffix = if (scheme == "http" && port == 80 || scheme == "https" && port == 443) "" else ":$port"
        return "$scheme://$name$suffix"
    }
    val fallback get() = "$address/favicon.ico"
    companion object {
        fun from(value: String?): SiteIconOrigin? {
            if (value == null || value.length > 4096) return null
            val raw = runCatching { URI(value) }.getOrNull() ?: return null
            if (!raw.isAbsolute || raw.rawAuthority == null || raw.rawUserInfo != null) return null
            val url = value.toHttpUrlOrNull() ?: return null
            if (url.username.isNotEmpty() || url.password.isNotEmpty()) return null
            return SiteIconOrigin(url.scheme, url.host, url.port)
        }
    }
    /** An icon may live on the site's www host or a CDN: https only, no cookies are ever sent. */
    fun reaches(address: String?): Boolean = from(address)?.let { it == this || it.scheme == "https" } == true
    fun candidates(declared: String?): List<String> {
        val accepted = declared?.takeIf(::reaches)?.toHttpUrlOrNull()?.toString()
        return if (accepted == null || accepted == fallback) listOf(fallback) else listOf(accepted, fallback)
    }

    /** The icons a page's HTML names, the large touch icon first; SVG doesn't draw here. */
    fun declaredIcons(html: String): List<String> {
        val base = address.toHttpUrlOrNull() ?: return emptyList()
        val touch = mutableListOf<String>()
        val plain = mutableListOf<String>()
        for (link in LINK.findAll(html)) {
            val kind = REL.find(link.value)?.groupValues?.get(1)?.lowercase() ?: continue
            if ("icon" !in kind) continue
            val href = HREF.find(link.value)?.groupValues?.get(1)?.replace("&amp;", "&") ?: continue
            if (".svg" in href.lowercase()) continue
            val url = base.resolve(href)?.takeIf { it.isHttps }?.toString() ?: continue
            if ("apple-touch" in kind) touch += url else plain += url
        }
        return (touch + plain).take(4)
    }
}

private val LINK = Regex("<link\\b[^>]*>", RegexOption.IGNORE_CASE)
private val REL = Regex("rel\\s*=\\s*[\"']?([^\"'>]*)", RegexOption.IGNORE_CASE)
private val HREF = Regex("href\\s*=\\s*[\"']?([^\"'\\s>]+)", RegexOption.IGNORE_CASE)
