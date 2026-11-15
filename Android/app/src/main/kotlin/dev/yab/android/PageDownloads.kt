package dev.yab.android

import java.net.URI
import java.util.regex.Pattern

object DownloadNames {
    private val grapheme = Pattern.compile("\\X")

    fun filename(url: String, disposition: String?): String {
        val named = disposition?.let(::suggested)
        val path = runCatching { URI(url).path?.substringAfterLast('/') }.getOrNull()
        return sanitize(named ?: path ?: "download")
    }
    internal fun sanitize(given: String): String {
        val component = given.substringAfterLast('/').substringAfterLast('\\')
        val clean = buildString {
            var at = 0
            while (at < component.length) {
                val point = component.codePointAt(at); at += Character.charCount(point)
                if (!Character.isISOControl(point) && point !in 0xD800..0xDFFF && (point > 127 || point.toChar() !in ":*?<>|\"")) appendCodePoint(point)
            }
        }.trim()
        if (clean.isBlank() || clean == "." || clean == "..") return "download"
        val matcher = grapheme.matcher(clean)
        var at = 0; var count = 0; var bytes = 0
        while (count < 120 && matcher.find()) {
            val end = matcher.end()
            // Valid UTF-16 length is a lower bound on UTF-8 bytes. Reject a huge
            // cluster before allocating its encoding; never retain only its prefix.
            if (end - matcher.start() > 255 - bytes) break
            val next = clean.substring(matcher.start(), end).toByteArray(Charsets.UTF_8).size
            if (next > 255 - bytes) break
            bytes += next; count++; at = end
        }
        return clean.substring(0, at).ifEmpty { "download" }
    }
    private fun suggested(header: String): String? {
        val parts = mutableListOf<String>(); val current = StringBuilder(); var quoted = false; var escaped = false
        for (char in header) {
            if (char == ';' && !quoted) { parts += current.toString(); current.setLength(0) }
            else { current.append(char) }
            if (char == '"' && !escaped) quoted = !quoted
            escaped = char == '\\' && !escaped
        }
        if (quoted) return null
        parts += current.toString()
        val values = parts.drop(1).mapNotNull { part ->
            val split = part.indexOf('='); if (split < 0) return@mapNotNull null
            val key = part.substring(0, split).trim().lowercase(java.util.Locale.ROOT)
            if (key !in setOf("filename", "filename*")) return@mapNotNull null
            var value = part.substring(split + 1).trim()
            if (value.startsWith('"')) {
                if (!value.endsWith('"') || value.length < 2) return null
                value = value.substring(1, value.lastIndex).replace("\\\"", "\"").replace("\\\\", "\\")
            }
            key to value
        }
        val regular = values.filter { it.first == "filename" }; val extended = values.filter { it.first == "filename*" }
        if (regular.size > 1 || extended.size > 1) return null
        return extended.singleOrNull()?.second?.let(::extendedUtf8) ?: regular.singleOrNull()?.second
    }
    private fun extendedUtf8(value: String): String? = runCatching {
        val match = Regex("(?i)^UTF-8'[^']*'(.*)$").matchEntire(value) ?: return null
        val bytes = java.io.ByteArrayOutputStream()
        val encoded = match.groupValues[1]; var at = 0
        while (at < encoded.length) {
            val char = encoded[at++]
            if (char == '%') {
                require(at + 1 < encoded.length)
                val hex = encoded.substring(at, at + 2); require(hex.matches(Regex("[0-9a-fA-F]{2}")))
                val byte = hex.toInt(16); at += 2; bytes.write(byte)
            } else { require(char.isLetterOrDigit() && char.code < 128 || char in "!#$&+-.^_`|~"); bytes.write(char.code) }
        }
        Charsets.UTF_8.newDecoder().onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
            .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT).decode(java.nio.ByteBuffer.wrap(bytes.toByteArray())).toString()
    }.getOrNull()
}
