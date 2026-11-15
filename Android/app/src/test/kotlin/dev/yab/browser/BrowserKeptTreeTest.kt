package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class BrowserKeptTreeTest {
    private fun tab(id: String, folder: String? = null) = BrowserTab(id, "https://$id.test", id,
        place = TabPlace.KEPT, folderId = folder, createdAt = 1)
    private fun space() = BrowserSpace("s", "Personal",
        tabs = listOf(tab("before"), tab("inside", "f"), tab("nested", "n"), tab("after")),
        folders = listOf(BrowserFolder("f", "Folder"), BrowserFolder("n", "Nested", "f")))
    private val sequence = listOf("tab:before", "folder:f", "tab:inside", "folder:n", "tab:nested", "tab:after")

    @Test fun importedSiblingOrderMixesTabsAndFoldersAtEveryLevel() {
        val original = space()
        val order = mapOf("tab:before" to "A", "folder:f" to "B", "tab:inside" to "C",
            "folder:n" to "D", "tab:nested" to "E", "tab:after" to "F")
        val received = original.copy(keptOrder = BrowserKeptTree.importedOrder(original, order))
        assertEquals(sequence, received.keptOrder)
        assertEquals(sequence, BrowserKeptTree.rows(received).map { it.key })
        assertEquals(listOf(0, 0, 1, 1, 2, 0), BrowserKeptTree.rows(received).map { it.depth })
        assertEquals(sequence, BrowserKeptTree.rows(received.copy(tabs = received.tabs.reversed(), folders = received.folders.reversed())).map { it.key })
    }

    @Test fun foldingHidesOnlyDescendantsAndSurvivesDiskRoundTrip() {
        val original = space().copy(keptOrder = sequence)
        val folded = original.copy(folders = original.folders.map { if (it.id == "f") it.copy(open = false) else it })
        val restored = Json.decodeFromString<BrowserSpace>(Json.encodeToString(folded))
        assertEquals(listOf("tab:before", "folder:f", "tab:after"), BrowserKeptTree.rows(restored).map { it.key })
        assertEquals(sequence, BrowserKeptTree.rows(restored, includeClosed = true).map { it.key })
        val opened = restored.copy(folders = restored.folders.map { it.copy(open = true) })
        assertEquals(sequence, BrowserKeptTree.rows(opened).map { it.key })
    }

    @Test fun malformedParentsCannotHideOrRepeatKeptItems() {
        val folders = listOf(BrowserFolder("a", "A", "b"), BrowserFolder("b", "B", "a"),
            BrowserFolder("self", "Self", "self"), BrowserFolder("orphan", "Orphan", "missing"))
        val s = BrowserSpace("s", "Personal", folders = folders,
            tabs = listOf(tab("a-tab", "a"), tab("lost", "missing"), tab("self-tab", "self"), tab("root"),
                tab("private").copy(isPrivate = true), tab("pin").copy(place = TabPlace.PINNED)))
        val rows = BrowserKeptTree.rows(s)
        assertEquals(setOf("folder:a", "folder:b", "folder:self", "folder:orphan", "tab:a-tab", "tab:lost", "tab:self-tab", "tab:root"), rows.map { it.key }.toSet())
        assertEquals(rows.size, rows.map { it.key }.toSet().size)
        assertEquals(0, rows.single { it.tab?.id == "lost" }.depth)
        assertEquals(0, rows.single { it.folder?.id == "a" }.depth)
        assertEquals(0, rows.single { it.folder?.id == "b" }.depth)
    }

    @Test fun missingFolderOrderUsesItsFirstDescendantAndCollectionKeysStayDistinct() {
        val s = BrowserSpace("s", "Personal", tabs = listOf(tab("same"), tab("inside", "same"), tab("after")),
            folders = listOf(BrowserFolder("same", "Same ID")))
        val order = BrowserKeptTree.importedOrder(s, mapOf("tab:same" to "A", "tab:inside" to "B", "tab:after" to "C"))
        assertEquals(listOf("tab:same", "folder:same", "tab:inside", "tab:after"), order)
        assertEquals(order, BrowserKeptTree.rows(s.copy(keptOrder = order)).map { it.key })
    }

    @Test fun oldProfilesKeepTheSameBytesUntilMixedOrderExists() {
        val encoded = Json { encodeDefaults = true }.encodeToString(space())
        assertFalse(encoded.contains("keptOrder"))
        assertTrue(Json { encodeDefaults = true }.encodeToString(space().copy(keptOrder = sequence)).contains("keptOrder"))
    }

    @Test fun excessiveDepthIsRepairedWithoutLosingTheLeaf() {
        val folders = (0..30).map { BrowserFolder("f$it", "Folder $it", if (it == 0) null else "f${it - 1}") }
        val s = BrowserSpace("s", "Personal", folders = folders, tabs = listOf(tab("leaf", "f30")))
        val rows = BrowserKeptTree.rows(s)
        assertEquals(32, rows.size)
        assertEquals(32, rows.map { it.key }.toSet().size)
        assertTrue(rows.maxOf { it.depth } <= 5)
        assertEquals("tab:leaf", rows.last().key)
    }
}
