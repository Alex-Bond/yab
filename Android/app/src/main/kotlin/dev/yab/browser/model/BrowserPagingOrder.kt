package dev.yab.browser.model

/** Phone Space.rows: visible kept-tree rows, then Today, with an out-of-column
 * selected pin or closed-folder page inserted at the beginning. Never MRU order. */
internal fun BrowserState.pagingOrder(): List<BrowserTab> {
    val owner = space ?: return emptyList()
    val rows = mutableListOf<BrowserTab>()
    val represented = mutableSetOf<String>()
    val visited = mutableSetOf<String>()
    fun walk(parent: String?, visible: Boolean, depth: Int) {
        owner.tabs.filter { it.place == TabPlace.KEPT && it.folderId == parent }.forEach {
            represented += it.id
            if (visible || it.id == owner.currentTabId) rows += it
        }
        owner.folders.filter { it.parentId == parent }.forEach { folder ->
            if (visited.add(folder.id) && depth < 20) walk(folder.id, visible && folder.open, depth + 1)
        }
    }
    walk(null, true, 0)
    // Malformed remote parentage follows the column's visible orphan fallback.
    rows += owner.tabs.filter { it.place == TabPlace.KEPT && it.id !in represented }
    rows += owner.tabs.filter { it.place == TabPlace.TODAY }
    val front = tab
    return if (front != null && rows.none { it.id == front.id }) listOf(front) + rows else rows
}
