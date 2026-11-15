package dev.yab.browser

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Running consumer geometry with a controlled clock, not presentation/smoothness acceptance. */
class BrowserGalleryDeviceTest {
    @get:Rule val compose = createComposeRule()

    @Test fun choosingAnOpeningCardRetainsItsPoseAndActivatesTheActualPageUnderIt() = fixture { browser, activated ->
        compose.mainClock.autoAdvance = false
        try {
            compose.runOnIdle { browser.show(BrowserSurface.GALLERY) }
            compose.mainClock.advanceTimeBy(160)
            val target = compose.onNodeWithTag("browser.gallery.card.gallery-1", useUnmergedTree = true)
            val before = target.fetchSemanticsNode().boundsInRoot
            val root = compose.onRoot().fetchSemanticsNode().boundsInRoot
            assertTrue("The stack card did not grow to an intermediate pose", before.width > 30 && before.width < root.width - 10)
            // The front page covers the older card's center during the morph.
            // Tap its exposed strip, as a finger would, rather than another card.
            val front = compose.onNodeWithTag("browser.gallery.card.gallery-2", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            val exposedLeft = maxOf(before.left, root.left)
            val exposedRight = minOf(before.right, front.left, root.right)
            assertTrue("The older opening card has no exposed touch strip", exposedRight - exposedLeft > 8)
            compose.onRoot().performTouchInput {
                click(Offset((exposedLeft + exposedRight) / 2 - root.left,
                    (maxOf(before.top, root.top) + minOf(before.bottom, root.bottom)) / 2 - root.top))
            }
            compose.runOnIdle {
                assertEquals("gallery-1", activated.last())
                assertEquals("gallery-1", browser.state.value.tab?.id)
                assertEquals(BrowserSurface.GALLERY, browser.state.value.surface)
                assertTrue(browser.state.value.galleryClosing)
            }
            compose.mainClock.advanceTimeByFrame()
            val firstClosing = target.fetchSemanticsNode().boundsInRoot
            assertTrue("An interrupted choice snapped directly to the page", firstClosing.width < root.width - 1)
            assertTrue("An interrupted choice lost its current pose", firstClosing.width >= before.width - 2)
            compose.mainClock.advanceTimeBy(550)
            compose.runOnIdle {
                assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
                assertFalse(browser.state.value.galleryClosing)
            }
        } finally { compose.mainClock.autoAdvance = true }
    }

    @Test fun anOldClosingAnimationCannotDismissANewSameSpaceGallery() = fixture { browser, _ ->
        compose.mainClock.autoAdvance = false
        try {
            compose.runOnIdle { browser.show(BrowserSurface.GALLERY) }
            compose.mainClock.advanceTimeBy(550)
            compose.onNodeWithTag("browser.gallery.card.gallery-1", useUnmergedTree = true).performClick()
            compose.mainClock.advanceTimeBy(80)
            compose.runOnIdle {
                browser.show(BrowserSurface.SETTINGS)
                browser.show(BrowserSurface.GALLERY)
            }
            val newEpoch = browser.state.value.surfaceEpoch
            compose.mainClock.advanceTimeBy(650)
            compose.runOnIdle {
                assertEquals(newEpoch, browser.state.value.surfaceEpoch)
                assertEquals(BrowserSurface.GALLERY, browser.state.value.surface)
            }
            compose.onNodeWithTag("browser.gallery.cards").assertExists()
        } finally { compose.mainClock.autoAdvance = true }
    }

    @Test fun cancellingAnUpwardCardDragReturnsFromItsDrawnPose() = fixture { browser, _ ->
        compose.mainClock.autoAdvance = false
        try {
            compose.runOnIdle { browser.show(BrowserSurface.GALLERY) }
            compose.mainClock.advanceTimeBy(550)
            val target = compose.onNodeWithTag("browser.gallery.card.gallery-1", useUnmergedTree = true)
            val rest = target.fetchSemanticsNode().boundsInRoot
            val root = compose.onRoot().fetchSemanticsNode().boundsInRoot
            val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
            compose.onRoot().performTouchInput {
                down(Offset(rest.center.x - root.left, rest.center.y - root.top))
                moveBy(Offset(0f, -70f * density), delayMillis = 80)
            }
            compose.mainClock.advanceTimeByFrame()
            val dragged = target.fetchSemanticsNode().boundsInRoot
            assertTrue("The real drag did not lift its card", dragged.top < rest.top - 20 * density)
            compose.onRoot().performTouchInput { cancel() }
            compose.mainClock.advanceTimeByFrame()
            val returning = target.fetchSemanticsNode().boundsInRoot
            assertTrue("Cancelling snapped directly to the resting card", returning.top < rest.top - density)
            assertTrue("Cancelling moved away from the captured pose", returning.top >= dragged.top - density)
            compose.mainClock.advanceTimeBy(550)
            assertEquals(rest.top, target.fetchSemanticsNode().boundsInRoot.top, 2f)
            compose.runOnIdle {
                assertEquals(3, browser.state.value.galleryTabs.size)
                assertEquals(BrowserSurface.GALLERY, browser.state.value.surface)
            }
        } finally { compose.mainClock.autoAdvance = true }
    }

    @Test fun aSyncedRemovalDuringReturnReopensAUsableGalleryWithoutResurrectingTheCard() = fixture { browser, _ ->
        compose.mainClock.autoAdvance = false
        try {
            compose.runOnIdle { browser.show(BrowserSurface.GALLERY) }
            compose.mainClock.advanceTimeBy(550)
            compose.onNodeWithTag("browser.gallery.card.gallery-1", useUnmergedTree = true).performClick()
            compose.mainClock.advanceTimeBy(80)
            val oldEpoch = browser.state.value.surfaceEpoch
            compose.runOnIdle {
                assertTrue(browser.state.value.galleryClosing)
                val snapshot = requireNotNull(browser.publicSnapshot())
                browser.applySyncedSnapshot(snapshot.copy(spaces = snapshot.spaces.map { space ->
                    space.copy(tabs = space.tabs.filterNot { it.id == "gallery-1" }, currentTabId = "gallery-0")
                }))
            }
            compose.mainClock.advanceTimeBy(650)
            compose.runOnIdle {
                assertEquals(BrowserSurface.GALLERY, browser.state.value.surface)
                assertNotEquals(oldEpoch, browser.state.value.surfaceEpoch)
                assertFalse(browser.state.value.galleryClosing)
                assertTrue(browser.state.value.space!!.tabs.none { it.id == "gallery-1" })
            }
            compose.onNodeWithTag("browser.gallery.card.gallery-1", useUnmergedTree = true).assertDoesNotExist()
            compose.onNodeWithTag("browser.gallery.card.gallery-0", useUnmergedTree = true).performClick()
            compose.mainClock.advanceTimeBy(550)
            compose.runOnIdle {
                assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
                assertEquals("gallery-0", browser.state.value.tab?.id)
                assertTrue(browser.state.value.space!!.tabs.none { it.id == "gallery-1" })
            }
        } finally { compose.mainClock.autoAdvance = true }
    }

    @Test fun nativeNavigationDuringReturnRestartsTheGalleryWithTheActualNewDestination() = fixture { browser, _ ->
        compose.mainClock.autoAdvance = false
        try {
            compose.runOnIdle { browser.show(BrowserSurface.GALLERY) }
            compose.mainClock.advanceTimeBy(550)
            compose.onNodeWithTag("browser.gallery.card.gallery-1", useUnmergedTree = true).performClick()
            compose.mainClock.advanceTimeBy(80)
            val oldEpoch = browser.state.value.surfaceEpoch
            val destination = "https://gallery-1.test/changed"
            compose.runOnIdle {
                assertTrue(browser.state.value.galleryClosing)
                browser.pageChanged("gallery-1", EnginePageState(url = destination, title = "New destination", progress = 1f))
            }
            compose.mainClock.advanceTimeBy(650)
            compose.runOnIdle {
                assertEquals(BrowserSurface.GALLERY, browser.state.value.surface)
                assertNotEquals(oldEpoch, browser.state.value.surfaceEpoch)
                assertFalse(browser.state.value.galleryClosing)
                assertEquals(destination, browser.state.value.tab?.url)
            }
            compose.onNodeWithTag("browser.gallery.card.gallery-1", useUnmergedTree = true).performClick()
            compose.mainClock.advanceTimeBy(550)
            compose.runOnIdle {
                assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
                assertEquals(destination, browser.state.value.tab?.url)
            }
        } finally { compose.mainClock.autoAdvance = true }
    }

    @Test fun lonePrivatePlusKeepsNewTabTapAndItsFreshSpokenActionOpensTheExistingCloseCard() = fixture { browser, _ ->
        openPrivate(browser, "https://private-stack.test/one")
        val original = browser.state.value.tab!!
        val beforeField = stackAllTabs().action
        compose.onNodeWithTag("browser.chrome.stack", useUnmergedTree = true).performClick()
        compose.runOnIdle {
            assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
            assertTrue(browser.state.value.fieldIsPrivate)
            assertFalse("A saved Plus action entered All Tabs beneath Field", beforeField())
            browser.dismissSurface()
        }
        compose.waitForIdle()
        val fresh = stackAllTabs().action
        compose.runOnIdle {
            assertFalse(beforeField())
            assertTrue(fresh())
        }
        compose.waitForIdle()
        compose.onNodeWithTag("browser.gallery.card.${original.id}", useUnmergedTree = true).assertExists()
        closeCurrentPrivateCard(browser, original)
    }

    @Test fun loneBlankPrivateFrontHasARealCardAndReturnsWithoutInventingGalleryMembership() = fixture { browser, _ ->
        openPrivate(browser, "about:blank")
        val original = browser.state.value.tab!!
        assertTrue(original.isBlank)
        assertEquals(listOf(original.id), browser.state.value.space!!.tabs.map { it.id })
        assertTrue("The global blank filter must remain unchanged", browser.state.value.galleryTabs.isEmpty())
        val open = stackAllTabs().action
        compose.runOnIdle { assertTrue(open()) }
        compose.waitForIdle()
        compose.onNodeWithTag("browser.gallery.card.${original.id}", useUnmergedTree = true).performClick()
        compose.waitForIdle()
        compose.runOnIdle {
            assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
            assertEquals(original, browser.state.value.tab)
            assertTrue(browser.state.value.galleryTabs.isEmpty())
        }
        val fresh = stackAllTabs().action
        compose.runOnIdle { assertTrue(fresh()) }
        compose.waitForIdle()
        closeCurrentPrivateCard(browser, original)
        openPrivate(browser, "about:blank")
        openPrivate(browser, "about:blank")
        assertEquals(2, browser.state.value.space!!.tabs.size)
        assertTrue(browser.state.value.space!!.tabs.all { it.isBlank && it.isPrivate })
        val multiple = compose.onNodeWithTag("browser.chrome.stack", useUnmergedTree = true).fetchSemanticsNode().config
        assertFalse("The lone-front override must not offer a partial two-blank gallery", multiple.contains(SemanticsActions.CustomActions))
    }

    @Test fun savedPrivateStackActionCannotBorrowLockForegroundAccountOrCoveredSceneRecovery() = fixture { browser, _ ->
        openPrivate(browser, "https://private-stack.test/owner")
        val beforeLock = stackAllTabs().action
        compose.runOnIdle { browser.lockPrivate(); assertFalse(beforeLock()) }
        compose.waitForIdle()
        compose.onNodeWithTag("browser.chrome.stack", useUnmergedTree = true).assertDoesNotExist()
        compose.onNodeWithText("Private is Locked").assertExists()
        compose.runOnIdle { browser.unlockPrivate(true) }
        compose.waitForIdle()
        compose.runOnIdle { assertFalse(beforeLock()) }
        val changes: List<(BrowserController) -> Unit> = listOf(
            { it.lockPrivate(); it.unlockPrivate(true) },
            { it.backgrounded(); it.foregrounded(); it.unlockPrivate(true) },
            { it.invalidateLocalOwnership() },
            { it.show(BrowserSurface.SETTINGS); it.dismissSurface() },
        )
        for (change in changes) {
            val old = stackAllTabs().action
            compose.runOnIdle {
                change(browser)
                assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
                assertFalse("An old Plus action revived after source recovery", old())
            }
            compose.waitForIdle()
            assertNotSame(old, stackAllTabs().action)
        }
        val fresh = stackAllTabs().action
        compose.runOnIdle { assertTrue(fresh()) }
        compose.waitForIdle()
        compose.onNodeWithTag("browser.gallery.cards").assertExists()
    }

    @Test fun aCoalescedBlankUrlABADuringReturnCannotFinishTheOriginalGallery() = fixture { browser, _ ->
        openPrivate(browser, "about:blank")
        val original = browser.state.value.tab!!
        val open = stackAllTabs().action
        compose.runOnIdle { assertTrue(open()) }
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        try {
            val epoch = browser.state.value.surfaceEpoch
            compose.onNodeWithTag("browser.gallery.card.${original.id}", useUnmergedTree = true).performClick()
            compose.mainClock.advanceTimeBy(80)
            compose.runOnIdle {
                assertEquals(TabPlace.TODAY, browser.state.value.tab?.place)
                browser.openUrl("https://private-stack.test/replacement", newTab = false, privately = true)
                assertEquals(original.id, browser.state.value.tab?.id)
                assertEquals(epoch, browser.state.value.surfaceEpoch)
                assertEquals(BrowserSurface.GALLERY, browser.state.value.surface)
                assertEquals("https://private-stack.test/replacement", browser.state.value.tab?.url)
                browser.openUrl(original.url, newTab = false, privately = true)
                assertEquals(original.id, browser.state.value.tab?.id)
                assertEquals(BrowserSurface.GALLERY, browser.state.value.surface)
                assertEquals(epoch, browser.state.value.surfaceEpoch)
                assertEquals(original.url, browser.state.value.tab?.url)
            }
            compose.mainClock.advanceTimeBy(700)
            compose.runOnIdle {
                assertEquals(BrowserSurface.GALLERY, browser.state.value.surface)
                assertNotEquals(epoch, browser.state.value.surfaceEpoch)
            }
            compose.onNodeWithTag("browser.gallery.card.${original.id}", useUnmergedTree = true).assertExists()
        } finally { compose.mainClock.autoAdvance = true }
    }

    @Test fun coalescedPrivateUrlABARebindsTheRenderedActionAndPublicPlusHasNoPrivateAction() = fixture { browser, _ ->
        val publicConfig = compose.onNodeWithTag("browser.chrome.stack", useUnmergedTree = true).fetchSemanticsNode().config
        assertFalse(publicConfig.contains(SemanticsActions.CustomActions))
        openPrivate(browser, "https://private-stack.test/source-a")
        val original = browser.state.value.tab!!
        val epoch = browser.state.value.surfaceEpoch
        val old = stackAllTabs().action
        compose.runOnIdle {
            browser.pageChanged(original.id, EnginePageState(url = "https://private-stack.test/source-b", title = original.title))
            browser.pageChanged(original.id, EnginePageState(url = original.url, title = original.title))
            assertEquals(epoch, browser.state.value.surfaceEpoch)
            assertEquals(original.url, browser.state.value.tab?.url)
            assertFalse("Same final URL revived the old rendered action", old())
        }
        compose.waitForIdle()
        val fresh = stackAllTabs().action
        compose.runOnIdle { assertFalse(old()); assertTrue(fresh()) }
        compose.waitForIdle()
        compose.onNodeWithTag("browser.gallery.card.${original.id}", useUnmergedTree = true).assertExists()
    }

    private fun stackAllTabs(): CustomAccessibilityAction = compose.onNodeWithTag("browser.chrome.stack", useUnmergedTree = true)
        .fetchSemanticsNode().config[SemanticsActions.CustomActions].single { it.label == "Show All Tabs" }

    private fun openPrivate(browser: BrowserController, url: String) {
        compose.runOnIdle { browser.openUrl(url, privately = true); browser.unlockPrivate(true) }
        compose.waitForIdle()
        compose.runOnIdle {
            assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
            assertTrue(browser.state.value.space!!.isPrivate)
            assertTrue(browser.state.value.tab!!.isPrivate)
            assertFalse(browser.state.value.privateContentBlocked)
        }
    }

    private fun closeCurrentPrivateCard(browser: BrowserController, original: BrowserTab) {
        val close = compose.onNodeWithTag("browser.gallery.card.${original.id}", useUnmergedTree = true)
            .fetchSemanticsNode().config[SemanticsActions.CustomActions].single { it.label == "Close ${original.title}" }.action
        compose.runOnIdle { assertTrue(close()) }
        compose.waitForIdle()
        compose.runOnIdle {
            assertTrue(browser.state.value.spaces.first { it.isPrivate }.tabs.none { it.id == original.id })
            assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
            assertTrue(browser.state.value.fieldIsPrivate)
        }
    }

    private fun fixture(block: (BrowserController, MutableList<String>) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val tabs = (0..2).map { BrowserTab("gallery-$it", "https://gallery-$it.test", "Gallery $it", createdAt = 1) }
        val snapshot = BrowserSnapshot(spaces = listOf(BrowserSpace("gallery-space", "Gallery", tabs = tabs, currentTabId = tabs.last().id)),
            selectedSpaceId = "gallery-space", recency = mapOf("gallery-space" to tabs.reversed().map { it.id }))
        val repository = object : BrowserRepository {
            override suspend fun load() = snapshot
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }
        val activated = mutableListOf<String>()
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) { activated += tab.id }
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
            override fun goBack(tabId: String) {}
            override fun goForward(tabId: String) {}
            override fun reload(tabId: String) {}
            override fun stop(tabId: String) {}
            override fun close(tabId: String) {}
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        val browser = BrowserController(repository, engine, scope)
        try {
            compose.setContent {
                CompositionLocalProvider(LocalBrowserAccessibility provides BrowserAccessibilityPreferences(reduceMotion = false)) {
                    BrowserScreen(browser, thumbnail = { tab, modifier ->
                        Box(modifier.background(if (tab.id == "gallery-1") Color.Blue else Color.LightGray))
                    }) { _, _, modifier -> Box(modifier.fillMaxSize().background(Color.White)) }
                }
            }
            compose.waitUntil(10_000) { !browser.state.value.loading }
            compose.waitForIdle()
            block(browser, activated)
        } finally { scope.cancel() }
    }
}
