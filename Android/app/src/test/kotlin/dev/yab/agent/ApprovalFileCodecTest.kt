package dev.yab.agent

import kotlinx.serialization.json.*
import kotlinx.serialization.encodeToString
import org.junit.Assert.*
import org.junit.Test

class ApprovalFileCodecTest {
    private fun file(extra: JsonObjectBuilder.() -> Unit = {}) = buildJsonObject {
        put("id", "original"); put("name", "Fixture.jpg"); put("kind", "image"); put("bytes", 42)
        put("pages", 150); put("previews", 3); extra()
    }
    @Test fun originalDimensionsStayDistinctFromPreviewCountAndFullDocumentPages() {
        val actual = ApprovalFileCodec.read(file { put("width", 1600); put("height", 800) })
        assertEquals(1600, actual.width); assertEquals(800, actual.height)
        assertEquals(150, actual.pages); assertEquals(3, actual.previewPages); assertEquals(42L, actual.size)
        assertEquals("application/pdf", ApprovalFileCodec.read(file { put("kind", "pdf") }).mime)
    }
    @Test fun absentNullAndNonpositiveDimensionsKeepTheSourcePictureFallback() {
        assertNull(ApprovalFileCodec.read(file()).width)
        assertNull(ApprovalFileCodec.read(file { put("width", JsonNull) }).width)
        val legacy = ApprovalFileCodec.read(file { put("width", 0); put("height", -1) })
        assertEquals(0, legacy.width); assertEquals(-1, legacy.height)
        assertEquals(1.0, ApprovalDetailGeometry.fitPicture(390.0, 844.0, 47.0, true, legacy.width, legacy.height).let { it.width / it.height }, 0.0)
    }
    @Test fun malformedDimensionTypesAndOverflowAreNeverSilentlyRenderedAsDifferentFacts() {
        for (bad in listOf<JsonElement>(JsonPrimitive("1600"), JsonPrimitive(true), JsonPrimitive(1.5), JsonPrimitive(3_000_000_000L), JsonObject(emptyMap()))) {
            assertThrows(IllegalArgumentException::class.java) { ApprovalFileCodec.read(file { put("width", bad) }) }
        }
    }
    @Test fun legacyFilesKeepTheirExistingFingerprintBytesWhenNoDimensionsWereSent() {
        val file = ApprovalFile("legacy", "Fixture.jpg", "image/jpeg", 42)
        assertEquals("{\"id\":\"legacy\",\"name\":\"Fixture.jpg\",\"mime\":\"image/jpeg\",\"size\":42}", Json.encodeToString(file))
        assertNotEquals(Json.encodeToString(file), Json.encodeToString(file.copy(width = 1600, height = 800)))
    }
}
