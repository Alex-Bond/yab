package dev.yab.browser.ui

import java.net.IDN
import java.net.URI
import kotlin.math.ceil

/** PlateLabel.address display policy. Never used as a navigation or storage URL. */
internal fun browserChromeAddress(url: String?): String {
    if (url == null || url == "about:blank") return "New Tab"
    val parsed = runCatching { URI(url) }.getOrNull() ?: return url
    var host = parsed.host
    var port = parsed.port.takeIf { it >= 0 }
    if (host == null) {
        // Canonical Unicode HTTP authorities can be valid while URI.host is null.
        val authority = parsed.rawAuthority?.substringAfterLast('@') ?: return url
        val separator = authority.lastIndexOf(':')
        val portText = authority.substringAfterLast(':', "")
        val explicitPort = portText.toIntOrNull()?.takeIf { it in 0..65535 }
        val rawHost = if (separator >= 0 && explicitPort != null) authority.substring(0, separator) else authority
        host = runCatching { IDN.toASCII(rawHost, IDN.USE_STD3_ASCII_RULES) }.getOrNull() ?: return url
        port = explicitPort
    }
    // Foundation URL.host() is the host itself; brackets delimit a URL authority.
    host = host.removeSurrounding("[", "]")
    if (host.startsWith("www.", ignoreCase = true)) host = host.drop(4)
    return host + (port?.let { ":$it" } ?: "")
}

/** HeadFadeLabel's scalar layout, kept separate from native font measurement. */
internal data class BrowserChromeLabelPose(val measured: Double, val width: Double, val density: Double) {
    init { require(measured.isFinite() && width.isFinite() && density.isFinite() && measured >= 0 && width >= 0 && density > 0) }
    val natural get() = ceil(measured / density) * density
    val overflow get() = natural > width + 0.5 * density
    val left get() = if (overflow) width - natural else (width - natural) / 2
    val fade get() = if (overflow) minOf(width, 26.0 * density) else 0.0
}
