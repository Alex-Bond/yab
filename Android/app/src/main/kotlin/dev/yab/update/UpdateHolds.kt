package dev.yab.update

import java.lang.ref.WeakReference
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

fun interface UpdateHold { fun reason(): String? }

/** Installing ends this process, so anything a person would lose holds the update back. Read on the main thread. */
object UpdateHolds {
    private val sources = CopyOnWriteArrayList<WeakReference<UpdateHold>>()
    private val transfers = AtomicInteger()

    /** Held weakly: the owner keeps its [UpdateHold] in a field and goes when it goes. */
    fun add(source: UpdateHold) { sources.add(WeakReference(source)) }

    inline fun <T> during(work: () -> T): T {
        began()
        try { return work() } finally { ended() }
    }
    fun began() { transfers.incrementAndGet() }
    fun ended() { transfers.decrementAndGet() }

    fun reason(): String? {
        if (transfers.get() > 0) return "transfer"
        sources.removeAll { it.get() == null }
        return sources.firstNotNullOfOrNull { it.get()?.reason() }
    }
}
