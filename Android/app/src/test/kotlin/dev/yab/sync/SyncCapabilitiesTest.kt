package dev.yab.sync

import dev.yab.core.sync.MemoryJournal
import dev.yab.core.sync.RecordKey
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.int
import org.junit.Assert.*
import org.junit.Test

class SyncCapabilitiesTest {
    @Test fun androidAdvertisesOnlyItsImplementedMobileCapabilitiesWithItsOwnStamps() {
        val fields = SyncCapabilities.local("android")
        val record = MemoryJournal("android").change(RecordKey("commandcap", "android"), fields)
        assertEquals(setOf("device", "kind", "platform", "androidSync", "open", "assistantApprovals"), record.visible.keys)
        assertEquals("android", record["device"]!!.jsonPrimitive.content)
        assertEquals("android", record["kind"]!!.jsonPrimitive.content)
        assertEquals("android", record["platform"]!!.jsonPrimitive.content)
        assertEquals(1, record["androidSync"]!!.jsonPrimitive.int)
        assertEquals(1, record["open"]!!.jsonPrimitive.int)
        assertEquals(3, record["assistantApprovals"]!!.jsonPrimitive.int)
        assertTrue(record.visible.keys.all { record.stamps[it]?.device == "android" })
    }
}
