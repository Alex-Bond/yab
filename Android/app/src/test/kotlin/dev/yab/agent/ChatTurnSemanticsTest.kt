package dev.yab.agent

import dev.yab.core.sync.Record
import java.io.File
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/** The source-derived shared fixtures also feed the independent production Swift helper oracle. */
@RunWith(Parameterized::class)
class ChatTurnSemanticsTest(private val name: String, private val fixture: JsonObject) {
    @Test fun sharedSourceCorpusAndActualProjection(): Unit {
        val head = Record("chat", "a:$name", fixture.getValue("head").jsonObject)
        val records = fixture.getValue("items").jsonArray.map { raw ->
            val f = raw.jsonObject
            Record("chatitem", f.getValue("id").jsonPrimitive.content, JsonObject(f.filterKeys { it != "id" }))
        }
        val turns = ChatTurnSemantics.turns(records)
        val agent = fixture["agent"]?.jsonPrimitive?.content ?: "Claude"
        val actual = buildJsonObject {
            put("head", headFacts(head))
            put("headProbes", JsonArray(fixture["headProbes"]?.jsonArray.orEmpty().map { headFacts(Record("chat", "a:probe", it.jsonObject)) }))
            put("turnSizes", JsonArray(turns.map { JsonPrimitive(it.size) }))
            put("items", JsonArray(records.map { record ->
                val item = ChatTurnSemantics.read(record)
                buildJsonObject {
                    put("id", item.id); put("said", ChatTurnSemantics.said(item)); put("note", ChatTurnSemantics.note(item, agent)?.let(::JsonPrimitive) ?: JsonNull)
                    put("thought", ChatTurnSemantics.thought(item)); put("quiet", ChatTurnSemantics.quiet(item)); put("report", reportFacts(ChatTurnSemantics.report(item.text)))
                    put("repeatsFailure", ChatTurnSemantics.repeats(item, head["answer"]?.jsonPrimitive?.content.orEmpty()))
                }
            }))
            put("turns", JsonArray(turns.mapIndexed { index, turn ->
                val ending = ChatTurnSemantics.ending(turn, index == turns.lastIndex, head["state"]?.jsonPrimitive?.content ?: "done")
                val steps = ChatTurnSemantics.steps(turn, ending)
                val words = ChatTurnSemantics.doneWords(ending, ChatTurnSemantics.worked(turn))
                buildJsonObject {
                    put("ids", strings(turn.map { it.id })); put("ending", ending)
                    put("worked", ChatTurnSemantics.worked(turn)?.let(::JsonPrimitive) ?: JsonNull); put("doneWords", words)
                    put("thoughtIds", strings(turn.filter(ChatTurnSemantics::thought).map { it.id })); put("thoughtWords", ChatTurnSemantics.thoughtWords(turn.filter(ChatTurnSemantics::thought)))
                    put("stepsAfterEnding", JsonArray(steps.map(::stepFacts))); put("runningSteps", JsonArray(ChatTurnSemantics.steps(turn, ending, true).map(::stepFacts)))
                    put("liveCandidates", JsonArray(ChatTurnSemantics.live(turn).map { candidate ->
                        buildJsonObject { put("id", candidate.id); put("name", candidate.name); put("since", candidate.since?.let { JsonPrimitive(it / 1000.0) } ?: JsonNull) }
                    }))
                    put("summary", if (steps.isEmpty()) words else "$words · ${steps.size} ${if (steps.size == 1) "step" else "steps"}")
                    put("failedCount", steps.count { it.state == "failed" })
                }
            }))
            put("spans", strings(fixture["spans"]?.jsonArray.orEmpty().map { ChatTurnSemantics.span(it.jsonPrimitive.double) }))
            put("problem", problemFacts(ChatTurnSemantics.problem(head["answer"]?.jsonPrimitive?.content.orEmpty(), agent)))
            put("problemProbes", JsonArray(fixture["problemProbes"]?.jsonArray.orEmpty().map { problemFacts(ChatTurnSemantics.problem(it.jsonPrimitive.content, agent)) }))
        }
        assertSubset(fixture.getValue("expect"), actual, name)
        val now = fixture["sourceDerivedDisplay"]?.jsonObject?.get("now")?.jsonPrimitive?.longOrNull?.times(1000) ?: 100_000_000L
        val messages = ChatTranscript.messages(head, records, emptyList(), now)
        when (name.substringBefore('-')) {
            "01" -> assertEquals(listOf(MessageRole.USER, MessageRole.ASSISTANT, MessageRole.USER, MessageRole.USER, MessageRole.ASSISTANT), messages.map { it.role })
            "02" -> assertTrue(messages.isEmpty())
            "03" -> {
                assertEquals("Clean checkout.\n\nSubmodules.", messages.single { it.work?.kind == "thought" }.work?.text)
                assertTrue(messages.none { it.text.contains("live stream thinking") })
            }
            "04" -> {
                assertEquals(1, messages.size); assertEquals("report", messages.single().work?.kind)
                assertTrue(messages.none { it.role == MessageRole.USER || it.text.trim() == "(quiet)" })
            }
            "05" -> assertEquals(listOf("report", "report", null), messages.map { it.work?.kind })
            "06", "07" -> {
                assertNotNull(messages.singleOrNull { it.work?.kind == "subagents" })
                assertTrue(messages.none { it.work?.kind == "actions" })
            }
            "08" -> {
                assertFalse(ChatTurnSemantics.isLive(head, 100_000_000L))
                assertTrue(ChatTurnSemantics.isLive(head, 99_999_000L))
                assertFalse(ChatTurnSemantics.isLive(head, 100_001_000L))
                assertTrue(messages.none { it.work?.kind in setOf("subagents", "actions") })
                assertEquals("I will compare both.", messages.last().text)
            }
            "09" -> {
                assertTrue(ChatTurnSemantics.isLive(head, now))
                assertFalse(ChatTurnSemantics.isLive(Record("chat", "a:missing", fixture.getValue("headProbes").jsonArray.first().jsonObject), now))
            }
            "10" -> assertEquals("Worked for 15s", messages.single { it.role == MessageRole.ASSISTANT }.work?.words)
            "11" -> {
                assertEquals(listOf(MessageRole.USER, MessageRole.ASSISTANT), messages.map { it.role })
                assertNull(messages.last().work); assertFalse(ChatTurnSemantics.isLive(head, now))
            }
            "12" -> {
                assertNull(messages.single { it.work?.kind == "subagents" }.work?.subagents?.single()?.since)
                assertEquals("Thought", messages.single { it.work?.kind == "thought" }.work?.words)
            }
            "13" -> {
                assertEquals("You stopped after 38s", messages.last().text)
                assertTrue(messages.none { it.work?.kind == "actions" })
            }
            "14" -> {
                assertEquals(listOf(MessageRole.USER, MessageRole.WORK), messages.map { it.role })
                assertEquals("failure", messages.last().work?.kind); assertTrue(messages.none { it.text.contains("API Error") })
                val bare = ChatTranscript.messages(head.copy(fields = JsonObject(head.fields + ("answer" to JsonPrimitive("connection reset")))), emptyList(), emptyList(), now)
                assertEquals("The connection dropped partway.", bare.single().work?.title); assertNull(bare.single().work?.question)
            }
            "15" -> {
                val work = messages.last().work!!
                assertEquals("Checking the sources.\n\nFound it on IGN.", work.text)
                assertFalse(work.text.contains("Which scenes?")); assertTrue(ChatTurnSemantics.choices(head).isEmpty())
            }
        }
    }

