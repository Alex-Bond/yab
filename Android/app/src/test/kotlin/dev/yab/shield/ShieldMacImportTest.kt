package dev.yab.shield

import dev.yab.core.sync.Record
import dev.yab.core.sync.Stamp
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ShieldMacImportTest {
    private fun setting(id: String, value: JsonElement) = Record("setting", id, buildJsonObject { put("value", value) })
    @Test fun exactSwiftBooleanNumberAndStringArrayImportsResetOnAccountEnd() {
        val paused = setting("shield.paused", buildJsonArray { add("WWW.EXAMPLE.COM"); add(4); add(false) })
        assertEquals(ShieldMacPreferences(false, listOf("WWW.EXAMPLE.COM")), ShieldMacImport.project(listOf(setting("shield", JsonPrimitive(0)), paused), "account"))
        assertEquals(true, ShieldMacImport.project(listOf(setting("shield", JsonPrimitive(2))), "account").enabled)
        assertNull(ShieldMacImport.project(listOf(setting("shield", JsonPrimitive("false"))), "account").enabled)
        assertEquals(ShieldMacPreferences(), ShieldMacImport.project(listOf(paused), null))
        assertEquals(ShieldMacPreferences(), ShieldMacImport.project(listOf(paused), "account", removed = true))
        val removed = setting("shield", JsonPrimitive(false)).copy(deleted = Stamp(10, device = "mac"))
        assertNull(ShieldMacImport.project(listOf(removed), "account").enabled)
    }
}
