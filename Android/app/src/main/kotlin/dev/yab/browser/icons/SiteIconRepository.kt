package dev.yab.browser.icons

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext

/** Public-only RAM pictures. A private read cannot see a public cache hit or start a request. */
internal class SiteIconRepository<T : Any>(
    private val scope: CoroutineScope,
    private val fetch: suspend (String, SiteIconOrigin) -> ByteArray?,
    private val decode: (ByteArray) -> T?,
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
    private val weight: (T) -> Int = { 1 },
    private val weightLimit: Long = 32L * 1024 * 1024,
    /** The icons an https site's own home page names, tried when the root has none. */
    private val discover: suspend (SiteIconOrigin) -> List<String> = { emptyList() },
    /** A picture taken: kept for the next launch. Public origins only reach this. */
    private val keep: (SiteIconOrigin, ByteArray) -> Unit = { _, _ -> },
) {
    private data class Pending(val token: Long, val task: Deferred<Boolean>)
    private data class Failure(val address: String, val at: Long)
    private val mutex = Mutex()
    private val network = Semaphore(4)
    private val requests = mutableMapOf<SiteIconOrigin, Pending>()
    private val failures = linkedMapOf<SiteIconOrigin, Failure>()
    private val mutable = MutableStateFlow<Map<SiteIconOrigin, T>>(emptyMap())
    val pictures = mutable.asStateFlow()
    private var generation = 0L
    private var sequence = 0L

    fun image(page: String?, isPrivate: Boolean): T? = if (isPrivate) null else SiteIconOrigin.from(page)?.let { mutable.value[it] }

    suspend fun load(page: String, declared: String?, isPrivate: Boolean): Boolean {
        if (isPrivate) return false
        val origin = SiteIconOrigin.from(page) ?: return false
        val candidates = origin.candidates(declared)
        val address = candidates.first()
        var joined = false
        val pending = mutex.withLock {
            if (mutable.value[origin] != null) return true
            requests[origin]?.let { joined = true; return@withLock it }
            val failure = failures[origin]
            if (failure?.address == address && now() - failure.at in 0L until 30_000L) return false
            if (requests.size >= 256) return false
            val token = ++sequence
            val lease = generation
            val task = scope.async(start = CoroutineStart.LAZY) {
                try {
                    suspend fun take(candidate: String): Boolean {
                        currentCoroutineContext().ensureActive()
                        val bytes = network.withPermit { fetch(candidate, origin) } ?: return false
                        currentCoroutineContext().ensureActive()
                        if (bytes.size > 1_048_576) return false
                        val image = decode(bytes) ?: return false
                        val accepted = mutex.withLock {
                            if (generation != lease || requests[origin]?.token != token) false
                            else {
                                val cost = weight(image).coerceAtLeast(1).toLong()
                                if (cost > weightLimit) false else {
                                    val next = LinkedHashMap(mutable.value).apply { remove(origin) }
                                    var total = next.values.sumOf { weight(it).coerceAtLeast(1).toLong() }
                                    while (next.isNotEmpty() && (next.size >= 256 || total + cost > weightLimit)) {
                                        val key = next.keys.first(); total -= weight(next.remove(key)!!).coerceAtLeast(1)
                                    }
                                    next[origin] = image; mutable.value = next; failures.remove(origin); true
                                }
                            }
                        }
                        if (accepted) keep(origin, bytes)
                        return accepted
                    }
                    suspend fun held() = mutex.withLock { generation == lease && requests[origin]?.token == token }
                    for (candidate in candidates) {
                        if (!held()) return@async false
                        if (take(candidate)) return@async true
                    }
                    if (origin.scheme == "https" && held()) {
                        for (candidate in network.withPermit { discover(origin) }) {
                            if (!held()) return@async false
                            if (take(candidate)) return@async true
                        }
                    }
                    mutex.withLock {
                        if (generation == lease && requests[origin]?.token == token) {
                            if (failures.size >= 256) failures.remove(failures.keys.first())
                            failures[origin] = Failure(address, now())
                        }
                    }
                    false
                } finally {
                    withContext(NonCancellable) { mutex.withLock { if (requests[origin]?.token == token) requests.remove(origin) } }
                }
            }
            Pending(token, task).also { requests[origin] = it }
        }
        pending.task.start()
        if (pending.task.await()) return true
        // A custom page icon can arrive while the cold /favicon.ico request is in flight.
        return joined && address != origin.fallback && load(page, declared, isPrivate = false)
    }

    /** Icons from earlier launches: never over one already here, never past the weight. */
    suspend fun restore(kept: Map<SiteIconOrigin, T>) = mutex.withLock {
        val next = LinkedHashMap(mutable.value)
        var total = next.values.sumOf { weight(it).coerceAtLeast(1).toLong() }
        for ((origin, image) in kept) {
            val cost = weight(image).coerceAtLeast(1).toLong()
            if (origin in next || next.size >= 256 || total + cost > weightLimit) continue
            next[origin] = image; total += cost
        }
        mutable.value = next
    }

    suspend fun removeAll() = mutex.withLock {
        generation++
        requests.values.forEach { it.task.cancel() }
        requests.clear(); failures.clear(); mutable.value = emptyMap()
    }
}
