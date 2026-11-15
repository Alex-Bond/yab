package dev.yab.agent

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/** Uses only the pre-project API so the exact same test can run on the prior model. */
class ChatProjectPersistenceTest {
    @Test fun storedProjectSurvivesTheExistingAgentChatJsonRoundTrip() {
        val json = Json { ignoreUnknownKeys = true }
        val source = """{"id":"owned","origin":"agent","routine":"routine-one","project":"prj-flight"}"""
        val chat = json.decodeFromString<AgentChat>(source)
        val restored = json.parseToJsonElement(json.encodeToString(chat)).jsonObject
        assertEquals("prj-flight", restored["project"]?.jsonPrimitive?.content)
    }
}
