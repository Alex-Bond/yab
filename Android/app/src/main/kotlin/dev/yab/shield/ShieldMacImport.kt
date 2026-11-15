package dev.yab.shield

import dev.yab.core.sync.Record
import kotlinx.serialization.json.*

data class ShieldMacPreferences(val enabled: Boolean? = null, val paused: List<String>? = null)

/** Import only. This projection never creates or writes a synced setting. */
object ShieldMacImport {
    fun project(records: List<Record>, account: String?, removed: Boolean = false): ShieldMacPreferences {
        if (account == null || removed) return ShieldMacPreferences()
        val settings = records.filter { it.collection == "setting" && it.alive() }.associateBy { it.id }
        val enabled = (settings["shield"]?.get("value") as? JsonPrimitive)?.takeUnless { it.isString }?.let {
            it.booleanOrNull ?: it.doubleOrNull?.let { number -> number != 0.0 }
        }
        val paused = (settings["shield.paused"]?.get("value") as? JsonArray)?.mapNotNull {
            (it as? JsonPrimitive)?.takeIf { value -> value.isString }?.content
        }
        return ShieldMacPreferences(enabled, paused)
    }
}
