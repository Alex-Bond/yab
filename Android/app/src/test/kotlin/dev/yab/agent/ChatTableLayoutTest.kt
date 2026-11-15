package dev.yab.agent

import org.junit.Assert.*
import org.junit.Test

class ChatTableLayoutTest {
    @Test fun wideTableUsesAccountTitleLongDescriptionAndSource() {
        val rows = listOf(listOf("Account", "What's live", "24/7?", "Source"),
            listOf("@trtworld", "TRT World Live Now, started three weeks ago", "Yes", "x.com"),
            listOf("@Reuters", "Only single events: press conferences and launches", "No", "[x.com](https://x.com/Reuters)"))
        val layout = ChatTableLayout.read(rows)
        assertEquals(0, layout.title); assertEquals(listOf(1), layout.words)
        assertEquals(listOf(2), layout.foot); assertEquals(3, layout.source)
        assertEquals("Yes", layout.footLine(rows[1], rows[0]))
        assertEquals("https://x.com/Reuters", ChatTableLayout.sourceUrl(rows[2][3]))
        assertNull(ChatTableLayout.sourceUrl("javascript:alert(1)"))
    }
    @Test fun dateColumnIsKickerAndNumericFootKeepsItsLabel() {
        val rows = listOf(listOf("Date", "Name", "Price", "Link"), listOf("Oct 26", "Museum", "€12", "https://example.com"))
        val layout = ChatTableLayout.read(rows)
        assertEquals(0, layout.kicker); assertEquals(1, layout.title)
        assertEquals("Price €12", layout.footLine(rows[1], rows[0]))
    }
    @Test fun shortIntroAndConsecutiveListItemsStayInOneBubble() {
        val blocks = AgentMarkdown.blocks("## Before Monday\nThree things:\n- first\n- second\n\n```\nflag = true\n```\n\nThen ship.")
        assertEquals(listOf(listOf(0), listOf(1, 2, 3), listOf(4), listOf(5)), AgentMarkdown.parts(blocks))
    }
}
