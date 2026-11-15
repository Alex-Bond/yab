package dev.yab.agent

import org.junit.Assert.*
import org.junit.Test

class AgentMarkdownTest {
    @Test fun rendererAcceptsWebLinksOnly() {
        assertTrue(AgentMarkdown.safeUrl("https://example.com/page"))
        for (url in listOf("yab://approve/id", "file:///private/key", "javascript:alert(1)", "https://", "intent://open")) assertFalse(url, AgentMarkdown.safeUrl(url))
    }
    @Test fun fencedCodeAndTablesStayTextRatherThanExecutingHtml() {
        val blocks = AgentMarkdown.blocks("# Title\n\n```html\n<script>alert(1)</script>\n```\n| a | b |\n|---|---|\n| 1 | 2 |")
        assertEquals(AgentMarkdown.Kind.HEADING, blocks[0].kind)
        assertEquals(AgentMarkdown.Kind.CODE, blocks[1].kind)
        assertEquals("<script>alert(1)</script>", blocks[1].text)
        assertEquals(3, blocks.size)
        assertEquals(AgentMarkdown.Kind.TABLE, blocks[2].kind)
        assertEquals(listOf(listOf("a", "b"), listOf("1", "2")), blocks[2].cells)
    }
    @Test fun fencedHtmlRemainsExactWhileSurroundingMarkupIsNormalized() {
        val blocks = AgentMarkdown.blocks("<b>Before</b>\n\n```html\n<b>literal</b><br/><strong>code</strong>\n```\n\n<strong>After</strong>")
        assertEquals("**Before**", blocks[0].text)
        assertEquals(AgentMarkdown.Kind.CODE, blocks[1].kind)
        assertEquals("<b>literal</b><br/><strong>code</strong>", blocks[1].text)
        assertEquals("**After**", blocks[2].text)
    }
}
