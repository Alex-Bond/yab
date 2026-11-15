package dev.yab.browser.ui

import java.security.MessageDigest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Original Swift output fetched unchanged from owned job 9f7b0d5f4c604831, not Android-generated expectations. */
class BrowserFieldSwiftParityTest {
    private val vectorBytes by lazy { resource("current-ios-vectors.json") }
    private val inputBytes by lazy { resource("current-ios-inputs.json") }
    private val pinBytes by lazy { resource("current-ios-source-pins.json") }
    private val vectors by lazy { Json.parseToJsonElement(vectorBytes.decodeToString()).jsonObject }
    private val inputs by lazy { Json.parseToJsonElement(inputBytes.decodeToString()).jsonObject }
    private val pins by lazy { Json.parseToJsonElement(pinBytes.decodeToString()).jsonObject }
    private fun resource(name: String) = checkNotNull(javaClass.getResourceAsStream("/field-presentation/$name"))
        .use { it.readBytes() }
    private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun JsonObject.number(key: String) = getValue(key).jsonPrimitive.double
    private fun JsonObject.boolean(key: String) = getValue(key).jsonPrimitive.boolean
    private fun rectangle(row: JsonObject, name: String, actual: FieldRect, context: String) {
        val expected = row.getValue(name).jsonArray
        assertEquals(4, expected.size)
        listOf(actual.x, actual.y, actual.width, actual.height).forEachIndexed { index, value ->
            assertEquals("$context $name[$index]", expected[index].jsonPrimitive.double, value, 1e-8)
        }
    }

    @Test fun corpusBytesAndSourcePinsRemainTheActual288CaseSwiftReceipt() {
        assertEquals("9d4b3680c58bbdc704951dbe8c77a2009169a1c82b7086ccc28cfa6a741a7062", sha256(vectorBytes))
        assertEquals("13fdb5464fda80eaeafb31ff3194209bd95480f17db63885ab674f57301a724e", sha256(inputBytes))
        assertEquals("97197e12b6f2615f353d343e19126b30ea85558619f9670b54901819f4a01271", sha256(pinBytes))
        assertEquals("944f6c2722068ceca102523480119c48a2d67e3a", pins.getValue("sourceSnapshot").jsonPrimitive.content)
        val expected = mapOf(
            "Phone/Sources/Field/FieldLayer.swift" to "21f2c4451e8847b820d56c09c746f3eff96e9c580f09d92e7c2ce43d808b5bed",
            "Phone/Sources/Design/Metrics.swift" to "a0bbcd4abd04f19f7cb85af9d84e2f4997c97be27f011ac73235286bbcfd2dfc",
            "Phone/Sources/Field/FieldMetrics.swift" to "55749b72a82214d1d70d26cd0338246ffe465d867a6b149f7300f45da1ca4195",
            "Phone/Sources/Field/FieldMotion.swift" to "a26d7e80ca782b623da673760960358a3754cdba337d5a3d4f8b013411bfc2f9",
            "Phone/Sources/Design/Motion.swift" to "6486d3bcf161a7d97b8f8ae9e739c9eb59f367643a51ee3e82977f302c2e3672",
            "Android/parity/field-presentation/inputs.json" to sha256(inputBytes),
        )
        val sourceRows = pins.getValue("inputs").jsonArray
        assertEquals(expected.size, sourceRows.size)
        val actual = sourceRows.associate { value -> value.jsonObject.let {
            it.getValue("path").jsonPrimitive.content to it.getValue("sha256").jsonPrimitive.content
        } }
        assertEquals(expected, actual)
        assertTrue(vectors.boolean("originalSwiftGeometry"))
        assertTrue(pins.boolean("originalSwiftGeometry"))
        assertFalse(vectors.boolean("nativeFontMeasurementVerified"))
        assertFalse(vectors.boolean("nativeKeyboardVerified"))
        assertFalse(vectors.boolean("presentedFrameParityVerified"))
        assertFalse(pins.boolean("nativeFontsVerified"))
        assertFalse(pins.boolean("nativeKeyboardVerified"))
        assertFalse(pins.boolean("presentedFrameParityVerified"))
    }

    @Test fun everyActualSwiftGeometryMatchesBothModesRestingKeyboardAndTextScale() {
        val cases = inputs.getValue("cases").jsonArray
        val rows = vectors.getValue("vectors").jsonArray
        assertEquals(288, cases.size)
        assertEquals(cases.size, rows.size)
        assertEquals(288, cases.toSet().size)
        rows.forEachIndexed { index, value ->
            val row = value.jsonObject
            val input = row.getValue("input").jsonObject
            val expectedInput = cases[index].jsonObject
            assertEquals("Swift input keys $index", expectedInput.keys, input.keys)
            // Foundation emits more decimal digits for the same IEEE Double than Python JSON.
            // Preserve row order and exact numeric values instead of comparing JSON spelling.
            for (name in listOf("width", "height", "keyboard", "textScale", "lineHeight")) {
                assertEquals("Swift input $index $name", expectedInput.number(name), input.number(name), 0.0)
            }
            assertEquals("Swift input $index mode", expectedInput.getValue("mode"), input.getValue("mode"))
            assertEquals("Swift input $index resting", expectedInput.boolean("resting"), input.boolean("resting"))
            val mode = input.getValue("mode").jsonPrimitive.content
            assertTrue(mode in setOf("address", "newTab"))
            val g = BrowserFieldGeometry(input.number("width"), input.number("height"), input.number("keyboard"),
                textScale = input.number("textScale"), lineHeight = input.number("lineHeight"),
                resting = input.boolean("resting"), newTab = mode == "newTab")
            rectangle(row, "field", g.field, "case $index")
            rectangle(row, "close", g.close, "case $index")
            val scalars = mapOf("keyboardTop" to g.keyboardTop, "radius" to g.field.height / 2,
                "cardBottom" to g.cardBottom, "cardWidth" to g.cardWidth, "newTabBottom" to g.newTabBottom,
                "spacesBottom" to g.spacesBottom, "spacesFieldExtra" to g.spacesFieldExtra,
                "newTabWidth" to g.newTabWidth, "newTabMaxHeight" to g.newTabMaxHeight)
            scalars.forEach { (name, actual) -> assertEquals("case $index $name", row.number(name), actual, 1e-8) }
        }
        fun axis(name: String) = cases.map { it.jsonObject.getValue(name) }.toSet().size
        assertEquals(6, cases.map { it.jsonObject.let { row -> row.number("width") to row.number("height") } }.toSet().size)
        assertEquals(3, axis("keyboard")); assertEquals(4, axis("textScale"))
        assertEquals(2, axis("mode")); assertEquals(2, axis("resting"))
    }
}
