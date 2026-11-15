package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

/** External-link adapter regression; same legacy APIs on both proof sides. */
@OptIn(ExperimentalCoroutinesApi::class)
class BrowserExternalUrlDedupTest {
    private class Repository(var snapshot: BrowserSnapshot) : BrowserRepository {
        override suspend fun load() = snapshot
        override suspend fun save(snapshot: BrowserSnapshot) { this.snapshot = snapshot }
    }
    private class Engine : BrowserEngine {
        data class Activation(val tab: BrowserTab, val profile: WebsiteProfile)
        val activated = mutableListOf<Activation>()
        val navigated = mutableListOf<Activation>()
        val closed = mutableListOf<String>()
        var onReconcile: ((List<BrowserSpace>) -> Unit)? = null
        var onPausePrivateMedia: (() -> Unit)? = null
        var onClose: (() -> Unit)? = null
        var onClearFind: (() -> Unit)? = null
        var reconciles = 0
        private val sessions = mutableMapOf<Pair<String, WebsiteProfile>, Any>()
        fun existingSession(id: String, profile: WebsiteProfile): Any? = sessions[id to profile]
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {
            activated += Activation(tab, profile)
            sessions.getOrPut(tab.id to profile) { Any() }
        }
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) { navigated += Activation(tab, profile) }
        override fun close(tabId: String) {
            closed += tabId
            val original = onClose; onClose = null; original?.invoke()
        }
        override fun pausePrivateMedia() {
            val original = onPausePrivateMedia; onPausePrivateMedia = null; original?.invoke()
        }
        override fun clearFind(tabId: String) {
            val original = onClearFind; onClearFind = null; original?.invoke()
        }
        override fun reconcileTabs(spaces: List<BrowserSpace>) {
            reconciles++
            val original = onReconcile
            onReconcile = null // A deterministic original callback, never a recursive replacement.
            original?.invoke(spaces)
        }
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private class Fixture(snapshot: BrowserSnapshot, scope: CoroutineScope) {
        val repository = Repository(snapshot)
        val engine = Engine()
        var ids = 0
        var clock = 100L
        val browser = BrowserController(repository, engine, scope, now = { clock }, newId = { "new-${++ids}" })
    }
    private fun tab(id: String, url: String = "https://article.test/$id", place: TabPlace = TabPlace.TODAY,
        folder: String? = null) = BrowserTab(id, url, "Title $id", place, createdAt = 1, folderId = folder)
    private fun snapshot(vararg tabs: BrowserTab, front: String = tabs.first().id) = BrowserSnapshot(
        spaces = listOf(BrowserSpace("personal", "Personal", tabs = tabs.toList(), currentTabId = front)), selectedSpaceId = "personal")

    @Test fun currentExternalPageClosesGalleryWithoutDuplicatingOrRenavigatingItsOriginalSession() = runTest {
        val front = tab("front")
        val f = Fixture(snapshot(front, tab("other")), backgroundScope); runCurrent()
        val profile = f.browser.state.value.space!!.websiteProfile
        val originalSession = checkNotNull(f.engine.existingSession(front.id, profile))
        f.browser.show(BrowserSurface.GALLERY)
        val galleryEpoch = f.browser.state.value.surfaceEpoch
        val beforeIds = f.ids
        val beforeNavigation = f.engine.navigated.toList()

        f.browser.openExternalUrl(front.url)

        assertEquals("EXTERNAL_CURRENT_PAGE_MUST_REUSE_ORIGINAL_TAB", front.id, f.browser.state.value.tab?.id)
        assertEquals(2, f.browser.state.value.space!!.tabs.size)
        assertEquals(BrowserSurface.PAGE, f.browser.state.value.surface)
        assertFalse(f.browser.state.value.galleryClosing)
        assertFalse(f.browser.finishGallery("personal", galleryEpoch, front.id))
        assertEquals(beforeIds, f.ids)
        assertEquals(beforeNavigation, f.engine.navigated)
        assertTrue(f.engine.closed.isEmpty())
        assertSame(originalSession, f.engine.existingSession(front.id, profile))
        assertEquals(profile, f.engine.activated.last().profile)
        runCurrent()
        assertEquals(front.id, f.repository.snapshot.spaces.single().currentTabId)
    }

