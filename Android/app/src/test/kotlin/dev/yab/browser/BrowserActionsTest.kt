package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

/** Ordering is asserted by visible lists, and late native replies cross real controller transitions. */
@OptIn(ExperimentalCoroutinesApi::class)
class BrowserActionsTest {
    private class Repository(var snapshot: BrowserSnapshot) : BrowserRepository {
        override suspend fun load() = snapshot
        override suspend fun save(snapshot: BrowserSnapshot) { this.snapshot = snapshot }
    }
    private class Engine : BrowserEngine {
        data class Search(val tab: String, val query: BrowserFindQuery, val direction: BrowserFindDirection, val answer: (BrowserFindResult?) -> Unit)
        val searches = mutableListOf<Search>()
        val cleared = mutableListOf<String>()
        val navigated = mutableListOf<String>()
        val activated = mutableListOf<String>()
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) { activated += tab.id }
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) { navigated += tab.id }
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override fun close(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        override fun find(tabId: String, query: BrowserFindQuery, direction: BrowserFindDirection, answer: (BrowserFindResult?) -> Unit): Boolean {
            searches += Search(tabId, query, direction, answer); return true
        }
        override fun clearFind(tabId: String) { cleared += tabId }
    }
    private fun tab(id: String, place: TabPlace = TabPlace.TODAY, folder: String? = null) =
        BrowserTab(id, "https://$id.example/", id, place, createdAt = 1, folderId = folder)
    private fun snapshot(tabs: List<BrowserTab> = listOf(tab("front"), tab("other"))) = BrowserSnapshot(
        spaces = listOf(BrowserSpace("space", "Personal", tabs = tabs, currentTabId = tabs.first().id,
            folders = listOf(BrowserFolder("folder", "Reading")))), selectedSpaceId = "space")

    @Test fun keepAppendsRootAndUnkeepPrecedesTodayWithoutReloadingOrRetainingFolder() = runTest {
        val tabs = listOf(tab("front"), tab("keep-me"), tab("already-kept", TabPlace.KEPT),
            tab("nested", TabPlace.KEPT, "folder"), tab("pin", TabPlace.PINNED), tab("last"))
        val repository = Repository(snapshot(tabs)); val engine = Engine()
        val controller = BrowserController(repository, engine, backgroundScope)
        runCurrent()
        val activations = engine.activated.toList()
        controller.keepTab("keep-me")
        var space = controller.state.value.space!!
        assertEquals(listOf("already-kept", "keep-me"), space.tabs.filter { it.place == TabPlace.KEPT && it.folderId == null }.map { it.id })
        controller.unkeepTab("nested")
        space = controller.state.value.space!!
        assertEquals(listOf("nested", "front", "last"), space.tabs.filter { it.place == TabPlace.TODAY }.map { it.id })
        assertNull(space.tabs.first { it.id == "nested" }.folderId)
        assertEquals(listOf(BrowserFolder("folder", "Reading")), space.folders)
        controller.keepTab("nested")
        assertEquals(listOf("already-kept", "keep-me", "nested"), controller.state.value.space!!.tabs.filter { it.place == TabPlace.KEPT }.map { it.id })
        val stable = controller.state.value.space
        controller.keepTab("nested"); controller.keepTab("pin"); controller.unkeepTab("pin"); controller.unkeepTab("front")
        assertEquals(stable, controller.state.value.space)
        assertEquals("front", controller.state.value.tab!!.id)
        assertEquals(activations, engine.activated)
        assertTrue(engine.navigated.isEmpty())
        runCurrent()
        assertEquals(controller.state.value.space, repository.snapshot.spaces.single())
    }

    @Test fun findCountsStepsOptionsEmptyQueryAndLateRepliesRespectTheCurrentSearch() = runTest {
        val repository = Repository(snapshot()); val engine = Engine()
        val controller = BrowserController(repository, engine, backgroundScope)
        runCurrent()
        controller.beginFind("parcel")
        val first = engine.searches.last()
        controller.find("city")
        val current = engine.searches.last()
        first.answer(BrowserFindResult(9, 20))
        assertTrue(controller.state.value.find!!.searching)
        current.answer(BrowserFindResult(1, 3))
        assertEquals(BrowserFindResult(1, 3), controller.state.value.find!!.result)
        controller.findNext()
        assertEquals(BrowserFindDirection.NEXT, engine.searches.last().direction)
        engine.searches.last().answer(BrowserFindResult(2, 3))
        controller.findNext(true)
        assertEquals(BrowserFindDirection.PREVIOUS, engine.searches.last().direction)
        engine.searches.last().answer(BrowserFindResult(1, 3))
        controller.findOptions(matchCase = true, wholeWord = true)
        assertEquals(BrowserFindQuery("city", true, true), engine.searches.last().query)
        assertEquals(BrowserFindDirection.START, engine.searches.last().direction)
        val options = engine.searches.last()
        controller.find("")
        val cleared = engine.searches.last()
        options.answer(BrowserFindResult(4, 8))
        cleared.answer(BrowserFindResult(0, 0))
        assertEquals("", controller.state.value.find!!.query.text)
        assertEquals(0, controller.state.value.find!!.result.total)
        val count = engine.searches.size
        controller.findNext()
        assertEquals(count, engine.searches.size)
        assertTrue(controller.back())
        cleared.answer(BrowserFindResult(3, 7))
        assertNull(controller.state.value.find)
        assertEquals("front", engine.cleared.last())
        assertFalse(controller.publicSnapshot().toString().contains("parcel"))
    }

    @Test fun findCannotSurviveSelectionProfileNavigationOrAccountOwnerReuse() = runTest {
        val repository = Repository(snapshot()); val engine = Engine()
        val controller = BrowserController(repository, engine, backgroundScope)
        runCurrent()
        controller.beginFind("first-owned-query")
        val old = engine.searches.last()
        controller.selectTab("other")
        assertNull(controller.state.value.find)
        old.answer(BrowserFindResult(1, 1))
        assertNull(controller.state.value.find)
        controller.beginFind("second-owned-query")
        controller.pageChanged("other", EnginePageState(url = "https://other.example/new", progress = 1f))
        assertNull(controller.state.value.find)
        controller.beginFind("third-owned-query")
        val sameId = engine.searches.last()
        controller.invalidateLocalOwnership()
        controller.beginFind("fourth-owned-query")
        sameId.answer(BrowserFindResult(10, 10))
        assertEquals("fourth-owned-query", controller.state.value.find!!.query.text)
        assertEquals(0, controller.state.value.find!!.result.total)
        controller.applySyncedSnapshot(controller.publicSnapshot()!!.let { it.copy(spaces = it.spaces.map { space -> space.copy(ownSignIns = true) }) })
        assertNull(controller.state.value.find)
        engine.searches.last().answer(null)
        assertNull(controller.state.value.find)
        controller.beginFind("native-document-owner")
        val native = engine.searches.last()
        native.answer(null)
        assertNull(controller.state.value.find)
        native.answer(BrowserFindResult(1, 2))
        assertNull(controller.state.value.find)
    }

    @Test fun privateFindIsRamOnlyAndBackgroundOrLockRevokesIt() = runTest {
        val repository = Repository(snapshot()); val engine = Engine()
        val controller = BrowserController(repository, engine, backgroundScope)
        runCurrent()
        controller.openUrl("https://private.example/", privately = true)
        controller.beginFind("private-search-canary")
        assertTrue(engine.searches.isEmpty())
        controller.unlockPrivate(true)
        controller.beginFind("private-search-canary")
        val pending = engine.searches.last()
        runCurrent()
        assertFalse(repository.snapshot.toString().contains("private-search-canary"))
        controller.backgrounded()
        assertNull(controller.state.value.find)
        pending.answer(BrowserFindResult(2, 5))
        assertNull(controller.state.value.find)
        assertTrue(controller.state.value.privateContentBlocked)
        controller.unlockPrivate(true); controller.beginFind("private-search-canary")
        controller.lockPrivate()
        assertNull(controller.state.value.find)
    }
}
