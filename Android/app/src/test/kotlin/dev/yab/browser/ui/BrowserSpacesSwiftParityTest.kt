package dev.yab.browser.ui

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** The reference trace is emitted by actual current Phone CapsuleModel and LiftFrame Swift. */
class BrowserSpacesSwiftParityTest {
    private fun resource(name: String) = checkNotNull(javaClass.getResourceAsStream("/spaces/$name"))
        .bufferedReader().use { Json.parseToJsonElement(it.readText()).jsonObject }
    private val vectors by lazy { resource("current-ios-vectors.json") }
    private fun JsonObject.number(key: String) = getValue(key).jsonPrimitive.double
    private fun JsonObject.integer(key: String) = getValue(key).jsonPrimitive.int
    private fun JsonObject.boolean(key: String) = getValue(key).jsonPrimitive.boolean
    private fun event(value: BrowserSpaceCapsuleModel.Event?) = when (value) {
        is BrowserSpaceCapsuleModel.Event.Tap -> "tap:${value.index}"
        is BrowserSpaceCapsuleModel.Event.Release -> "release:${value.index}"
        BrowserSpaceCapsuleModel.Event.PressCurrent -> "pressCurrent"
        null -> "none"
    }

    @Test fun everySixSpringStateMatchesActualSwiftAcrossTapsThrowsCancellationAndReversal() {
        val input = resource("inputs.json").getValue("cases").jsonArray
        val rows = vectors.getValue("capsule").jsonArray.map { it.jsonObject }
        assertEquals(10, input.size)
        assertEquals(input.map { it.jsonObject.getValue("id").jsonPrimitive.content }.toSet(),
            rows.map { it.getValue("case").jsonPrimitive.content }.toSet())
        var total = 0
        input.forEach { caseValue ->
            val case = caseValue.jsonObject
            val id = case.getValue("id").jsonPrimitive.content
            val expected = rows.filter { it.getValue("case").jsonPrimitive.content == id }.iterator()
            val model = BrowserSpaceCapsuleModel(case.getValue("widths").jsonArray.map { it.jsonPrimitive.double },
                case.integer("current"), case.number("mid"), case.number("rest"), case.number("wide"), case.boolean("pair"))
            fun sample(operation: Int, frame: Int, result: BrowserSpaceCapsuleModel.Event? = null) {
                assertTrue("$id lacks Swift row for operation $operation frame $frame", expected.hasNext())
                val row = expected.next()
                val context = "$id operation=$operation frame=$frame"
                assertEquals(context, operation, row.integer("operation"))
                assertEquals(context, frame, row.integer("frame"))
                assertEquals(context, row.getValue("event").jsonPrimitive.content, event(result))
                val pose = model.pose
                val values = listOf(pose.left, pose.width, pose.trackX, pose.lensCenter, pose.lensWidth,
                    pose.fraction, pose.side, pose.press)
                row.getValue("pose").jsonArray.forEachIndexed { index, value ->
                    assertEquals("$context pose[$index]", value.jsonPrimitive.double, values[index], 1e-8)
                }
                val springs = listOf(model.trackX, model.capWidth, model.side, model.fraction, model.press, model.pull)
                row.getValue("springs").jsonArray.forEachIndexed { index, value ->
                    val actual = springs[index].let { listOf(it.value, it.target, it.velocity) }
                    value.jsonArray.forEachIndexed { channel, number ->
                        assertEquals("$context spring[$index][$channel]", number.jsonPrimitive.double, actual[channel], 1e-8)
                    }
                }
                assertEquals(context, row.getValue("fades").jsonArray.map { it.jsonPrimitive.boolean },
                    listOf(pose.fadeLeft, pose.fadeRight))
                assertEquals(context, row.integer("current"), model.current)
                assertEquals(context, row.getValue("mode").jsonPrimitive.content, model.mode.name.lowercase())
                assertEquals(context, row.boolean("settled"), model.isSettled)
                assertEquals(context, row.boolean("touching"), model.isTouched)
                assertEquals(context, row.boolean("dragging"), model.isDragging)
                assertEquals(context, row.boolean("external"), model.external)
                assertEquals(context, row.integer("ticks"), model.ticks)
                assertEquals(context, row.number("time"), model.time, 1e-10)
                total++
            }
            sample(-1, 0)
            case.getValue("operations").jsonArray.forEachIndexed { index, value ->
                val operation = value.jsonObject
                if (operation.getValue("kind").jsonPrimitive.content == "step") {
                    repeat(operation.integer("frames")) { frame -> model.step(operation.number("dt")); sample(index, frame) }
                } else {
                    val result = when (operation.getValue("kind").jsonPrimitive.content) {
                        "down" -> { model.down(operation.number("x")); null }
                        "move" -> { model.move(operation.number("x")); null }
                        "up" -> model.up(operation.number("x"))
                        "select" -> model.select(operation.integer("index"))
                        "follow" -> { model.follow(operation.number("position"), operation.integer("index")); null }
                        "cancel" -> { model.cancel(); null }
                        "reset" -> { model.reset(operation.integer("index")); null }
                        else -> error("Unknown Swift oracle operation")
                    }
                    sample(index, 0, result)
                }
            }
            assertFalse("$id leaves unverified Swift states", expected.hasNext())
        }
        assertEquals(rows.size, total)
    }

    @Test fun everyLiftFrameMatchesActualSwiftIncludingKeyboardAndRevealBoundaries() {
        val rows = vectors.getValue("lift").jsonArray
        assertEquals(85, rows.size)
        rows.forEachIndexed { index, value ->
            val row = value.jsonObject
            val plate = row.getValue("plate").jsonArray.map { it.jsonPrimitive.double }
            val actual = BrowserSpacesLiftFrame.at(row.number("reveal"), row.number("width"), row.number("bottom"),
                SpacesRect(plate[0], plate[1], plate[2], plate[3]))
            val expected = row.getValue("pose")
            if (expected == JsonNull) assertNull("lift $index", actual)
            else {
                assertNotNull("lift $index", actual)
                val values = requireNotNull(actual).let { listOf(it.rect.x, it.rect.y, it.rect.width, it.rect.height, it.radius, it.drop) }
                expected.jsonArray.forEachIndexed { channel, number ->
                    assertEquals("lift $index channel $channel", number.jsonPrimitive.double, values[channel], 1e-8)
                }
            }
        }
    }
}
