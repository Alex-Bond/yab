package dev.yab.core.sync

/** Wire-compatible base62 fractional order keys (Sources/SyncKit/Order.swift). */
object Order {
    private const val digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    fun valid(key: String): Boolean = key.isNotEmpty() && key.last() != '0' && key.all { it in digits }
    fun between(after: String?, before: String?): String {
        var low = after?.takeIf(::valid) ?: ""
        var high = before?.takeIf(::valid)
        if (high != null && low >= high) { low = maxOf(low, high); high = null }
        if (high == null) return if (low.isEmpty()) digits[31].toString() else Order.after(low)
        if (low.isEmpty()) return Order.before(high)
        return midpoint(low, high)
    }
    private fun after(a: String): String {
        if (a.isEmpty()) return digits[31].toString()
        val d = digits.indexOf(a[0])
        return if (d < 61) digits[d + 1].toString() else a[0] + after(a.drop(1))
    }
    private fun before(b: String): String {
        if (b.isEmpty()) return digits[31].toString()
        val d = digits.indexOf(b[0])
        if (d > 1) return digits[d - 1].toString()
        if (d == 1 && b.length > 1) return b[0].toString()
        return "0" + if (b.length == 1) "z" else before(b.drop(1))
    }
    private fun midpoint(a: String, b: String?): String {
        if (b != null) {
            var n = 0
            while (n < b.length && a.getOrElse(n) { '0' } == b[n]) n++
            if (n > 0) return (0 until n).map { a.getOrElse(it) { '0' } }.joinToString("") + midpoint(a.drop(minOf(n, a.length)), b.drop(n))
        }
        val low = a.firstOrNull()?.let(digits::indexOf) ?: 0
        val high = b?.firstOrNull()?.let(digits::indexOf) ?: 62
        if (high - low > 1) return digits[(low + high + 1) / 2].toString()
        if (b != null && b.length > 1) return b[0].toString()
        return digits[low] + midpoint(a.drop(1), null)
    }
    fun spread(count: Int, after: String? = null, before: String? = null): List<String> {
        if (count <= 0) return emptyList()
        val low = after?.takeIf(::valid) ?: ""
        val high = before?.takeIf { valid(it) && low < it }
        val mid = midpoint(low, high)
        val left = (count - 1) / 2
        return spread(left, low, mid) + mid + spread(count - 1 - left, mid, high)
    }
    fun assign(ids: List<String>, previous: Map<String, String>): Map<String, String> {
        require(ids.distinct().size == ids.size)
        val old = ids.map { previous[it]?.takeIf(::valid) }
        val tails = mutableListOf<Int>(); val back = arrayOfNulls<Int>(ids.size)
        for ((i, key) in old.withIndex()) if (key != null) {
            var lo = 0; var hi = tails.size
            while (lo < hi) { val mid = (lo + hi) / 2; if (old[tails[mid]]!! < key) lo = mid + 1 else hi = mid }
            back[i] = if (lo > 0) tails[lo - 1] else null
            if (lo == tails.size) tails.add(i) else tails[lo] = i
        }
        val stays = mutableSetOf<Int>(); var at = tails.lastOrNull()
        while (at != null) { stays.add(at); at = back[at] }
        val result = linkedMapOf<String, String>(); var i = 0; var low: String? = null
        while (i < ids.size) {
            if (i in stays) { low = old[i]!!; result[ids[i]] = low; i++; continue }
            var j = i; while (j < ids.size && j !in stays) j++
            val high = old.getOrNull(j)
            spread(j - i, low, high).forEachIndexed { n, key -> result[ids[i + n]] = key }
            low = result[ids[j - 1]]; i = j
        }
        return result
    }
}
