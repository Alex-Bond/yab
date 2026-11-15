package dev.yab.browser.engine

import java.net.URI

internal fun linkPreviewWebUrl(value: String): Boolean = runCatching {
    URI(value).let { it.scheme?.lowercase() in setOf("http", "https") && !it.host.isNullOrBlank() && it.rawUserInfo == null }
}.getOrDefault(false)

/** A revoked lease never becomes usable again, even if the same account or tab returns. */
internal class LinkPreviewLease(private val sourceCurrent: () -> Boolean) {
    private var live = true
    fun current(): Boolean {
        if (live && !sourceCurrent()) live = false
        return live
    }
    fun consume(): Boolean = current().also { live = false }
    fun close() { live = false }
}