    @Test fun existingTodayPageMovesToFirstTodayWithoutReplacingItsMetadataOrNativeNamespace() = runTest {
        val pin = tab("pin", place = TabPlace.PINNED)
        val first = tab("first")
        val match = tab("match").copy(openerId = first.id, hasDraft = true, hasTask = true, shared = true)
        val last = tab("last")
        val f = Fixture(snapshot(pin, first, match, last, front = first.id), backgroundScope); runCurrent()
        f.browser.selectTab(match.id)
        val profile = f.browser.state.value.space!!.websiteProfile
        val originalSession = checkNotNull(f.engine.existingSession(match.id, profile))
        f.browser.selectTab(first.id)
        val beforeNavigation = f.engine.navigated.toList()
        val beforeIds = f.ids

        f.browser.openExternalUrl(match.url)

        assertEquals("EXTERNAL_EXISTING_TODAY_MUST_REUSE_ORIGINAL_TAB", match.id, f.browser.state.value.tab?.id)
        val after = f.browser.state.value.space!!
        assertEquals(listOf(match.id, first.id, last.id), after.tabs.filter { it.place == TabPlace.TODAY }.map { it.id })
        assertEquals(listOf(pin), after.tabs.filter { it.place == TabPlace.PINNED })
        assertEquals(match.copy(lastActiveAt = f.clock), after.tabs.single { it.id == match.id })
        assertEquals(beforeIds, f.ids)
        assertEquals(beforeNavigation, f.engine.navigated)
        assertSame(originalSession, f.engine.existingSession(match.id, profile))
    }

    @Test fun pinnedRootKeptAndNestedKeptMatchesKeepTheirPlacesWhileOnlyRootKeptReorders() = runTest {
        for ((place, folder) in listOf(TabPlace.PINNED to null, TabPlace.KEPT to null, TabPlace.KEPT to "folder")) {
            val firstKept = tab("first-kept", place = TabPlace.KEPT)
            val match = tab("match", place = place, folder = folder)
            val today = tab("today")
            val initial = snapshot(firstKept, today, match, front = today.id).let { snapshot ->
                snapshot.copy(spaces = snapshot.spaces.map { it.copy(folders = listOf(BrowserFolder("folder", "Folder", open = false))) })
            }
            val f = Fixture(initial, backgroundScope); runCurrent()
            f.browser.openExternalUrl(match.url)
            val after = f.browser.state.value.space!!
            assertEquals(match.id, after.currentTabId)
            assertEquals(3, after.tabs.size)
            assertEquals(place, after.currentTab!!.place)
            assertEquals(folder, after.currentTab!!.folderId)
            assertEquals(if (place == TabPlace.KEPT && folder == null) listOf(match.id, today.id, firstKept.id)
                else listOf(firstKept.id, today.id, match.id), after.tabs.map { it.id })
            assertEquals(initial.spaces.single().folders.map { if (folder != null && it.id == folder) it.copy(open = true) else it }, after.folders)
            assertEquals(listOf(today.id), after.tabs.filter { it.place == TabPlace.TODAY }.map { it.id })
            if (place == TabPlace.KEPT) assertEquals(if (folder == null) listOf(match.id, firstKept.id) else listOf(firstKept.id, match.id),
                after.tabs.filter { it.place == TabPlace.KEPT }.map { it.id })
            assertTrue(f.engine.navigated.isEmpty())
        }
    }

