package dev.yab.browser.engine

import dev.yab.browser.model.BrowserBackItem
import java.util.UUID

/** RAM-only menu leases, issued from a copied native history list for one native session. */
internal class NativeBackHistory {
    data class Page(val url: String, val title: String)
    private data class Lease(val tab: String, val generation: String, val revision: String,
        val document: String, val current: Int, val target: Int, val page: Page)
    private val generation = UUID.randomUUID().toString()
    private var revision = UUID.randomUUID().toString()
    private var pages: List<Page> = emptyList()
    private var current = -1
    private val leases = mutableMapOf<String, Lease>()

    fun capture(items: List<Page>, currentIndex: Int): Boolean {
        val copied = items.toList()
        val index = currentIndex.takeIf { it in copied.indices } ?: -1
        if (pages == copied && current == index) return false
        pages = copied; current = index; invalidate()
        return true
    }

    fun invalidate() { revision = UUID.randomUUID().toString(); leases.clear() }

    fun items(tab: String, document: String): List<BrowserBackItem> {
        if (current <= 0) return emptyList()
        return (current - 1 downTo 0).map { target ->
            val lease = Lease(tab, generation, revision, document, current, target, pages[target])
            val token = leases.entries.firstOrNull { it.value == lease }?.key
                ?: UUID.randomUUID().toString().also { leases[it] = lease }
            BrowserBackItem(current - target, lease.page.url, lease.page.title, token)
        }
    }

    fun consume(tab: String, document: String, item: BrowserBackItem): Int? {
        val lease = leases[item.token] ?: return null
        if (lease.tab != tab || lease.generation != generation || lease.revision != revision ||
            lease.document != document || lease.current != current || lease.target !in 0 until current ||
            pages.getOrNull(lease.target) != lease.page || item.steps != current - lease.target ||
            item.url != lease.page.url || item.title != lease.page.title) return null
        invalidate()
        return lease.target
    }
}
