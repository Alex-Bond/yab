package dev.yab.agent

import org.junit.Assert.*
import org.junit.Test

class ChatCardSiteOrderTest {
    @Test fun cardsKeepFirstEncounterOrderWhileInfoKeepsItsMostRecentVisitOrder() {
        val chat = AgentChat("a", messages = listOf(AgentMessage("m", MessageRole.ASSISTANT, "Answer", 1,
            work = ChatWork("w", "worked", steps = listOf("a.test", "b.test", "c.test", "a.test").mapIndexed { index, host ->
                ChatStep("$index", "tool", "Read", "https://$host", "", "done")
            }))))
        val card = ChatContents.read(chat, sitesInEncounterOrder = true)
        assertEquals(listOf("a.test", "b.test", "c.test"), card.sites.map { it.host })
        assertEquals(2, card.sites.first().visits)
        assertEquals(listOf("a.test", "c.test", "b.test"), ChatContents.read(chat).sites.map { it.host })
    }
}