    @Test fun exactResolvedAddressMatchesButFixtureStyleSchemeWwwSlashCaseAndFragmentFoldingIsNotApplied() = runTest {
        val canonical = "https://article.test/Case?x=1#part"
        val variants = listOf("http://article.test/Case?x=1#part", "https://www.article.test/Case?x=1#part",
            "https://article.test/Case/?x=1#part", "https://article.test/case?x=1#part",
            "https://article.test/Case?x=1#other", "https://article.test:443/Case?x=1#part",
            "https://article.test/a/../Case?x=1#part")
        for (different in variants) {
            val front = tab("front", canonical)
            val f = Fixture(snapshot(front), backgroundScope); runCurrent()
            f.browser.openExternalUrl(different)
            assertEquals(2, f.browser.state.value.space!!.tabs.size)
            assertNotEquals(front.id, f.browser.state.value.tab?.id)
            assertEquals(different, f.browser.state.value.tab?.url)
            assertEquals(different, f.engine.navigated.last().tab.url)
        }
        val f = Fixture(snapshot(tab("front", canonical)), backgroundScope); runCurrent()
        f.browser.openExternalUrl("  $canonical  ") // Existing BrowserAddress trimming, not a new equivalence rule.
        assertEquals("front", f.browser.state.value.tab?.id)
        assertEquals(1, f.browser.state.value.space!!.tabs.size)
    }

    @Test fun sameAddressInAnotherPublicSpaceDoesNotBorrowItsTabOrWebsiteProfile() = runTest {
        val elsewhere = tab("elsewhere", "https://article.test/shared")
        val here = tab("here")
        val personal = BrowserSpace("personal", "Personal", tabs = listOf(elsewhere), currentTabId = elsewhere.id)
        val work = BrowserSpace("work", "Work", ownSignIns = true, tabs = listOf(here), currentTabId = here.id)
        val f = Fixture(BrowserSnapshot(spaces = listOf(personal, work), selectedSpaceId = work.id), backgroundScope); runCurrent()
        f.browser.openExternalUrl(elsewhere.url)
        val selected = f.browser.state.value
        assertEquals(work.id, selected.selectedSpaceId)
        assertNotEquals(elsewhere.id, selected.tab?.id)
        assertEquals(2, selected.space!!.tabs.size)
        assertEquals(personal.tabs, selected.spaces.single { it.id == personal.id }.tabs)
        assertEquals(work.websiteProfile, f.engine.navigated.last().profile)
        assertFalse(f.engine.navigated.last().profile.isPrivate)
    }

    @Test fun privateFrontReturnsToExistingPublicDestinationWithoutBorrowingPrivateOrOtherSpaceSession() = runTest {
        val personalTab = tab("personal", "https://article.test/shared")
        val workTab = tab("work", personalTab.url)
        val personal = BrowserSpace("personal", "Personal", tabs = listOf(personalTab), currentTabId = personalTab.id)
        val work = BrowserSpace("work", "Work", ownSignIns = true, tabs = listOf(workTab), currentTabId = workTab.id)
        val f = Fixture(BrowserSnapshot(spaces = listOf(personal, work), selectedSpaceId = work.id), backgroundScope); runCurrent()
        val originalWorkSession = checkNotNull(f.engine.existingSession(workTab.id, work.websiteProfile))
        f.browser.openUrl(workTab.url, privately = true)
        f.browser.unlockPrivate(true)
        val privateTab = f.browser.state.value.tab!!
        val privateProfile = f.browser.state.value.space!!.websiteProfile
        val privateSession = checkNotNull(f.engine.existingSession(privateTab.id, privateProfile))
        val beforeNavigation = f.engine.navigated.toList()
        val beforeIds = f.ids

        f.browser.openExternalUrl(workTab.url)

        assertEquals("EXTERNAL_PUBLIC_MATCH_MUST_NOT_CREATE_OR_ADOPT_PRIVATE_TAB", workTab.id, f.browser.state.value.tab?.id)
        assertEquals(work.id, f.browser.state.value.selectedSpaceId)
        assertFalse(f.browser.state.value.tab!!.isPrivate)
        assertEquals(work.websiteProfile, f.engine.activated.last().profile)
        assertEquals(beforeIds, f.ids)
        assertEquals(beforeNavigation, f.engine.navigated)
        assertSame(originalWorkSession, f.engine.existingSession(workTab.id, work.websiteProfile))
        assertSame(privateSession, f.engine.existingSession(privateTab.id, privateProfile))
        assertTrue(f.engine.closed.isEmpty())
        runCurrent()
        assertTrue(f.repository.snapshot.spaces.none { it.isPrivate || it.tabs.any(BrowserTab::isPrivate) })
    }

