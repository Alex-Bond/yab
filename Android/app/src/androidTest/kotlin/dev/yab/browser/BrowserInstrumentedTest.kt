package dev.yab.browser

import android.graphics.Bitmap
import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.MainActivity
import dev.yab.android.EngineTestActivity
import dev.yab.android.YabApplication
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.engine.NativePagePrompts
import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserScreen
import dev.yab.browser.ui.BrowserChromeFrame
import dev.yab.browser.ui.LocalBrowserChromeObserver
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URI
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoView

/** Device proof uses the shipped controller, file repository, Gecko and content bridge. */
@RunWith(AndroidJUnit4::class)
class BrowserInstrumentedTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 60_000)
    fun publicProfileSurvivesProcessBoundaryWhilePrivateStateRemainsInMemory(): Unit = runBlocking {
        val file = File(context.cacheDir, "browser-state-${UUID.randomUUID()}.json")
        val disk = FileBrowserRepository(file)
        val writes = AtomicInteger()
        val repository = object : BrowserRepository {
            override suspend fun load() = disk.load()
            override suspend fun save(snapshot: BrowserSnapshot) { disk.save(snapshot); writes.incrementAndGet() }
        }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val restoredScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        try {
            val controller = onMain { BrowserController(repository, NoNetworkEngine(), scope) }
            await("profile load") { !controller.state.value.loading }
            val publicUrl = "https://public.fixture.invalid/${UUID.randomUUID()}"
            onMain {
                controller.openExternalUrl(publicUrl)
                controller.pageChanged(controller.state.value.tab!!.id, EnginePageState(url = publicUrl, title = "Saved public page", progress = 1f))
            }
            await("durable public visit") { file.isFile && file.readText().contains("Saved public page") }
            val beforePrivate = writes.get()
            val privateUrl = "https://private.fixture.invalid/${UUID.randomUUID()}"
            onMain {
                controller.openUrl(privateUrl, privately = true)
                assertTrue(controller.state.value.privateContentBlocked)
                controller.unlockPrivate(true)
                controller.pageChanged(controller.state.value.tab!!.id, EnginePageState(url = privateUrl, title = "Private secret", progress = 1f))
            }
            await("private operation flushed its filtered snapshot") { writes.get() > beforePrivate }
            assertTrue(controller.state.value.space!!.isPrivate)
            assertTrue(controller.state.value.tab!!.url == privateUrl)
            assertFalse(file.readText().contains(privateUrl))
            assertFalse(file.readText().contains("Private secret"))
            assertTrue(controller.state.value.history.none { it.url == privateUrl })
            scope.cancel()

            // Recreate the entire controller from the bytes, with no in-memory repository state.
            val restored = onMain { BrowserController(FileBrowserRepository(file), NoNetworkEngine(), restoredScope) }
            await("restored profile") { !restored.state.value.loading }
            assertEquals(publicUrl, restored.state.value.tab!!.url)
            assertEquals("Saved public page", restored.state.value.tab!!.title)
            assertEquals(publicUrl, restored.state.value.history.single().url)
            assertTrue(restored.state.value.spaces.none(BrowserSpace::isPrivate))
            assertNull(restored.state.value.persistenceError)
        } finally {
            scope.cancel()
            restoredScope.cancel()
            file.delete()
            File(file.parentFile, file.name + ".pending").delete()
        }
    }

    @Test(timeout = 240_000)
    fun actualGeckoPageReaderAndNativeBackKeepOneTodayTab(): Unit = runBlocking {
        FixtureServer().use { fixture ->
            withBrowser { controller, engine ->
                onMain { ownSpace(controller, "Article fixture"); controller.openUrl(fixture.url("/article")) }
                await("article load and content bridge", 60_000) {
                    controller.state.value.page.let { !it.loading && it.progress >= 1f && it.readerAvailable && it.title == "Delivery to Oslo" }
                }
                val id = controller.state.value.tab!!.id
                assertEquals(fixture.url("/article"), controller.state.value.tab!!.url)
                assertFalse("First navigation unexpectedly created a duplicate back entry", controller.state.value.page.canGoBack)
                val original = onMainSuspend { engine.readText(controller.state.value.tab!!) }
                assertTrue(original.text.contains("delivery city is Oslo"))
                shot("browser-article.png")
                onMain { controller.reader() }
                await("Reader entered") { controller.state.value.page.readerEnabled }
                shot("browser-reader.png")
                onMain { controller.reader() }
                await("Reader exited") { !controller.state.value.page.readerEnabled }

                onMain { controller.openUrl(fixture.url("/second"), newTab = false) }
                await("second document") {
                    controller.state.value.page.let { !it.loading && it.progress >= 1f && it.title == "Second document" && it.canGoBack }
                }
                assertEquals(id, controller.state.value.tab!!.id)
                onMain { assertTrue(controller.back()) }
                await("native session back to article") {
                    controller.state.value.page.let { !it.loading && it.title == "Delivery to Oslo" && it.url == fixture.url("/article") && it.canGoForward }
                }
                assertEquals(id, controller.state.value.tab!!.id)
                val returned = onMainSuspend { engine.readText(controller.state.value.tab!!) }
                assertTrue(returned.text.contains("delivery city is Oslo"))
                assertFalse(controller.state.value.page.readerEnabled)
                shot("browser-native-back.png")
                onMain { controller.forward() }
                await("native forward") { controller.state.value.page.title == "Second document" && !controller.state.value.page.loading }
                assertEquals(id, controller.state.value.tab!!.id)
            }
        }
    }

    @Test(timeout = 240_000)
    fun actualGeckoContainersSeparateSignInsAndPrivateSessionLeavesNoNavigationFile(): Unit = runBlocking {
        FixtureServer().use { fixture ->
            withBrowser { controller, engine ->
                val first = onMain { ownSpace(controller, "First sign-in"); controller.openUrl(fixture.url("/cookie/write?value=alpha")); controller.state.value.space!!.id }
                assertTrue(readLoaded(controller, engine, "Cookie write").contains("Cookie=alpha"))
                val second = onMain { ownSpace(controller, "Second sign-in"); controller.openUrl(fixture.url("/cookie/read")); controller.state.value.space!!.id }
                assertTrue(readLoaded(controller, engine, "Cookie read").contains("Cookie=empty"))
                onMain { controller.openUrl(fixture.url("/cookie/write?value=beta"), newTab = false) }
                assertTrue(readLoaded(controller, engine, "Cookie write").contains("Cookie=beta"))
                val betaTab = controller.state.value.tab!!.id
                val betaProfile = controller.state.value.space!!.websiteProfile
                val betaFile = navigationFile(betaTab)
                onMain { controller.selectSpace(first); controller.openUrl(fixture.url("/cookie/read"), newTab = false) }
                assertTrue(readLoaded(controller, engine, "Cookie read").contains("Cookie=alpha"))
                assertTrue(controller.state.value.page.canGoBack)

                val profileToClear = controller.state.value.space!!.websiteProfile.id
                val dormantFile = dormantCheckpoint(WebsiteProfile(profileToClear), fixture.url("/safe/dormant-clear"))
                onMain { engine.saveSessions() }
                await("second profile native checkpoint") { betaFile.isFile && betaFile.readText().contains(betaProfile.id) }
                onMainSuspend { engine.clearWebsiteData(setOf(profileToClear)) }
                onMain { controller.openUrl(fixture.url("/cookie/read")) }
                val cleared = readLoaded(controller, engine, "Cookie read")
                assertTrue("Scoped clearing raced the new session", cleared.contains("Cookie=empty"))
                assertTrue("Scoped clearing retained localStorage", cleared.contains("Storage=empty"))
                assertFalse("Clearing restored an obsolete native Back stack", controller.state.value.page.canGoBack)
                assertFalse("Disk-only state from the first profile survived clearing", dormantFile.exists())
                assertTrue("Clearing the first profile deleted second-profile native state", betaFile.isFile)
                onMain { controller.selectSpace(second) }
                assertEquals(betaTab, controller.state.value.tab!!.id)
                assertTrue("Clearing the first profile reset the second's native Back", controller.state.value.page.canGoBack)
                onMain { controller.openUrl(fixture.url("/cookie/read"), newTab = false) }
                val preserved = readLoaded(controller, engine, "Cookie read")
                assertTrue("Clearing the first container erased the second", preserved.contains("Cookie=beta"))
                assertTrue("Clearing the first container erased second localStorage", preserved.contains("Storage=beta"))

                onMain { controller.updateSettings(controller.state.value.settings.copy(lockPrivate = false)); controller.openUrl(fixture.url("/cookie/write?value=private-secret"), privately = true) }
                assertTrue(readLoaded(controller, engine, "Cookie write").contains("Cookie=private-secret"))
                val privateTab = controller.state.value.tab!!
                val file = File(context.filesDir, "navigation/${UUID.nameUUIDFromBytes(privateTab.id.toByteArray())}.json")
                assertFalse("Private Gecko session state was written to disk", file.exists())
                assertFalse(controller.publicSnapshot().toString().contains("private-secret"))
                onMain { controller.closeTab(privateTab.id) }
                await("closed private session") { controller.state.value.spaces.filter(BrowserSpace::isPrivate).all { it.tabs.isEmpty() } }
                onMain { controller.openUrl(fixture.url("/cookie/read"), privately = true) }
                assertTrue("Private cookies survived after its last session closed", readLoaded(controller, engine, "Cookie read").contains("Cookie=empty"))
                assertFalse(file.exists())
            }
        }
    }

    @Test(timeout = 60_000)
    fun privateJarSurvivesOneCardCloseButFinalCloseUndoStartsFresh(): Unit = runBlocking {
        FixtureServer().use { fixture ->
            withBrowser { controller, engine ->
                onMain {
                    controller.updateSettings(controller.state.value.settings.copy(lockPrivate = false))
                    controller.openUrl(fixture.url("/cookie/write?value=private-undo-secret"), privately = true)
                }
                val written = readLoaded(controller, engine, "Cookie write")
                assertTrue(written.contains("Cookie=private-undo-secret"))
                assertTrue(written.contains("Storage=private-undo-secret"))
                val first = controller.state.value.tab!!
                onMain { controller.openUrl(fixture.url("/cookie/read"), privately = true) }
                assertTrue(readLoaded(controller, engine, "Cookie read").contains("Cookie=private-undo-secret"))
                val second = controller.state.value.tab!!
                onMain {
                    controller.closeTab(first.id)
                    controller.openUrl(fixture.url("/cookie/read"), privately = true, newTab = false)
                }
                val retained = readLoaded(controller, engine, "Cookie read")
                assertTrue("Closing one of two Private cards ended cookies", retained.contains("Cookie=private-undo-secret"))
                assertTrue("Closing one of two Private cards ended localStorage", retained.contains("Storage=private-undo-secret"))
                onMain { controller.closeTab(second.id); controller.undoClose() }
                await("Private Undo restored the same card") { controller.state.value.tab?.id == second.id }
                val fresh = readLoaded(controller, engine, "Cookie read")
                assertTrue("Undo resurrected cookies from an ended Private session", fresh.contains("Cookie=empty"))
                assertTrue("Undo resurrected localStorage from an ended Private session", fresh.contains("Storage=empty"))
                assertEquals(second.url, controller.state.value.tab!!.url)
                assertFalse(navigationFile(first.id).exists())
                assertFalse(navigationFile(second.id).exists())
                assertFalse(controller.publicSnapshot().toString().contains("private-undo-secret"))
            }
        }
    }

    @Test(timeout = 60_000)
    fun permissionAnswerAfterOwnerChangesIsDeniedAndDismissAnswersExactlyOnce(): Unit = runBlocking {
        val scenario = ActivityScenario.launch(EngineTestActivity::class.java)
        val owns = AtomicBoolean(true)
        val answer = AtomicReference<Boolean?>()
        val answers = AtomicInteger()
        lateinit var prompts: NativePagePrompts
        var createdPrompts = false
        try {
            scenario.onActivity { activity ->
                prompts = NativePagePrompts(activity, { owns.get() }, requestFiles = { _, callback -> callback(emptyList()) })
                createdPrompts = true
                prompts.permission(GeckoSession(), "Fixture permission", "Allow this fixture to use your microphone?") {
                    answer.set(it); answers.incrementAndGet()
                }
            }
            await("native permission dialog") { allowButton() != null }
            shot("browser-permission-before-owner-change.png")
            owns.set(false)
            assertTrue("Allow button was not clickable", allowButton()!!.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            await("stale permission answer") { answer.get() != null }
            assertEquals(false, answer.get())
            assertEquals(1, answers.get())
            onMain { prompts.dismiss() }
            assertEquals(1, answers.get())

            owns.set(true)
            answer.set(null)
            onMain {
                prompts.permission(GeckoSession(), "Fixture permission", "This request is canceled by navigation") {
                    answer.set(it); answers.incrementAndGet()
                }
                prompts.dismiss()
                prompts.dismiss()
            }
            assertEquals(false, answer.get())
            assertEquals(2, answers.get())
        } finally {
            if (createdPrompts) onMain { prompts.dismiss() }
            scenario.close()
        }
    }

    @Test(timeout = 60_000)
    fun destroyedPromptWindowStillDeniesItsOriginalAnswerExactlyOnce(): Unit = runBlocking {
        val scenario = ActivityScenario.launch(EngineTestActivity::class.java)
        val answers = AtomicInteger()
        val answer = AtomicReference<Boolean?>()
        lateinit var prompts: NativePagePrompts
        try {
            scenario.onActivity { activity ->
                prompts = NativePagePrompts(activity, { true }, requestFiles = { _, reply -> reply(emptyList()) })
                prompts.permission(GeckoSession(), "Owned destroyed window", "Fictional permission") {
                    answer.set(it); answers.incrementAndGet()
                }
            }
            await("actual owned prompt before destruction") { prompts.pending.value }
            scenario.close()
            onMain { prompts.dismiss(); prompts.dismiss() }
            assertEquals(false, answer.get())
            assertEquals(1, answers.get())
            assertFalse(prompts.pending.value)
        } finally { scenario.close() }
    }

    @Test(timeout = 180_000)
    fun realSelectDateAndJavascriptConfirmationReturnNativeAnswersToTheDocument(): Unit = runBlocking {
        FixtureServer().use { fixture ->
            withBrowser { controller, engine ->
                onMain { ownSpace(controller, "Native form fixture"); controller.openUrl(fixture.url("/forms")) }
                assertTrue(readLoaded(controller, engine, "Native web forms").contains("Selection=pending"))
                clickText("Destination", className = "android.widget.Spinner")
                await("native select") { textNode("Oslo") != null }
                shot("browser-native-select.png")
                clickText("Oslo")
                awaitText(controller, engine, "Selection=Oslo")

                clickText("Choose delivery date")
                await("native date picker") { textNode("Set") != null }
                shot("browser-native-date.png")
                await("23rd day in the native calendar") { calendarDay(23) != null }
                assertTrue(calendarDay(23)!!.performAction(AccessibilityNodeInfo.ACTION_CLICK))
                clickText("Set")
                awaitText(controller, engine, "Date=2026-10-23")

                clickText("Confirm delivery")
                await("native JavaScript confirmation") { textNode("Send the parcel?") != null }
                shot("browser-native-confirm.png")
                clickText("Cancel")
                awaitText(controller, engine, "Confirmation=Canceled")
                clickText("Confirm delivery")
                await("second native confirmation") { textNode("Send the parcel?") != null }
                clickText("OK")
                awaitText(controller, engine, "Confirmation=Confirmed")
            }
        }
    }

    @Test(timeout = 120_000)
    fun systemNightModeKeepsTheActualActivityPrivateControllerAndSecureWindow(): Unit = runBlocking {
        org.junit.Assume.assumeTrue("Requires the disposable device", InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        val modes = context.getSystemService(UiModeManager::class.java)
        val originallyDark = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        lateinit var activityBefore: MainActivity
        lateinit var controllerBefore: BrowserController
        lateinit var settingsBefore: BrowserSettings
        var capturedSettings = false
        try {
            scenario.onActivity { activity ->
                activityBefore = activity
                controllerBefore = activityBrowser(activity)
            }
            await("actual activity browser") { !controllerBefore.state.value.loading }
            onMain {
                settingsBefore = controllerBefore.state.value.settings
                capturedSettings = true
                controllerBefore.updateSettings(settingsBefore.copy(appearance = BrowserAppearance.SYSTEM, welcomed = true, lockPrivate = false))
                controllerBefore.openUrl("https://private-uimode.fixture.invalid/${UUID.randomUUID()}", privately = true)
            }
            val privateTab = controllerBefore.state.value.tab!!
            assertTrue(privateTab.isPrivate)
            await("private secure window") { activityBefore.window.attributes.flags and android.view.WindowManager.LayoutParams.FLAG_SECURE != 0 }
            onMain { modes.setApplicationNightMode(if (originallyDark) UiModeManager.MODE_NIGHT_NO else UiModeManager.MODE_NIGHT_YES) }
            await("application uiMode change", 20_000) {
                val dark = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
                dark != originallyDark
            }
            scenario.onActivity { activity ->
                assertSame("System theme recreated the activity and lost private RAM", activityBefore, activity)
                val current = activityBrowser(activity)
                assertSame(controllerBefore, current)
                assertEquals(privateTab.id, current.state.value.tab!!.id)
                assertEquals(privateTab.url, current.state.value.tab!!.url)
                assertTrue(current.state.value.tab!!.isPrivate)
                assertTrue(activity.window.attributes.flags and android.view.WindowManager.LayoutParams.FLAG_SECURE != 0)
            }
        } finally {
            onMain {
                modes.setApplicationNightMode(if (originallyDark) UiModeManager.MODE_NIGHT_YES else UiModeManager.MODE_NIGHT_NO)
                if (capturedSettings) controllerBefore.updateSettings(settingsBefore)
            }
            scenario.close()
        }
    }

    private fun activityBrowser(activity: MainActivity): BrowserController = MainActivity::class.java.getDeclaredField("browser").let { field ->
        field.isAccessible = true
        field.get(activity) as BrowserController
    }

    private fun navigationFile(id: String) = File(context.filesDir, "navigation/${UUID.nameUUIDFromBytes(id.toByteArray())}.json")

    private suspend fun dormantCheckpoint(profile: WebsiteProfile, url: String): File {
        val tab = BrowserTab(UUID.randomUUID().toString(), url, createdAt = System.currentTimeMillis())
        val page = AtomicReference(EnginePageState())
        val engine = onMain {
            GeckoEngine(context, (context.applicationContext as YabApplication).runtime).also { native ->
                native.onState = { id, state -> if (id == tab.id) page.set(state) }
                native.activate(tab, profile)
            }
        }
        val file = navigationFile(tab.id)
        try {
            await("real dormant native document", 30_000) { page.get().let { !it.loading && it.progress >= 1f && it.title == "Safe page dormant-clear" } }
            onMain { engine.saveSessions() }
            await("real dormant native state written") { file.isFile && file.readText().contains(profile.id) }
        } finally { onMain { engine.dispose() } }
        // No future page callbacks can enqueue writes after dispose; wait for its
        // already-queued atomic checkpoint to stop changing before the next engine clears it.
        var changedAt = SystemClock.elapsedRealtime()
        var stamp = file.lastModified() to file.length()
        await("dormant writer quiescence") {
            val current = file.lastModified() to file.length()
            if (current != stamp) { stamp = current; changedAt = SystemClock.elapsedRealtime() }
            SystemClock.elapsedRealtime() - changedAt >= 300
        }
        return file
    }

    internal suspend fun withBrowser(configure: (GeckoEngine) -> Unit = {}, chromeFrames: ((BrowserChromeFrame) -> Unit)? = null,
        viewBound: ((GeckoView) -> Unit)? = null, paging: Boolean = false, historySwipe: Boolean = false,
        menuFrames: ((dev.yab.browser.ui.PageMenuFrame, dev.yab.browser.ui.BrowserPageMenuPose, Long) -> Unit)? = null,
        menuAnimations: Boolean? = null,
        translationMenu: (@androidx.compose.runtime.Composable () -> dev.yab.browser.ui.BrowserPageTranslationUi?)? = null,
        block: suspend (BrowserController, GeckoEngine) -> Unit) {
        val scenario = ActivityScenario.launch(EngineTestActivity::class.java)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val file = File(context.cacheDir, "gecko-browser-${UUID.randomUUID()}.json")
        lateinit var controller: BrowserController
        lateinit var engine: GeckoEngine
        var createdEngine = false
        var createdController = false
        try {
            scenario.onActivity { activity ->
                engine = GeckoEngine(activity, (activity.application as YabApplication).runtime)
                createdEngine = true
                engine.prompts = NativePagePrompts(activity, engine::owns) { _, answer -> answer(emptyList()) }
                configure(engine)
                controller = BrowserController(FileBrowserRepository(file), engine, scope)
                createdController = true
                engine.onState = controller::pageChanged
                if (historySwipe) engine.setHistorySwipeConsumer(dev.yab.browser.ui.BrowserHistorySwipeHostState(controller))
                activity.setContent {
                    var fixtureCovered by remember { mutableStateOf(false) }
                    CompositionLocalProvider(LocalBrowserChromeObserver provides chromeFrames,
                        dev.yab.browser.ui.LocalPageMenuDrawObserver provides menuFrames,
                        dev.yab.browser.ui.LocalPageMenuAnimationsEnabled provides menuAnimations) {
                    BrowserScreen(controller, onUnlockPrivate = { it(true) },
                        translationMenu = translationMenu?.invoke(),
                        onOverlayChange = { fixtureCovered = it },
                        capturePageMenuLease = captureMenu@ { generation ->
                            val source = controller.state.value
                            val tab = source.tab ?: return@captureMenu null
                            val space = source.space ?: return@captureMenu null
                            val native = engine.captureExternalActivityOwner() ?: return@captureMenu null
                            PageMenuLease(null, 0, tab.id, space.id, space.websiteProfile, native,
                                source.surfaceEpoch, generation, url = tab.url).takeIf {
                                it.ownsSource(controller.state.value, tab.url) && engine.ownsExternalActivity(native) &&
                                    native.session.settings.contextId == it.profile.id && native.session.settings.usePrivateMode == it.profile.isPrivate
                            }
                        }, pageMenuCurrent = { lease ->
                            val native = lease.nativeOwner as? GeckoEngine.ExternalActivityOwner
                            val url = lease.url
                            lease.account == null && lease.device == null && lease.accountEpoch == 0L && native != null && url != null &&
                                lease.ownsSource(controller.state.value, url) && native.session.settings.contextId == lease.profile.id &&
                                native.session.settings.usePrivateMode == lease.profile.isPrivate && engine.ownsExternalActivity(native)
                        }, pageMenuFieldCurrent = { lease, input ->
                            val native = lease.nativeOwner as? GeckoEngine.ExternalActivityOwner
                            val url = lease.url
                            lease.account == null && lease.device == null && lease.accountEpoch == 0L && native != null && url != null &&
                                controller.fieldInputCurrent(input) && lease.ownsDrawnField(controller.state.value, input, url) &&
                                native.session.settings.contextId == lease.profile.id &&
                                native.session.settings.usePrivateMode == lease.profile.isPrivate && engine.ownsExternalActivity(native)
                        },
                        onPagingVisibility = if (!paging) null else { lease, fieldEpoch ->
                            val current = controller.state.value
                            val normal = if (current.surface == BrowserSurface.PAGE && !current.privateContentBlocked)
                                setOfNotNull(current.tab?.id, current.workspace?.companion) else emptySet()
                            val extra = if (current.surface == BrowserSurface.PAGE && lease != null && controller.pageSwipeCurrent(lease, fieldEpoch))
                                listOfNotNull(lease.front.id, lease.before?.id, lease.after?.id).toSet() else emptySet()
                            engine.setVisibleTabs(normal + extra, recoveryIds = normal)
                        }, pageContent = { tab, profile, modifier ->
                        AndroidView(modifier = modifier.fillMaxSize(), factory = { viewContext ->
                            // Match MainActivity's shipped native view. The historySwipe
                            // option controls the consumer, not a replacement GeckoView type.
                            dev.yab.browser.engine.HistorySwipeView(viewContext).apply {
                                importantForAccessibility = if (tab.id == controller.state.value.tab?.id && !fixtureCovered) android.view.View.IMPORTANT_FOR_ACCESSIBILITY_AUTO else android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                                setSession(engine.session(tab, profile)); tag = tab.id; engine.bindView(tab.id, this)
                                viewBound?.invoke(this)
                            }
                        }, update = { view ->
                            val session = engine.session(tab, profile)
                            if (view.session !== session) {
                                (view.tag as? String)?.let { engine.unbindView(it, view) }
                                view.releaseSession(); view.setSession(session); view.tag = tab.id
                            }
                            engine.bindView(tab.id, view)
                            viewBound?.invoke(view)
                            view.importantForAccessibility = if (tab.id == controller.state.value.tab?.id && !fixtureCovered) android.view.View.IMPORTANT_FOR_ACCESSIBILITY_AUTO else android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                        }, onReset = null, onRelease = { view -> (view.tag as? String)?.let { engine.unbindView(it, view) }; view.releaseSession() })
                    })
                    }
                }
            }
            await("isolated browser profile") { !controller.state.value.loading }
            block(controller, engine)
        } finally {
            // Destroy the Activity's composition while its native engine is still
            // alive. A pending AndroidView update must not enter a disposed engine.
            try {
                scenario.close()
            } finally {
                onMain {
                    scope.cancel()
                    if (createdEngine) {
                        if (createdController) controller.state.value.spaces.flatMap { it.tabs }.forEach { engine.close(it.id) }
                        engine.dispose()
                    }
                }
                file.delete()
                File(file.parentFile, file.name + ".pending").delete()
            }
        }
    }

    internal fun ownSpace(controller: BrowserController, name: String) {
        controller.addSpace(name)
        controller.changeSignIns(controller.state.value.space!!.id, true)
        controller.dismissSurface()
    }

    private suspend fun readLoaded(controller: BrowserController, engine: GeckoEngine, title: String): String {
        val owner = onMain { controller.state.value.let { checkNotNull(it.tab) to checkNotNull(it.space).websiteProfile } }
        fun current() = controller.state.value.let { it.tab?.id == owner.first.id && it.tab?.url == owner.first.url &&
            it.space?.websiteProfile == owner.second && !it.privateContentBlocked }
        fun loaded(): Boolean {
            check(current()) { "The synthetic content read lost its original tab/profile/URL" }
            return controller.state.value.page.let { !it.loading && it.progress >= 1f && it.title == title }
        }
        await("$title loaded", 60_000, ::loaded)
        val deadline = SystemClock.elapsedRealtime() + 20_000
        var failure: Throwable? = null
        while (SystemClock.elapsedRealtime() < deadline) {
            try {
                if (loaded()) return onMainSuspend { check(current()); engine.readText(owner.first).text }
            }
            catch (error: CancellationException) {
                // A navigation can cancel the standalone bridge answer without cancelling
                // this test. Retry only this same logical owner; parent cancellation wins.
                currentCoroutineContext().ensureActive()
                check(current()) { "The synthetic content read was revoked by another owner" }
                failure = error
            }
            catch (error: Exception) { failure = error }
            delay(100)
        }
        throw AssertionError("$title content bridge did not answer", failure)
    }

    private fun allowButton(): AccessibilityNodeInfo? = instrumentation.uiAutomation.rootInActiveWindow
        ?.findAccessibilityNodeInfosByText("Allow")?.firstOrNull { it.isClickable && it.isEnabled }

    private fun textNode(text: String): AccessibilityNodeInfo? = OwnedWebControl.find(text, ignoreCase = true)

    private fun calendarDay(day: Int): AccessibilityNodeInfo? {
        val queue = java.util.ArrayDeque<AccessibilityNodeInfo>()
        instrumentation.uiAutomation.rootInActiveWindow?.let(queue::add)
        var visited = 0
        while (queue.isNotEmpty() && visited++ < 3000) {
            val node = queue.removeFirst()
            val description = node.contentDescription?.toString().orEmpty()
            val matches = node.text?.toString() == day.toString() || description.startsWith("$day ") || description.contains("October $day,")
            if (matches && node.isEnabled && node.isVisibleToUser && node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK }) return node
            repeat(node.childCount) { index -> node.getChild(index)?.let(queue::add) }
        }
        return null
    }

    private suspend fun clickText(text: String, className: String? = null) {
        fun target() = if (className == null) textNode(text) else OwnedWebControl.find(text, className = className)
        try { await("$text control") { target() != null } }
        catch (failure: Throwable) { NativeWebControlDiagnostics.capture(text); throw failure }
        var node = target()!!
        repeat(5) {
            if (node.isClickable && node.isEnabled) {
                assertTrue("Could not click $text", node.performAction(AccessibilityNodeInfo.ACTION_CLICK))
                return
            }
            node = node.parent ?: return@repeat
        }
        error("$text has no clickable native or web accessibility control")
    }

    private suspend fun awaitText(controller: BrowserController, engine: GeckoEngine, text: String) {
        val deadline = SystemClock.elapsedRealtime() + 15_000
        while (SystemClock.elapsedRealtime() < deadline) {
            val result = runCatching { onMainSuspend { engine.readText(controller.state.value.tab!!).text } }.getOrNull()
            if (result?.contains(text) == true) return
            delay(80)
        }
        error("The real document did not receive $text")
    }

    internal fun shot(name: String) {
        val directory = File(context.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot()) { "Device screenshot unavailable" }
        File(directory, name).outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
    }

    private suspend fun <T> onMain(block: () -> T): T = withContext(Dispatchers.Main) { block() }
    private suspend fun <T> onMainSuspend(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }

    private suspend fun await(name: String, timeout: Long = 15_000, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeout
        while (!condition()) {
            if (SystemClock.elapsedRealtime() >= deadline) {
                NativeWebControlDiagnostics.capture(name)
                error("Timed out waiting for $name")
            }
            delay(40)
        }
    }

    internal class NoNetworkEngine : BrowserEngine {
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override fun close(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }

    /** Loopback-only fixture. No external site, credentials or trust override is involved. */
    internal class FixtureServer : Closeable {
        private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val executor = Executors.newSingleThreadExecutor()
        private val running = AtomicBoolean(true)
        private val body = (1..16).joinToString("") {
            "<p>The delivery city is Oslo. This article describes a parcel, its destination, the shipping date and the careful delivery process. Every fact belongs to this local test document.</p>"
        }

        init {
            executor.submit {
                while (running.get()) {
                    val accepted = try { server.accept() } catch (error: IOException) {
                        if (running.get()) throw error else break
                    }
                    try {
                        accepted.use { socket ->
                            socket.soTimeout = 5000
                            val input = socket.getInputStream().bufferedReader()
                            val request = input.readLine() ?: return@use
                            while (!input.readLine().isNullOrEmpty()) { /* Drain request headers. */ }
                            val uri = URI(request.split(' ').getOrElse(1) { "/" })
                            val value = uri.rawQuery?.substringAfter("value=", "")?.takeIf { it.matches(Regex("[a-z-]{1,40}")) }
                            val html = if (uri.path.startsWith("/autofill/")) {
                                val sample = uri.path.substringAfterLast('/').takeIf { it.matches(Regex("[a-z]{1,16}")) } ?: "invalid"
                                """<title>Autofill fixture $sample</title><main><h1>Autofill fixture $sample</h1><form autocomplete='on'>
                                    <label for='username'>Fixture username</label><input id='username' name='yab-fixture-$sample-username' type='text' autocomplete='username' data-yab-fixture-case='$sample'>
                                    <label for='password'>Fixture password</label><input id='password' name='yab-fixture-$sample-password' type='password' autocomplete='current-password' data-yab-fixture-case='$sample'>
                                    <button type='button' onclick="window.fixtureReads=(window.fixtureReads||0)+1;document.getElementById('result').textContent='Read='+window.fixtureReads+' Username='+document.getElementById('username').value+' Password='+document.getElementById('password').value">Read fixture values</button>
                                    <p id='result'>Read=0 Username= Password=</p></form></main>""".trimIndent()
                            } else if (uri.path.startsWith("/safe/")) "<title>Safe page ${uri.path.substringAfterLast('/')}</title><article><h1>Safe page ${uri.path.substringAfterLast('/')}</h1>$body</article>" else when (uri.path) {
                                "/article" -> "<title>Delivery to Oslo</title><article><h1>Delivery to Oslo</h1>$body</article><a href='/second'>Continue reading</a>"
                                "/second" -> "<title>Second document</title><main><h1>Second document</h1><p>The native back stack must retain the first article.</p></main>"
                                "/forms" -> """<title>Native web forms</title><main>
                                    <label for='city'>Destination</label><select id='city' onchange="document.getElementById('selection').textContent='Selection='+this.value">
                                    <option selected disabled>Choose a city</option><optgroup label='Delivery cities'><option disabled>Unavailable</option><option value='Oslo'>Oslo</option><option value='Bergen'>Bergen</option></optgroup></select>
                                    <p id='selection'>Selection=pending</p><input id='date' type='date' value='2026-10-22' min='2026-10-21' max='2026-10-24' onchange="document.getElementById('dateResult').textContent='Date='+this.value">
                                    <button onclick="document.getElementById('date').showPicker()">Choose delivery date</button><p id='dateResult'>Date=pending</p>
                                    <button onclick="document.getElementById('confirmation').textContent='Confirmation='+(confirm('Send the parcel?')?'Confirmed':'Canceled')">Confirm delivery</button>
                                    <p id='confirmation'>Confirmation=pending</p></main>""".trimIndent()
                                "/capture" -> """<title>Private capture</title><main><h1>Private capture</h1>
                                    <p id='cookie'></p><button id='start'>Start camera and microphone</button><p id='result'>Stream=none</p>
                                    <video id='preview' muted autoplay playsinline style='width:240px;height:160px'></video>
                                    <script>document.getElementById('cookie').textContent='Cookie='+(document.cookie.split('; ').find(x=>x.startsWith('fixture='))?.slice(8)||'empty');
                                    document.getElementById('start').onclick=async()=>{try{
                                    const stream=await navigator.mediaDevices.getUserMedia({video:true,audio:true});window.fixtureStream=stream;
                                    document.getElementById('preview').srcObject=stream;document.getElementById('result').textContent='Stream='+stream.getTracks().map(t=>t.kind+':'+t.readyState).sort().join(',');
                                    }catch(e){document.getElementById('result').textContent='Error='+e.name;}};</script></main>""".trimIndent()
                                "/dirty" -> "<title>Unsent form</title><main><input id='draft' aria-label='Draft notes'><button onclick=\"document.getElementById('draft').value='unsent notes';document.getElementById('draft').dispatchEvent(new Event('input',{bubbles:true}));\">Edit form</button><button onclick=\"document.getElementById('draftResult').textContent='Draft='+document.getElementById('draft').value\">Read form</button><p id='draftResult'>Draft=pending</p>$body</main>"
                                "/uncertain" -> "<title>Embedded frame</title><main><h1>Embedded frame</h1><iframe src='/safe/frame' title='Embedded content'></iframe>$body</main>"
                                "/cookie/write" -> "<title>Cookie write</title><main id='result'></main><script>document.cookie='fixture=$value; Path=/; SameSite=Lax';localStorage.setItem('fixture','$value');document.getElementById('result').textContent='Cookie='+(document.cookie.split('; ').find(x=>x.startsWith('fixture='))?.slice(8)||'empty')+' Storage='+(localStorage.getItem('fixture')||'empty');</script>"
                                else -> "<title>Cookie read</title><main id='result'></main><script>document.getElementById('result').textContent='Cookie='+(document.cookie.split('; ').find(x=>x.startsWith('fixture='))?.slice(8)||'empty')+' Storage='+(localStorage.getItem('fixture')||'empty');</script>"
                            }
                            val response = ("<!doctype html><html lang='en'><meta name='viewport' content='width=device-width,initial-scale=1'>" + html + "</html>").toByteArray()
                            socket.getOutputStream().use { output ->
                                output.write(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: ${response.size}\r\nConnection: close\r\n\r\n").toByteArray())
                                output.write(response)
                            }
                        }
                    } catch (_: IOException) {
                        // Navigation can cancel a connection after accept or midway
                        // through a response. That client must not kill the fixture.
                    }
                }
            }
        }

        fun url(path: String) = "http://127.0.0.1:${server.localPort}$path"
        override fun close() { running.set(false); server.close(); executor.shutdownNow() }
    }
}
