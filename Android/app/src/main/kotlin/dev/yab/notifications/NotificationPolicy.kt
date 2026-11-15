package dev.yab.notifications

data class PushEnvelope(val kind: Kind, val approval: String?, val name: String?, val blob: String?) {
    enum class Kind { SYNC, APPROVAL, WITHDRAW }
    companion object {
        fun read(data: Map<String, String>): PushEnvelope? {
            if (data["v"] != "1") return null
            val kind = when (data["kind"]) { "sync" -> Kind.SYNC; "approval" -> Kind.APPROVAL; "withdraw" -> Kind.WITHDRAW; else -> return null }
            val id = data["approval"]?.takeIf { it.matches(Regex("[A-Za-z0-9:_-]{1,128}")) }
            if (kind != Kind.SYNC && id == null) return null
            val name = data["n"]?.takeIf { it.length in 1..256 }
            val blob = data["b"]?.takeIf { it.length in 1..4000 }
            return PushEnvelope(kind, id, name, blob)
        }
    }
}

data class NotificationWords(val id: String, val title: String, val body: String, val validated: Boolean)
object NotificationPolicy {
    /** Only locally decrypted/current records may supply human-readable notification content. */
    fun words(envelope: PushEnvelope, validatedId: String?, title: String?, summary: String?): NotificationWords? {
        if (envelope.kind != PushEnvelope.Kind.APPROVAL) return null
        val id = envelope.approval ?: return null
        return if (validatedId == id && title != null && summary != null) NotificationWords(id, title.take(240), summary.take(800), true)
        else NotificationWords(id, "Yab", "Needs your answer", false)
    }
    fun ledgerKey(account: String?, id: String): String = "${account ?: "unjoined"}:$id"
    fun alreadyAnnounced(key: String, seen: Map<String, Long>, now: Long): Boolean = seen[key]?.let { now - it in 0..172_800_000 } == true
}