    @Test fun newExternalUrlStillOpensOnePublicTodayPageAndClosesGalleryWhileBlankEntryDoesNothing() = runTest {
        val original = tab("front")
        val f = Fixture(snapshot(original), backgroundScope); runCurrent()
        f.browser.show(BrowserSurface.GALLERY)
        val epoch = f.browser.state.value.surfaceEpoch
        val target = "https://external.test/new?x=1#part"
        f.browser.openExternalUrl(target)
        assertEquals(2, f.browser.state.value.space!!.tabs.size)
        assertEquals(target, f.browser.state.value.tab?.url)
        assertEquals(TabPlace.TODAY, f.browser.state.value.tab?.place)
        assertFalse(f.browser.state.value.tab!!.isPrivate)
        assertEquals(BrowserSurface.PAGE, f.browser.state.value.surface)
        assertFalse(f.browser.state.value.galleryClosing)
        assertFalse(f.browser.finishGallery("personal", epoch, original.id))
        assertEquals(listOf(target), f.engine.navigated.map { it.tab.url })
        assertEquals(BrowserSpace.SHARED_PROFILE, f.engine.navigated.single().profile.id)
        val before = f.browser.state.value
        val beforeIds = f.ids
        f.browser.openExternalUrl("   ")
        assertEquals(before, f.browser.state.value)
        assertEquals(beforeIds, f.ids)
    }

    @Test fun ordinaryExplicitNewTabNavigationKeepsItsExistingNonExternalBehavior() = runTest {
        val original = tab("front")
        val f = Fixture(snapshot(original), backgroundScope); runCurrent()
        f.browser.openUrl(original.url, newTab = true, privately = false)
        assertEquals(2, f.browser.state.value.space!!.tabs.size)
        assertNotEquals(original.id, f.browser.state.value.tab?.id)
        assertEquals(original.url, f.engine.navigated.single().tab.url)
    }

    @Test fun lookupPrefersPinsThenKeptThenTodayDespiteConflictingFlatStorageOrder() = runTest {
        val address = "https://article.test/shared"
        for (includePins in listOf(true, false)) {
            val today = tab("today", address)
            val nested = tab("nested", address, TabPlace.KEPT, "folder")
            val root = tab("root", address, TabPlace.KEPT)
            val pins = if (includePins) listOf(tab("pin-first", address, TabPlace.PINNED), tab("pin-second", address, TabPlace.PINNED)) else emptyList()
            val initial = snapshot(*(listOf(today, nested, root) + pins).toTypedArray(), front = today.id).let { snapshot ->
                snapshot.copy(spaces = snapshot.spaces.map { it.copy(folders = listOf(BrowserFolder("folder", "Closed", open = false))) })
            }
            val f = Fixture(initial, backgroundScope); runCurrent()
            val beforePins = initial.spaces.single().tabs.filter { it.place == TabPlace.PINNED }
            f.browser.openExternalUrl(address)
            assertEquals("EXTERNAL_LOOKUP_MUST_USE_PIN_KEPT_TODAY_PRIORITY", if (includePins) "pin-first" else root.id,
                f.browser.state.value.tab?.id)
            assertEquals(initial.spaces.single().tabs.size, f.browser.state.value.space!!.tabs.size)
            assertEquals(beforePins.map { it.id }, f.browser.state.value.space!!.tabs.filter { it.place == TabPlace.PINNED }.map { it.id })
            assertFalse(f.browser.state.value.space!!.folders.single().open)
            assertEquals(0, f.ids)
            assertTrue(f.engine.navigated.isEmpty())
        }
    }

