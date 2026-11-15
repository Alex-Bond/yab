package dev.yab.browser.model

/** One mixed folder/tab row; collection-qualified keys cannot collide. */
data class BrowserKeptRow(val folder: BrowserFolder? = null, val tab: BrowserTab? = null, val depth: Int = 0) {
    val key: String get() = folder?.let { "folder:${it.id}" } ?: "tab:${checkNotNull(tab).id}"
}

/** Phone SyncKeptTree's sibling order and malformed-parent repair, without any wire writes. */
object BrowserKeptTree {
    private const val DEEPEST = 5
    private class Tree(space: BrowserSpace) {
        val folders = space.folders.distinctBy { it.id }
        val tabs = space.tabs.filter { !it.isPrivate && it.place == TabPlace.KEPT }.distinctBy { it.id }
        private val ids = folders.mapTo(mutableSetOf()) { it.id }
        val parent = folders.associate { it.id to it.parentId?.takeIf { up -> up != it.id && up in ids } }.toMutableMap()
        init {
            val original = parent.toMap()
            for (folder in folders) {
                val seen = mutableSetOf(folder.id)
                var here = folder.id
                while (true) {
                    val up = original[here] ?: break
                    if (!seen.add(up) || seen.size > DEEPEST) { parent[folder.id] = null; break }
                    here = up
                }
            }
        }
        fun children(owner: String?) = folders.filter { parent[it.id] == owner }.map { BrowserKeptRow(folder = it) } +
            tabs.filter { it.folderId?.takeIf(ids::contains) == owner }.map { BrowserKeptRow(tab = it) }
        fun rows(includeClosed: Boolean, compare: Comparator<BrowserKeptRow>): List<BrowserKeptRow> = buildList {
            fun walk(owner: String?, depth: Int) {
                children(owner).sortedWith(compare).forEach { row ->
                    add(row.copy(depth = depth))
                    row.folder?.takeIf { includeClosed || it.open }?.let { walk(it.id, depth + 1) }
                }
            }
            walk(null, 0)
        }
    }

    fun rows(space: BrowserSpace, includeClosed: Boolean = false): List<BrowserKeptRow> {
        val rank = space.keptOrder.withIndex().associate { it.value to it.index }
        // Unpublished local additions follow the received rows, in their local order.
        return Tree(space).rows(includeClosed, compareBy { rank[it.key] ?: Int.MAX_VALUE })
    }

    /** Reads order values already supplied for both collections; a missing folder order uses its children. */
    fun importedOrder(space: BrowserSpace, wireOrder: Map<String, String>): List<String> {
        val tree = Tree(space)
        fun firstTabOrder(owner: String): String? = tree.children(owner).mapNotNull { child ->
            child.folder?.let { firstTabOrder(it.id) } ?: child.tab?.let { wireOrder[child.key] }
        }.minOrNull()
        val ranks = tree.folders.associate { folder ->
            val key = "folder:${folder.id}"
            key to (wireOrder[key] ?: firstTabOrder(folder.id) ?: "\uDBFF\uDFFF")
        } + tree.tabs.associate { "tab:${it.id}" to (wireOrder["tab:${it.id}"] ?: "") }
        return tree.rows(true, compareBy<BrowserKeptRow> { ranks.getValue(it.key) }.thenBy { it.key }).map { it.key }
    }
}
