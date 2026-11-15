package dev.yab.browser

import android.os.SystemClock
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test

/** Selection uses a captured native history identity and preserves the Forward stack. */
class BrowserBackHistoryDeviceTest {

    @Test(timeout = 180_000)
    fun heldBackChoosesNativeEntryAndRejectsStaleOrDifferentTabIdentity(): Unit = runBlocking {
        val ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.BACK_HISTORY)
        ui.run {
            val fixture = BrowserInstrumentedTest()
            BrowserInstrumentedTest.FixtureServer().use { server ->
                fixture.withBrowser { browser, engine ->
                    main { ui.bind(browser, engine) }
                    ui.checkpoint("browser_ready")
                    main { browser.openUrl(server.url("/safe/first")) }
                    await("first page") { browser.state.value.page.title == "Safe page first" && !browser.state.value.page.loading }
                    main { browser.openUrl(server.url("/safe/second"), newTab = false) }
                    await("second page") { browser.state.value.page.title == "Safe page second" && !browser.state.value.page.loading }
                    main { browser.openUrl(server.url("/safe/third"), newTab = false) }
                    await("third native history") { browser.state.value.page.title == "Safe page third" && !browser.state.value.page.loading && main { engine.backItems(browser.state.value.tab!!.id).size >= 2 } }
                    val owner = browser.state.value.tab!!.id
                    val captured = main { engine.backItems(owner) }
                    assertEquals(server.url("/safe/second"), captured.first().url)
                    assertEquals(1, captured.first().steps)
                    await("Back long-press control") { ui.hasLabel("Back") }
                    ui.longPress("Back", activated = { ui.hasLabel("All History") })
                    await("actual native back menu") { ui.hasLabel("Safe page second") && ui.hasLabel("All History") }
                    fixture.shot("browser-back-history-menu.png")
                    ui.click("Safe page second")
                    await("chosen native entry") { browser.state.value.page.title == "Safe page second" && !browser.state.value.page.loading && browser.state.value.page.canGoForward }
                    main { assertFalse("Old menu token remained valid after native history moved", engine.goBackTo(owner, captured.first())) }
                    main { browser.forward() }
                    await("Forward stack retained") { browser.state.value.page.title == "Safe page third" && !browser.state.value.page.loading }
                    val current = main { engine.backItems(owner).first() }
                    main { browser.openUrl(server.url("/safe/other-tab")) }
                    await("other tab") { browser.state.value.page.title == "Safe page other-tab" && !browser.state.value.page.loading }
                    val other = browser.state.value.tab!!.id
                    main {
                        assertFalse("History identity crossed native sessions", engine.goBackTo(other, current))
                        browser.goBackTo(owner, current)
                    }
                    assertEquals(other, browser.state.value.tab!!.id)
                    assertEquals("Safe page other-tab", browser.state.value.page.title)
                    fixture.shot("browser-back-native-forward.png")
                }
            }
        }
    }

    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
    private suspend fun await(name: String, test: suspend () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (!test()) { check(SystemClock.elapsedRealtime() < deadline) { "Timed out waiting for $name" }; delay(80) }
    }
}