    @Test fun closedKeptTreeLookupUsesHierarchyAndRevealsOnlyTheSelectedRowsOriginalAncestors() = runTest {
        val address = "https://article.test/shared"
        val later = tab("later", address, TabPlace.KEPT, "b")
        val earlier = tab("earlier", address, TabPlace.KEPT, "a-child")
        val front = tab("front")
        val folders = listOf(BrowserFolder("a", "First", open = false),
            BrowserFolder("a-child", "Inside First", parentId = "a", open = false),
            BrowserFolder("b", "Second", open = false))
        val initial = snapshot(later, earlier, front, front = front.id).let { snapshot ->
            snapshot.copy(spaces = snapshot.spaces.map { it.copy(folders = folders) })
        }
        val f = Fixture(initial, backgroundScope); runCurrent()
        f.browser.show(BrowserSurface.GALLERY)
        val epoch = f.browser.state.value.surfaceEpoch
        f.browser.openExternalUrl(address)
        assertEquals("EXTERNAL_KEPT_LOOKUP_MUST_FOLLOW_TREE_BEFORE_FLAT_STORAGE", earlier.id, f.browser.state.value.tab?.id)
        val after = f.browser.state.value.space!!
        assertEquals(listOf(later.id, earlier.id, front.id), after.tabs.map { it.id })
        assertEquals(earlier.folderId, after.currentTab!!.folderId)
        assertEquals(TabPlace.KEPT, after.currentTab!!.place)
        assertEquals(folders.map { if (it.id in setOf("a", "a-child")) it.copy(open = true) else it }, after.folders)
        assertEquals(BrowserSurface.PAGE, f.browser.state.value.surface)
        assertFalse(f.browser.finishGallery("personal", epoch, earlier.id))
        assertEquals(0, f.ids)
        assertTrue(f.engine.navigated.isEmpty())
        runCurrent()
        assertEquals(after, f.repository.snapshot.spaces.single())
    }

    @Test fun duplicateDestinationSpaceOrTabCannotMutateOrSelectAnotherPublicNamespace() = runTest {
        for (duplicateSpace in listOf(false, true)) {
            val match = tab("match", "https://article.test/shared")
            val front = tab("front")
            val foreign = BrowserSpace(if (duplicateSpace) "work" else "personal", "Foreign", ownSignIns = true,
                tabs = listOf(if (duplicateSpace) tab("foreign") else match.copy(title = "Foreign match")),
                currentTabId = if (duplicateSpace) "foreign" else match.id)
            val work = BrowserSpace("work", "Work", tabs = listOf(front, match), currentTabId = front.id)
            val f = Fixture(BrowserSnapshot(spaces = listOf(foreign, work), selectedSpaceId = work.id), backgroundScope); runCurrent()
            f.browser.show(BrowserSurface.GALLERY)
            val before = f.browser.state.value
            val activations = f.engine.activated.toList()
            val navigations = f.engine.navigated.toList()
            f.browser.openExternalUrl(match.url)
            assertEquals("EXTERNAL_DUPLICATE_TARGET_MUST_NOT_BORROW_ANOTHER_NAMESPACE", before, f.browser.state.value)
            assertEquals(activations, f.engine.activated)
            assertEquals(navigations, f.engine.navigated)
            assertTrue(f.engine.closed.isEmpty())
            assertEquals(0, f.ids)
        }
    }

