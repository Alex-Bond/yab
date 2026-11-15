package dev.yab.agent

import org.junit.Assert.*
import org.junit.Test

class ChatTurnUnicodeTest {
    @Test fun liveNameLimitNeverSplitsAnAstralCodePoint(): Unit {
        val emoji = String(Character.toChars(0x1F9EA))
        val item = ChatTurnItem("agent", 1.0, "subagent", "spawnAgent", "  ${emoji.repeat(81)}  ", "", "running", null, null)
        val name = ChatTurnSemantics.live(listOf(item)).single().name
        assertEquals(emoji.repeat(80), name)
        assertEquals(80, name.codePointCount(0, name.length))
        assertEquals(160, name.length)
        assertNull(ChatTurnSemantics.live(listOf(item)).single().since)
    }

    @Test fun liveNameKeepsTheDecomposedAccentAtTheGraphemeBoundary(): Unit {
        val cluster = "e\u0301"
        val name = boundaryName(cluster)
        assertEquals("A".repeat(79) + cluster, name)
        assertTrue(name.endsWith("e\u0301"))
        assertFalse(name.endsWith("\u00E9"))
    }

    @Test fun liveNameKeepsTheWholeJoinedFamilyAtTheGraphemeBoundary(): Unit {
        val family = listOf(0x1F468, 0x1F469, 0x1F467, 0x1F466).joinToString("\u200D", transform = ::codePoint)
        assertEquals("A".repeat(79) + family, boundaryName(family))
    }

    @Test fun liveNameKeepsTheWholeRegionalIndicatorFlagAtTheGraphemeBoundary(): Unit {
        val flag = codePoint(0x1F1F5) + codePoint(0x1F1F9)
        assertEquals("A".repeat(79) + flag, boundaryName(flag))
    }

    @Test fun liveNameKeepsTheSkinToneModifierAtTheGraphemeBoundary(): Unit {
        val modified = codePoint(0x1F44D) + codePoint(0x1F3FD)
        assertEquals("A".repeat(79) + modified, boundaryName(modified))
    }

    private fun boundaryName(cluster: String): String {
        val item = ChatTurnItem("agent", 1.0, "subagent", "spawnAgent", "  ${"A".repeat(79)}${cluster}Z  ", "", "running", null, null)
        return ChatTurnSemantics.live(listOf(item)).single().name
    }

    private fun codePoint(value: Int): String = String(Character.toChars(value))
}