    private fun assertSubset(expected: JsonElement, actual: JsonElement, path: String) {
        when (expected) {
            is JsonObject -> {
                assertTrue("$path must be an object", actual is JsonObject)
                for ((key, value) in expected) {
                    // Full StepWords wording/site discovery and desktop repeat rows are outside this bounded port.
                    if (key in setOf("line", "hosts", "runs", "why")) continue
                    val found = actual.jsonObject[key] ?: error("Missing $path.$key")
                    assertSubset(value, found, "$path.$key")
                }
            }
            is JsonArray -> {
                assertTrue("$path must be an array", actual is JsonArray); assertEquals(path, expected.size, actual.jsonArray.size)
                expected.forEachIndexed { index, value -> assertSubset(value, actual.jsonArray[index], "$path[$index]") }
            }
            is JsonPrimitive -> if (expected != JsonNull && !expected.isString && expected.doubleOrNull != null) {
                assertEquals(path, expected.double, actual.jsonPrimitive.double, 0.000001)
            } else assertEquals(path, expected, actual)
        }
    }
    private fun strings(values: List<String>) = JsonArray(values.map(::JsonPrimitive))
    private fun headFacts(head: Record) = buildJsonObject {
        val f = ChatTurnSemantics.facts(head)
        put("state", ChatTurnSemantics.text(f, "state").ifEmpty { "done" }); put("started", ChatTurnSemantics.number(f, "started") ?: 0.0)
        put("updated", ChatTurnSemantics.updatedSeconds(head)); put("asks", strings(ChatTurnSemantics.choices(head)))
    }
    private fun stepFacts(step: ChatStep) = buildJsonObject {
        put("id", step.id); put("state", step.state)
        put("began", step.began?.let { JsonPrimitive(it / 1000.0) } ?: JsonNull); put("ended", step.ended?.let { JsonPrimitive(it / 1000.0) } ?: JsonNull)
    }
    private fun reportFacts(report: ChatSubagentReport?): JsonElement = report?.let { buildJsonObject {
        put("name", it.name); put("id", it.id); put("state", it.state); put("body", it.body); put("gist", it.gist)
    } } ?: JsonNull
    private fun problemFacts(problem: ChatFailure) = buildJsonObject { put("kind", problem.kind); put("title", problem.title); put("detail", problem.detail) }

    companion object {
        @JvmStatic @Parameterized.Parameters(name = "{0}")
        fun fixtures(): Collection<Array<Any>> {
            val file = generateSequence(File(System.getProperty("user.dir")).absoluteFile) { it.parentFile }
                .map { File(it, "Android/parity/chat-work/fixtures.json") }.first { it.isFile }
            val cases = Json.parseToJsonElement(file.readText()).jsonObject.getValue("cases").jsonArray
            check(cases.size == 15)
            return cases.map { arrayOf<Any>(it.jsonObject.getValue("id").jsonPrimitive.content, it.jsonObject) }
        }
    }
}