    @Test fun originalExternalFollowupRefusesOwnershipNavigationForegroundWindowAndProfileReentry() = runTest {
        for (change in listOf("ownership", "selection-aba", "foreground-aba", "window", "surface-aba", "profile-aba")) {
            val first = tab("first")
            val match = tab("match")
            val other = BrowserSpace("other", "Other", ownSignIns = true, tabs = listOf(tab("other-tab")), currentTabId = "other-tab")
            val f = Fixture(snapshot(first, match).let { it.copy(spaces = it.spaces + other) }, backgroundScope); runCurrent()
            val profile = f.browser.state.value.space!!.websiteProfile
            var called = false
            var afterInterruption: BrowserState? = null
            var activationCount = 0
            f.engine.onReconcile = {
                called = true
                when (change) {
                    "ownership" -> f.browser.invalidateLocalOwnership()
                    "selection-aba" -> { f.browser.selectSpace(other.id); f.browser.selectSpace("personal") }
                    "foreground-aba" -> { f.browser.backgrounded(); f.browser.foregrounded() }
                    "window" -> f.browser.invalidateWorkspaceWindow()
                    "surface-aba" -> { f.browser.show(BrowserSurface.SETTINGS); f.browser.show(BrowserSurface.PAGE) }
                    "profile-aba" -> { f.browser.changeSignIns("personal", true); f.browser.changeSignIns("personal", false) }
                }
                afterInterruption = f.browser.state.value
                activationCount = f.engine.activated.size
            }
            f.browser.openExternalUrl(match.url)
            assertTrue("Original reconcile callback was not reached", called)
            assertEquals("EXTERNAL_RECONCILE_MUST_NOT_SELECT_IN_A_RETIRED_ROUTE", afterInterruption, f.browser.state.value)
            assertEquals(first.id, f.browser.state.value.tab?.id)
            assertEquals(activationCount, f.engine.activated.size)
            assertEquals(profile, f.browser.state.value.space!!.websiteProfile)
            assertTrue(f.engine.navigated.isEmpty())
            assertEquals(0, f.ids)
        }
    }

    @Test fun privateFrontCannotBorrowNonfrontPublicDestinationAfterExactProfileOrRowAba() = runTest {
        for (change in listOf("profile-aba", "row-aba")) {
            val first = tab("first")
            val match = tab("match")
            val f = Fixture(snapshot(first, match), backgroundScope); runCurrent()
            f.browser.openUrl("https://private.test/original", privately = true)
            f.browser.unlockPrivate(true)
            val originalPrivate = f.browser.state.value.tab!!
            val privateProfile = f.browser.state.value.space!!.websiteProfile
            val originalHistory = f.browser.historyPresentationLifetime.value
            val originalHardware = f.browser.hardwareKeyRevision.value
            var called = false
            var afterInterruption: BrowserState? = null
            var activationCount = 0
            f.engine.onReconcile = {
                called = true
                when (change) {
                    "profile-aba" -> { f.browser.changeSignIns("personal", true); f.browser.changeSignIns("personal", false) }
                    "row-aba" -> {
                        val originalPublic = checkNotNull(f.browser.publicSnapshot())
                        f.browser.applySyncedSnapshot(originalPublic.copy(spaces = originalPublic.spaces.map { space ->
                            space.copy(tabs = space.tabs.filterNot { it.id == match.id })
                        }))
                        f.browser.applySyncedSnapshot(originalPublic)
                    }
                }
                // Selected-front counters cannot witness this nonfront destination ABA.
                assertEquals(originalHistory, f.browser.historyPresentationLifetime.value)
                assertEquals(originalHardware, f.browser.hardwareKeyRevision.value)
                afterInterruption = f.browser.state.value
                activationCount = f.engine.activated.size
            }
            val beforeNavigation = f.engine.navigated.toList()
            f.browser.openExternalUrl(match.url)
            assertTrue("Nonfront reconcile callback was not reached", called)
            assertEquals("EXTERNAL_NONFRONT_DESTINATION_ABA_MUST_RETIRE_ORIGINAL_FOLLOWUP", afterInterruption, f.browser.state.value)
            assertEquals(originalPrivate, f.browser.state.value.tab)
            assertEquals(privateProfile, f.browser.state.value.space!!.websiteProfile)
            assertEquals(activationCount, f.engine.activated.size)
            assertEquals(beforeNavigation, f.engine.navigated)
        }
    }

