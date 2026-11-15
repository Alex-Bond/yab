package dev.yab.shield

import java.io.File
import java.net.URI
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

fun shieldHost(value: String?): String? = value?.lowercase(Locale.ROOT)?.removePrefix("www.")?.takeIf {
    it.isNotEmpty() && it.length <= 253 && it.all { c -> c in 'a'..'z' || c in '0'..'9' || c in ".-_:" } && !it.startsWith('.') && !it.endsWith('.')
}
fun shieldUrlHost(value: String?): String? = value?.let { runCatching { URI(it).takeIf { uri -> uri.scheme in setOf("http", "https") }?.host?.let(::shieldHost) }.getOrNull() }

@Serializable
data class ShieldPolicy(val localGlobal: Boolean? = null, val importedGlobal: Boolean = true,
    val publicSites: Map<String, Boolean> = emptyMap(), val privateSites: Map<String, Boolean> = emptyMap(),
    val importedPaused: Set<String> = emptySet()) {
    val global get() = localGlobal ?: importedGlobal
    fun enabled(host: String?, privately: Boolean): Boolean {
        if (!global) return false
        val key = shieldHost(host) ?: return true
        return (if (privately) privateSites else publicSites)[key] ?: (key !in importedPaused)
    }
}

/** Only local public choices reach disk. Mac imports and Private choices stay in RAM. */
class ShieldPolicyStore(private val file: File? = null) {
    @Serializable private data class Saved(val schema: Int = 1, val global: Boolean? = null, val sites: Map<String, Boolean> = emptyMap())
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val mutex = Mutex()
    private val mutable = MutableStateFlow(load())
    val state = mutable.asStateFlow()
    private fun load(): ShieldPolicy {
        val target = file ?: return ShieldPolicy()
        if (!target.isFile || target.length() > 1024 * 1024) return ShieldPolicy()
        return runCatching { json.decodeFromString<Saved>(target.readText()).takeIf { it.schema == 1 }?.let { saved ->
            ShieldPolicy(localGlobal = saved.global, publicSites = saved.sites.entries.take(10_000).mapNotNull { (host, value) -> shieldHost(host)?.let { it to value } }.toMap())
        } }.getOrNull() ?: ShieldPolicy()
    }
    suspend fun setGlobal(enabled: Boolean) = change { it.copy(localGlobal = enabled) }
    suspend fun setSite(host: String?, privately: Boolean, enabled: Boolean) {
        val key = shieldHost(host) ?: return
        change { old ->
            val sites = (if (privately) old.privateSites else old.publicSites).toMutableMap()
            check(key in sites || sites.size < 10_000) { "Too many saved site choices" }; sites[key] = enabled
            if (privately) old.copy(privateSites = sites) else old.copy(publicSites = sites)
        }
    }
    suspend fun importMac(enabled: Boolean?, paused: List<String>?) = mutex.withLock {
        mutable.value = mutable.value.copy(importedGlobal = enabled ?: true,
            importedPaused = paused.orEmpty().take(10_000).mapNotNull(::shieldHost).toSet())
    }
    private suspend fun change(update: (ShieldPolicy) -> ShieldPolicy) = mutex.withLock {
        val before = mutable.value; val next = update(before)
        if (before.localGlobal != next.localGlobal || before.publicSites != next.publicSites) withContext(Dispatchers.IO) {
            file?.let { target ->
                target.parentFile?.mkdirs(); val pending = File(target.parentFile, target.name + ".pending")
                try {
                    pending.outputStream().use { stream -> stream.write(json.encodeToString(Saved(global = next.localGlobal, sites = next.publicSites)).toByteArray()); stream.fd.sync() }
                    check(pending.renameTo(target)) { "Site blocking choices could not be saved" }
                } finally { pending.delete() }
            }
        }
        mutable.value = next
    }
}
