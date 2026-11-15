package dev.yab.browser

import android.graphics.Bitmap
import android.os.SystemClock
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.*
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import java.io.File
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Production Site/Certificate components with explicit fixture facts. No TLS or OS grant claim. */
class SiteMenuSurfaceDeviceTest {
    @get:Rule val compose = createComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun shot(name: String) {
        compose.waitForIdle(); SystemClock.sleep(450)
        val dir = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        try { File(dir, "site-fixture-$name.png").outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { bitmap.recycle() }
        File(dir, "site-fixture-$name.json").writeText("""{"kind":"controlled-component-fixture","productionComponents":true,"realGecko":false,"realTlsVerified":false,"osPermissionsChanged":false,"certificateFacts":"fictional"}""")
    }
    @Test(timeout = 120_000) fun savedPermissionsCertificateAndThemeUseTheSameOwnedSite() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val tab = BrowserTab("site-fixture", "https://fixture.example/article", "Fixture article", createdAt = 1)
        val space = BrowserSpace("personal", "Personal", tabs = listOf(tab), currentTabId = tab.id)
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
            override fun goBack(tabId: String) {}; override fun goForward(tabId: String) {}
            override fun reload(tabId: String) {}; override fun stop(tabId: String) {}; override fun close(tabId: String) {}
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        lateinit var browser: BrowserController
        var dark by mutableStateOf(false)
        var mounted by mutableStateOf(true)
        var shown by mutableStateOf(true)
        lateinit var session: BrowserPageMenuSession
        val choices = mutableListOf<Pair<SitePermission, SiteDecision?>>()
        try {
            compose.runOnIdle { browser = BrowserController(object : BrowserRepository {
                override suspend fun load() = BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id)
                override suspend fun save(snapshot: BrowserSnapshot) {}
            }, engine, scope) }
            compose.waitUntil(10_000) { !browser.state.value.loading }
            compose.setContent {
                BrowserTheme(if (dark) BrowserAppearance.DARK else BrowserAppearance.LIGHT) {
                    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                        BoxWithConstraints {
                            val geometry = remember { BrowserPageMenuGeometry(maxWidth.value.toDouble(), maxHeight.value.toDouble(), 24.0,
                                PageMenuRect(70.0, maxHeight.value - 76.0, (maxWidth.value - 140.0).toDouble(), 48.0), 450.0) }
                            val held = remember {
                                val lease = PageMenuLease("site-ui-fixture", 1, tab.id, space.id, space.websiteProfile, Any(), 1, 1)
                                val connection = SiteConnection(true, false, tab.host, "https://fixture.example", 0, 0, 0,
                                    "fixture.example", "UI Fixture Issuer", null, 1_830_297_600_000, null)
                                val initial = PageMenuContentSnapshot(tab, EnginePageState(url = tab.url),
                                    SitePreferences(permissions = linkedMapOf(SitePermission.MICROPHONE to SiteDecision.OFF, SitePermission.CAMERA to SiteDecision.ASK)),
                                    connection, true, null, null, onPermission = { permission, decision ->
                                        choices += permission to decision
                                        val old = session.snapshot
                                        val values = checkNotNull(old.preferences).permissions
                                        session.snapshot = old.copy(preferences = old.preferences.copy(permissions =
                                            if (decision == null) values - permission else values + (permission to decision)))
                                    })
                                makePageMenuSession(lease, geometry, SpacesRect(0.0, 0.0, geometry.width, geometry.height),
                                    SpacesRect(0.0, 0.0, geometry.width, geometry.height), initial, browser, instrumentation.targetContext,
                                    current = { mounted && browser.state.value.tab?.id == tab.id && browser.state.value.space?.websiteProfile == space.websiteProfile },
                                    closing = { shown = false }, released = { _, _ -> mounted = false }, reopened = { shown = true },
                                    onAsk = null, onTranslate = null, onMac = null, onExtensions = null).also { session = it }
                            }
                            if (mounted) BrowserPageMenuHost(held.entry, shown, geometry)
                        }
                    }
                }
            }
            fun settled(page: PageMenuPage) { compose.waitUntil(15_000) { session.entry.presentation.frame.value.let {
                it.interactive && !it.running && when (page) {
                    PageMenuPage.SITE -> it.site == 1.0 && it.certificate == 0.0
                    PageMenuPage.CERTIFICATE -> it.certificate == 1.0
                    else -> it.site == 0.0
                }
            } } }
            settled(PageMenuPage.MENU)
            compose.onNodeWithText("Site Settings").performTouchInput { click() }; settled(PageMenuPage.SITE)
            compose.onNodeWithText("Camera").assertExists(); compose.onNodeWithText("Microphone").assertExists()
            assertTrue("Camera precedes Microphone regardless of storage insertion order",
                compose.onNodeWithText("Camera").fetchSemanticsNode().boundsInRoot.top <
                    compose.onNodeWithText("Microphone").fetchSemanticsNode().boundsInRoot.top)
            shot("permissions-light")
            compose.onNodeWithText("Ask").performTouchInput { click() }
            compose.onNode(hasText("Allowed") and hasAnyAncestor(isPopup())).performTouchInput { click() }
            compose.onNodeWithText("Allowed").assertExists()
            compose.runOnIdle { assertEquals(listOf(SitePermission.CAMERA to SiteDecision.ALLOWED), choices) }
            compose.onNodeWithContentDescription("Forget Camera").performTouchInput { click() }
            compose.onNodeWithText("Camera").assertDoesNotExist(); compose.onNodeWithText("Microphone").assertExists()
            compose.runOnIdle { assertEquals(SitePermission.CAMERA to null, choices.last()); dark = true }
            shot("permissions-dark")
            compose.onNodeWithText("Connection is secure").performScrollTo().performTouchInput { click() }; settled(PageMenuPage.CERTIFICATE)
            compose.onNodeWithText("UI Fixture Issuer").assertExists(); shot("certificate-dark")
            compose.runOnIdle { dark = false }; shot("certificate-light")
            compose.runOnIdle { assertEquals(tab.id, browser.state.value.tab?.id); assertEquals(2, choices.size) }
        } finally { compose.runOnIdle { mounted = false; scope.cancel() } }
    }
}