    @Test fun unchangedInactiveLifetimeAndHarmlessProgressKeepTheOriginalPublicReuseAvailable() = runTest {
        val first = tab("first")
        val match = tab("match")
        val f = Fixture(snapshot(first, match), backgroundScope); runCurrent()
        f.browser.backgrounded()
        val lifetime = f.browser.settingsPresentationLifetime.value
        assertFalse(lifetime.active)
        var called = false
        f.engine.onReconcile = {
            called = true
            f.browser.pageChanged(first.id, EnginePageState(progress = .5f))
        }
        f.browser.openExternalUrl(match.url)
        assertTrue(called)
        assertEquals("EXTERNAL_INACTIVE_UNCHANGED_SOURCE_MUST_KEEP_EXISTING_ENTRY_POLICY", match.id, f.browser.state.value.tab?.id)
        assertEquals(listOf(match.id, first.id), f.browser.state.value.space!!.tabs.map { it.id })
        assertEquals(lifetime, f.browser.settingsPresentationLifetime.value)
        assertEquals(.5f, f.browser.state.value.pageStates[first.id]!!.progress, 0f)
        assertTrue(f.engine.navigated.isEmpty())
        assertEquals(0, f.ids)
    }

    /** Pinned and already-first selection must retire when its original reconcile source is lost. */
    @Test fun pinnedAndAlreadyFirstExternalSelectCannotContinueAfterItsOwnReconcileRetiresTheRoute() = runTest {
        for (place in listOf(TabPlace.PINNED, TabPlace.TODAY)) {
            for (change in listOf("ownership", "selection", "profile", "window", "foreground-aba")) {
                val match = tab("match", place = place)
                val front = tab("front")
                val other = BrowserSpace("other", "Other", ownSignIns = true,
                    tabs = listOf(tab("other-tab")), currentTabId = "other-tab")
                val initial = snapshot(match, front, front = front.id).let { it.copy(spaces = it.spaces + other) }
                val f = Fixture(initial, backgroundScope); runCurrent()
                f.browser.show(BrowserSurface.GALLERY)
                var called = false
                var afterInterruption: BrowserState? = null
                var activationCount = -1
                f.engine.onReconcile = {
                    // PINNED and already-first TODAY have no adapter pre-edit.
                    // These hits reach their first changed-spaces callback during selection.
                    called = true
                    when (change) {
                        "ownership" -> f.browser.invalidateLocalOwnership()
                        "selection" -> f.browser.selectSpace(other.id)
                        "profile" -> f.browser.changeSignIns("personal", true)
                        "window" -> f.browser.invalidateWorkspaceWindow()
                        "foreground-aba" -> { f.browser.backgrounded(); f.browser.foregrounded() }
                    }
                    afterInterruption = f.browser.state.value
                    activationCount = f.engine.activated.size
                }
                f.browser.openExternalUrl(match.url)
                assertTrue("The original selectTab reconcile callback was not reached", called)
                assertEquals("EXTERNAL_OWN_SELECT_REENTRY_MUST_REFUSE_TRAILING_STATE_MUTATION",
                    afterInterruption, f.browser.state.value)
                assertEquals("EXTERNAL_OWN_SELECT_REENTRY_MUST_NOT_ACTIVATE_A_SUCCESSOR",
                    activationCount, f.engine.activated.size)
                assertEquals(0, f.ids)
                assertTrue(f.engine.navigated.isEmpty())
            }
        }
    }

