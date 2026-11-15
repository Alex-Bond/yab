package dev.yab.reports

import dev.yab.core.sync.Record
import kotlinx.serialization.json.JsonPrimitive

/** Projects only the current authenticated account's setting; never publishes an identity to Sync. */
object ReportPerson {
    fun project(records: List<Record>, account: String?, removed: Boolean): String? {
        if (account.isNullOrBlank() || removed) return null
        val row = records.singleOrNull { it.collection == "setting" && it.id == "activity.person" } ?: return null
        if (row.schema != 1 || !row.alive()) return null
        val value = row["value"] as? JsonPrimitive ?: return null
        return value.content.takeIf { value.isString && ReportWire.uuid.matches(it) }?.lowercase()
    }
}
