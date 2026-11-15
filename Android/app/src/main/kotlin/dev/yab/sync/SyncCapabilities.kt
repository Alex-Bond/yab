package dev.yab.sync

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Values required by production SyncKit OpenOnPhone and approval capability readers. */
internal object SyncCapabilities {
    fun local(device: String): JsonObject = buildJsonObject {
        put("device", device); put("kind", "android"); put("platform", "android")
        put("androidSync", 1); put("open", 1); put("assistantApprovals", 3)
    }
}
