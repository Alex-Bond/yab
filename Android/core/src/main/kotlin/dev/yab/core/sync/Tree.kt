package dev.yab.core.sync

/** Deterministic repair of concurrent folder moves, orphans and duplicate order keys. */
object Tree {
    data class Node(val id: String, val parent: String?, val order: String, val moved: Stamp? = null)
    data class Fix(val id: String, val parent: String?, val order: String)
    fun repair(nodes: List<Node>, roots: Set<String> = emptySet(), fallback: String? = null): List<Fix> {
        val byId = nodes.distinctBy { it.id }.associateBy { it.id }.toMutableMap(); val fixes = mutableListOf<Fix>()
        fun move(id: String) {
            val node = byId[id] ?: return
            val parent = fallback?.takeIf { it in byId || it in roots }
            val order = Order.between(byId.values.filter { it.parent == parent }.maxOfOrNull { it.order }, null)
            byId[id] = node.copy(parent = parent, order = order); fixes += Fix(id, parent, order)
        }
        for (id in byId.keys.sorted()) byId[id]?.parent?.let { if (it !in byId && it !in roots) move(id) }
        for (id in byId.keys.sorted()) {
            val path = mutableListOf<String>(); val seen = mutableSetOf<String>(); var at: String? = id
            while (at != null && at in byId) {
                val here = at ?: break
                if (here in seen) {
                    val loop = path.dropWhile { it != here }
                    val oldest = loop.minWithOrNull { a, b ->
                        val x = byId[a]?.moved; val y = byId[b]?.moved
                        when { x != null && y != null -> x.compareTo(y).takeIf { it != 0 } ?: wireCompare(a, b); x == null && y != null -> -1; x != null -> 1; else -> wireCompare(a, b) }
                    }
                    oldest?.let(::move); break
                }
                seen += here; path += here; at = byId[here]?.parent
            }
        }
        for (group in byId.values.groupBy { it.parent }.values) {
            val sorted = group.sortedWith(compareBy<Node> { it.order }.thenBy { it.id }); var previous: String? = null
            for ((index, node) in sorted.withIndex()) {
                var order = node.order
                val prior = previous
                if (prior != null && order <= prior) {
                    val next = sorted.drop(index + 1).firstOrNull { it.order > prior }?.order
                    order = Order.between(prior, next); byId[node.id] = node.copy(order = order); fixes += Fix(node.id, node.parent, order)
                }
                previous = order
            }
        }
        return fixes
    }
    fun children(parent: String?, nodes: List<Node>): List<Node> = nodes.filter { it.parent == parent }.sortedWith(compareBy<Node> { it.order }.thenBy { it.id })
}
