package dev.yab.nativefeatures

import java.io.File
import java.net.URI
import java.util.Locale
import com.google.mlkit.nl.translate.TranslateLanguage
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Android locales include regions/scripts; ML Kit needs its supported base code. */
internal fun translationLanguage(tag: String): String? = TranslateLanguage.fromLanguageTag(tag)
    ?: Locale.forLanguageTag(tag).toLanguageTag().substringBefore('-').let(TranslateLanguage::fromLanguageTag)

/** One source language per site. Private choices never enter the persisted map. */
interface TranslationRuleStore {
    fun source(host: String, privateOrigin: Boolean): String?
    fun setSource(host: String, privateOrigin: Boolean, source: String?)
}

fun translationHost(url: String): String? = runCatching {
    val parsed = URI(url)
    if (parsed.scheme?.lowercase(Locale.ROOT) !in setOf("http", "https")) null
    else parsed.host?.lowercase(Locale.ROOT)?.removePrefix("www.")?.takeIf(String::isNotBlank)
}.getOrNull()

open class MemoryTranslationRules : TranslationRuleStore {
    protected var publicRules = emptyMap<String, String>()
    private var privateRules = emptyMap<String, String>()
    @Synchronized override fun source(host: String, privateOrigin: Boolean): String? =
        (if (privateOrigin) privateRules else publicRules)[host]

    @Synchronized override fun setSource(host: String, privateOrigin: Boolean, source: String?) {
        require(host.isNotBlank() && host.length <= 253)
        require(source == null || source.matches(Regex("[a-z]{2,3}(?:-[A-Za-z]{2,8})?")))
        val previous = if (privateOrigin) privateRules else publicRules
        val next = if (source == null) previous - host else previous + (host to source)
        require(next.size <= 10_000) { "Too many translation rules" }
        if (privateOrigin) privateRules = next else publicRules = next
    }
}

/** Caller uses IO for public reads/writes. A corrupt file is preserved for recovery. */
class FileTranslationRules(private val file: File) : MemoryTranslationRules() {
    private val json = Json { ignoreUnknownKeys = true }
    init {
        if (file.isFile && file.length() <= 1024 * 1024) {
            publicRules = runCatching { json.decodeFromString<Map<String, String>>(file.readText()) }
                .getOrDefault(emptyMap()).filter { (host, source) -> host.isNotBlank() && host.length <= 253 &&
                    source.matches(Regex("[a-z]{2,3}(?:-[A-Za-z]{2,8})?")) }.entries.take(10_000).associate { it.toPair() }
        }
    }
    @Synchronized override fun setSource(host: String, privateOrigin: Boolean, source: String?) {
        val previous = publicRules
        super.setSource(host, privateOrigin, source)
        if (privateOrigin || previous == publicRules) return
        try {
            file.parentFile?.mkdirs()
            val pending = File(file.parentFile, file.name + ".pending")
            pending.outputStream().use { output ->
                output.write(json.encodeToString(publicRules).toByteArray(Charsets.UTF_8)); output.fd.sync()
            }
            check(pending.renameTo(file)) { "The translation rule could not be saved" }
        } catch (error: Exception) { publicRules = previous; throw error }
    }
}
