package dev.yab.android

import java.net.URI
import java.util.UUID

/** External entrances only select a surface. They never authorize a remote action. */
sealed interface IncomingAction {
    data class Page(val url: String) : IncomingAction
    data class SharedPage(val url: String) : IncomingAction
    data class Search(val words: String) : IncomingAction
    data class Join(val code: String) : IncomingAction
    data class Review(val id: String) : IncomingAction
    data class Task(val id: String) : IncomingAction
    data class Now(val address: String) : IncomingAction
    data object NewTab : IncomingAction
    data object Ask : IncomingAction
    data object Private : IncomingAction
    data object Scan : IncomingAction

    companion object {
        fun parse(address: String): IncomingAction? = runCatching {
            if (address.length > 16_384) return null
            val uri = URI(address.trim())
            when (uri.scheme?.lowercase()) {
                "http", "https" -> if (!uri.host.isNullOrBlank() && uri.rawUserInfo == null) Page(uri.toASCIIString()) else null
                "yab-open" -> {
                    val inner = uri.schemeSpecificPart.removePrefix("//")
                    if (inner.startsWith("http://", true) || inner.startsWith("https://", true)) parse(inner)
                    else if (inner.isNotBlank() && runCatching { URI(inner).scheme == null }.getOrDefault(true)) Search(inner) else null
                }
                "yab" -> when (uri.host?.lowercase()) {
                    "new" -> NewTab
                    "ask" -> Ask
                    "private" -> Private
                    "scan" -> Scan
                    "now" -> Now(uri.toASCIIString())
                    "join" -> uri.path.removePrefix("/").takeIf { it.length in 4..32 && it.all { char -> char.isLetterOrDigit() || char == '-' } }?.let(::Join)
                    "approval", "task" -> uri.path.removePrefix("/").takeIf { UUID.fromString(it).toString().equals(it, true) }?.let { if (uri.host == "task") Task(it) else Review(it) }
                    else -> null
                }
                else -> null
            }
        }.getOrNull()

        fun shared(text: String): IncomingAction? = text.trim().takeIf { it.isNotEmpty() && it.length <= 16_384 }?.let { words ->
            val pages = words.lineSequence().map(String::trim).mapNotNull { parse(it) as? Page }.distinct().take(2).toList()
            when {
                pages.size == 1 -> SharedPage(pages.single().url)
                words.contains("://") -> null
                else -> Search(words)
            }
        }
    }
}