    @Test fun originalPrivatePauseAndAbandonedCloseCallbacksCannotResumeAReplacementRoute() = runTest {
        for (phase in listOf("private-pause", "abandoned-close")) {
            val match = tab("match", place = TabPlace.PINNED)
            val front = tab("front")
            val f = Fixture(snapshot(match, front, front = front.id), backgroundScope); runCurrent()
            if (phase == "private-pause") {
                f.browser.openUrl("https://private.test/original", privately = true)
                f.browser.unlockPrivate(true)
            } else {
                f.browser.resizeWorkspace(true)
                f.browser.newTabBeside()
                assertNotNull(f.browser.state.value.workspace?.newPage)
            }
            var called = false
            var afterInterruption: BrowserState? = null
            var activationCount = 0
            var reconcileCount = 0
            val interrupt = {
                called = true
                f.browser.invalidateLocalOwnership()
                afterInterruption = f.browser.state.value
                activationCount = f.engine.activated.size
                reconcileCount = f.engine.reconciles
            }
            if (phase == "private-pause") f.engine.onPausePrivateMedia = interrupt else f.engine.onClose = interrupt
            val beforeNavigations = f.engine.navigated.toList()
            f.browser.openExternalUrl(match.url)
            assertTrue("The original owned callback was not reached", called)
            assertEquals("EXTERNAL_PAUSE_OR_CLOSE_RETIREMENT_MUST_STOP_OWN_CONTINUATION", afterInterruption, f.browser.state.value)
            assertEquals(activationCount, f.engine.activated.size)
            assertEquals(reconcileCount, f.engine.reconciles)
            assertEquals(beforeNavigations, f.engine.navigated)
        }
    }

    @Test fun retiredFindClearCallbackCannotReconcileTouchOrActivateTheSuccessor() = runTest {
        val match = tab("match", place = TabPlace.PINNED)
        val front = tab("front")
        val f = Fixture(snapshot(match, front, front = front.id), backgroundScope); runCurrent()
        f.browser.beginFind("original query")
        assertNotNull(f.browser.state.value.find)
        var called = false
        var afterInterruption: BrowserState? = null
        var activationCount = 0
        var reconcileCount = 0
        f.engine.onClearFind = {
            called = true
            f.browser.invalidateLocalOwnership()
            afterInterruption = f.browser.state.value
            activationCount = f.engine.activated.size
            reconcileCount = f.engine.reconciles
        }
        f.browser.openExternalUrl(match.url)
        assertTrue("The original selected Find clear callback was not reached", called)
        assertEquals("EXTERNAL_RETIRED_FIND_CLEAR_MUST_STOP_BEFORE_SUCCESSOR_RECONCILE", afterInterruption, f.browser.state.value)
        assertEquals(reconcileCount, f.engine.reconciles)
        assertEquals(activationCount, f.engine.activated.size)
        assertTrue(f.engine.navigated.isEmpty())
        assertEquals(0, f.ids)
    }

    @Test fun unregisteredWorkspaceLayoutChangeOrAbaRetiresOnlyTheOriginalExternalContinuation() = runTest {
        for (change in listOf("changed", "aba", "unchanged")) {
            val front = tab("front")
            val match = tab("match")
            val f = Fixture(snapshot(front, match), backgroundScope); runCurrent()
            var called = false
            var afterInterruption: BrowserState? = null
            var activationCount = 0
            f.engine.onReconcile = {
                called = true
                f.browser.resizeWorkspace(change != "unchanged")
                if (change == "aba") f.browser.resizeWorkspace(false)
                afterInterruption = f.browser.state.value
                activationCount = f.engine.activated.size
            }
            f.browser.openExternalUrl(match.url)
            assertTrue("The original layout callback was not reached", called)
            if (change == "unchanged") {
                assertEquals(match.id, f.browser.state.value.tab?.id)
                assertEquals(activationCount + 1, f.engine.activated.size)
            } else {
                assertEquals("EXTERNAL_LAYOUT_ABA_MUST_NOT_RESUME_ITS_OLD_SELECTION", afterInterruption, f.browser.state.value)
                assertEquals(front.id, f.browser.state.value.tab?.id)
                assertEquals(activationCount, f.engine.activated.size)
            }
            assertTrue(f.engine.navigated.isEmpty())
            assertEquals(0, f.ids)
        }
    }
}
