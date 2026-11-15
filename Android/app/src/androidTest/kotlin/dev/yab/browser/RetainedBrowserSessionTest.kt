package dev.yab.browser

import android.os.SystemClock
import android.view.WindowManager
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.BrowserSessionViewModel
import dev.yab.android.MainActivity
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.engine.NativePagePrompts
import dev.yab.browser.model.*
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.mozilla.geckoview.GeckoSession

/** Uses MainActivity's real retained owner and shipped GeckoView binding, with no replacement UI. */
@RunWith(AndroidJUnit4::class)
class RetainedBrowserSessionTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 240_000)
    fun recreationKeepsPrivateNativeSessionCookiesAndBackWithoutChangingPublicProfile(): Unit = runBlocking {
        BrowserInstrumentedTest.FixtureServer().use { server ->
            val scenario = ActivityScenario.launch(MainActivity::class.java)
            lateinit var originalActivity: MainActivity
            lateinit var owner: BrowserSessionViewModel
            var restore: BrowserSnapshot? = null
            var privateTab: BrowserTab? = null
            val denied = AtomicReference<Boolean?>()
            val answers = AtomicInteger()
            try {
                scenario.onActivity { activity ->
                    originalActivity = activity
                    owner = ViewModelProvider(activity)[BrowserSessionViewModel::class.java]
                }
                val browser = owner.browser
                val engine = owner.engine
                await("Main browser loaded") { !browser.state.value.loading }
                restore = browser.publicSnapshot()
                main {
                    browser.updateSettings(browser.state.value.settings.copy(welcomed = true, autoClearToday = false, lockPrivate = true))
                    BrowserInstrumentedTest().ownSpace(browser, "Retained ${UUID.randomUUID()}")
                    browser.openUrl(server.url("/safe/retained-public"))
                }
                await("actual public page") { browser.state.value.page.title == "Safe page retained-public" && !browser.state.value.page.loading }
                val publicTab = browser.state.value.tab!!
                val publicProfile = browser.state.value.space!!.websiteProfile
                val publicSession = main { engine.session(publicTab, publicProfile) }
                main {
                    browser.openUrl(server.url("/cookie/write?value=private-retained"), privately = true)
                    browser.unlockPrivate(true)
                }
                awaitText(browser, engine, "Cookie=private-retained")
                main { browser.openUrl(server.url("/article"), newTab = false) }
                awaitText(browser, engine, "delivery city is Oslo")
                assertTrue(browser.state.value.page.canGoBack)
                privateTab = browser.state.value.tab!!
                val privateProfile = browser.state.value.space!!.websiteProfile
                val privateSession = main { engine.session(privateTab!!, privateProfile) }
                val oldPrompts = requireNotNull(engine.prompts)
                val publicBefore = browser.publicSnapshot()
                val disk = FileBrowserRepository(File(context.filesDir, "browser.json"))
                await("public profile checkpoint") { disk.load() == publicBefore }
                main {
                    oldPrompts.permission(privateSession, "Recreation permission", "This old Activity must not keep a permission lease") {
                        denied.set(it); answers.incrementAndGet()
                    }
                }
                assertTrue(main { oldPrompts.hasPending(privateSession) })
                BrowserInstrumentedTest().shot("private-before-activity-recreate.png")

                // This destroys the actual MainActivity, including its Compose/GeckoView tree.
                // No configChanges exception or test-owned controller bypasses the path.
                scenario.recreate()
                scenario.onActivity { activity ->
                    assertNotSame(originalActivity, activity)
                    val retained = ViewModelProvider(activity)[BrowserSessionViewModel::class.java]
                    assertSame(owner, retained)
                    assertSame(browser, retained.browser)
                    assertSame(engine, retained.engine)
                    assertSame(owner.agent, retained.agent)
                    assertSame(owner.translator, retained.translator)
                    assertSame(owner.extensionHost, retained.extensionHost)
                    assertTrue(browser.state.value.privateContentBlocked)
                    assertEquals(privateTab!!.id, browser.state.value.tab!!.id)
                    assertSame(privateSession, engine.session(privateTab!!, privateProfile))
                    assertSame(publicSession, engine.session(publicTab, publicProfile))
                    assertNotSame(oldPrompts, engine.prompts)
                    assertSame(engine.prompts, privateSession.promptDelegate)
                    assertSame(engine.prompts, publicSession.promptDelegate)
                }
                await("recreated Private window is secure") {
                    var secure = false
                    scenario.onActivity { secure = it.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0 }
                    secure
                }
                assertEquals(false, denied.get())
                assertEquals("Old native prompt answered more than once", 1, answers.get())
                assertFalse(main { oldPrompts.hasPending(privateSession) })
                assertEquals("Activity recreation changed the public model", publicBefore, browser.publicSnapshot())
                assertEquals("Activity recreation changed the saved public profile", publicBefore, disk.load())
                main { browser.unlockPrivate(true) }
                awaitText(browser, engine, "delivery city is Oslo")
                assertTrue("Activity recreation lost native Back", browser.state.value.page.canGoBack)

                // Read cookies from a NEW document first. Going Back to /cookie/write
                // would set them again and could conceal a lost private cookie jar.
                main { browser.openUrl(server.url("/cookie/read"), privately = true) }
                awaitText(browser, engine, "Cookie=private-retained Storage=private-retained")
                val cookieCheck = browser.state.value.tab!!.id
                main { browser.closeTab(cookieCheck); browser.selectTab(privateTab!!.id) }
                awaitText(browser, engine, "delivery city is Oslo")
                main { assertTrue(browser.back()) }
                awaitText(browser, engine, "Cookie=private-retained")
                assertEquals(server.url("/cookie/write?value=private-retained"), browser.state.value.page.url)
                assertEquals(publicBefore, browser.publicSnapshot())
                val stateFile = File(context.filesDir, "navigation/${UUID.nameUUIDFromBytes(privateTab!!.id.toByteArray())}.json")
                assertFalse("Private native state was persisted", stateFile.exists())
                assertFalse(File(context.filesDir, "browser.json").readText().contains("private-retained"))
                BrowserInstrumentedTest().shot("private-after-activity-recreate.png")
            } finally {
                if (restore != null) main {
                    owner.browser.state.value.spaces.filter(BrowserSpace::isPrivate).flatMap { it.tabs }.forEach { owner.browser.closeTab(it.id) }
                    owner.browser.applySyncedSnapshot(restore!!)
                }
                if (restore != null) await("restored original public profile") {
                    FileBrowserRepository(File(context.filesDir, "browser.json")).load() == restore
                }
                scenario.close()
            }
        }
    }

    private suspend fun awaitText(browser: BrowserController, engine: GeckoEngine, text: String) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        var observed = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            if (!browser.state.value.page.loading) {
                observed = runCatching { main { engine.readText(browser.state.value.tab!!).text } }.getOrDefault("")
                if (observed.contains(text)) return
            }
            delay(100)
        }
        error("The native document did not contain $text. Last content: $observed")
    }

    private suspend fun await(label: String, timeout: Long = 20_000, ready: suspend () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeout
        while (SystemClock.elapsedRealtime() < deadline) { if (ready()) return; delay(100) }
        error("Timed out waiting for $label")
    }

    private suspend fun <T> main(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }
}
