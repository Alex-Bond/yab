package dev.yab.browser

import android.graphics.Bitmap
import android.graphics.Color as NativeColor
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.icons.AndroidSiteIcons
import dev.yab.browser.icons.SiteIconOrigin
import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.BrowserEngine
import dev.yab.browser.model.BrowserRepository
import dev.yab.browser.model.BrowserSnapshot
import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.BrowserSurface
import dev.yab.browser.model.TabPlace
import dev.yab.browser.model.WebsiteProfile
import dev.yab.browser.ui.*
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Actual Android decoder/renderer pixels; no paired iOS or presented-motion claim. */
class BrowserFaviconDeviceTest {
    @get:Rule val compose = createComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    @Test fun aLateNativePictureInvalidatesTheRasterOnceAndPrivateCannotReuseOrFetchIt() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val store = AndroidSiteIcons(instrumentation.targetContext, scope) { it.host == "127.0.0.1" }
        IconServer(png()).use { server ->
            try {
                val tab = BrowserTab("icon-fixture", "${server.origin}/page", createdAt = 1)
                compose.setContent {
                    Row(Modifier.fillMaxSize().background(Color.White).padding(24.dp), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                        CompositionLocalProvider(LocalBrowserSiteIcons provides BrowserSiteIconScope(store, false)) {
                            BrowserFavicon(tab, 24.dp, Modifier.testTag("favicon.public"))
                        }
                        CompositionLocalProvider(LocalBrowserSiteIcons provides BrowserSiteIconScope(store, true)) {
                            BrowserFavicon(tab, 24.dp, Modifier.testTag("favicon.private-space"))
                        }
                        CompositionLocalProvider(LocalBrowserSiteIcons provides BrowserSiteIconScope(store, false)) {
                            BrowserFavicon(tab.copy(id = "private", isPrivate = true), 24.dp, Modifier.testTag("favicon.private-tab"))
                        }
                    }
                }
                compose.waitForIdle()
                assertFalse(redCenter("favicon.public"))
                assertTrue(runBlocking { store.load(tab.url, "${server.origin}/picture.png", false) })
                compose.waitUntil(5_000) { store.pictures.value[SiteIconOrigin.from(tab.url)!!] != null }
                compose.waitForIdle()
                assertTrue("Fetched image did not replace the drawn tile", redCenter("favicon.public"))
                assertFalse("A private space reused the public image", redCenter("favicon.private-space"))
                assertFalse("A private tab reused the public image", redCenter("favicon.private-tab"))
                assertFalse(runBlocking { store.load("${server.origin}/private", null, true) })
                assertEquals(1, server.requests.get())
                val density = instrumentation.targetContext.resources.displayMetrics.density
                val first = store.render(tab, 24f, density, false, false)
                val renders = store.rasterCount
                repeat(60) { assertSame(first, store.render(tab, 24f, density, false, false)) }
                assertEquals(renders, store.rasterCount)
                record("late-public-private", JSONObject().put("httpRequests", server.requests.get()).put("repeatedRasters", 60)
                    .put("extraRenders", store.rasterCount - renders))
            } finally { scope.cancel() }
        }
    }

    @Test fun originalBundleAndPngInsideIcoDecodeOnTheActualAndroidDecoder() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val store = AndroidSiteIcons(instrumentation.targetContext, scope)
        try {
            val entries = instrumentation.targetContext.assets.open("favicons/favicons.json").bufferedReader().use { JSONArray(it.readText()) }
            val dimensions = JSONArray()
            val bundled = instrumentation.targetContext.assets.list("favicons").orEmpty().filter { it.endsWith(".png") || it.endsWith(".webp") || it.endsWith(".jpg") }
            assertEquals(28, bundled.size)
            bundled.forEach { name ->
                val decoded = instrumentation.targetContext.assets.open("favicons/$name").use { AndroidSiteIcons.decode(it.readBytes()) }
                assertNotNull("Original bundled file $name failed native decode", decoded)
                decoded!!.recycle()
            }
            assertNull("A real www host silently borrowed its pretty-host prototype image",
                store.image(BrowserTab("www-host", "https://www.github.com/owned", createdAt = 1), true))
            repeat(entries.length()) { index ->
                val entry = entries.getJSONObject(index)
                val host = entry.getString("host")
                val tab = BrowserTab("bundle-$index", "https://$host/", createdAt = 1)
                if (entry.getString("source") == "image") assertNotNull("Original bundled image ${entry.getString("key")} failed native decode", store.image(tab, true))
                val image = store.render(tab, 20f, 3f, true, true)
                assertEquals(60, image.width); assertEquals(60, image.height)
                dimensions.put(JSONObject().put("key", entry.getString("key")).put("pixels", image.width))
            }
            val picture = png()
            val ico = ByteBuffer.allocate(22 + picture.size).order(ByteOrder.LITTLE_ENDIAN)
                .putShort(0).putShort(1).putShort(1).put(32).put(32).put(0).put(0)
                .putShort(1).putShort(32).putInt(picture.size).putInt(22).put(picture).array()
            val decoded = AndroidSiteIcons.decode(ico)
            assertNotNull("The native root favicon ICO path did not decode", decoded)
            decoded!!.recycle()
            assertNull(AndroidSiteIcons.decode(byteArrayOf(0, 1, 2)))
            record("bundle-decoder", JSONObject().put("bundledEntries", dimensions).put("bundledFilesDecoded", bundled.size).put("pngIcoDecoded", true))
        } finally { scope.cancel() }
    }

    @Test fun realAddressSpacesAndGalleryConsumersUseIconsAndTypedWordsRestoreTheMagnifier() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val store = AndroidSiteIcons(instrumentation.targetContext, scope) { false }
        val page = BrowserTab("favicon-row", "https://github.com/owned", createdAt = 1)
        val pin = BrowserTab("favicon-pin", "https://figma.com/owned", place = TabPlace.PINNED, createdAt = 1)
        val repository = object : BrowserRepository {
            override suspend fun load() = BrowserSnapshot(spaces = listOf(BrowserSpace("favicon-consumers", "Icons",
                tabs = listOf(pin, page), currentTabId = page.id)), selectedSpaceId = "favicon-consumers")
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
            override fun goBack(tabId: String) {}; override fun goForward(tabId: String) {}
            override fun reload(tabId: String) {}; override fun stop(tabId: String) {}; override fun close(tabId: String) {}
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        val browser = BrowserController(repository, engine, scope)
        try {
            compose.setContent {
                BrowserTheme(BrowserAppearance.LIGHT) {
                    CompositionLocalProvider(LocalBrowserSiteIcons provides BrowserSiteIconScope(store, false)) {
                        BrowserScreen(browser) { _, _, modifier -> Box(modifier.fillMaxSize().background(Color.White)) }
                    }
                }
            }
            compose.waitUntil(10_000) { !browser.state.value.loading }
            compose.runOnIdle { browser.openField(newTab = false) }
            val icon = compose.onNodeWithTag("browser.field.favicon", useUnmergedTree = true)
            icon.assertExists()
            val iconBounds = icon.fetchSemanticsNode().boundsInRoot
            val inputBounds = compose.onNodeWithTag("browser.field.input").fetchSemanticsNode().boundsInRoot
            val density = instrumentation.targetContext.resources.displayMetrics.density
            assertEquals(16f * density, iconBounds.width, 1f)
            assertEquals(8f * density, inputBounds.left - iconBounds.right, 1f)
            compose.runOnIdle { browser.dismissSurface(); browser.show(BrowserSurface.SPACES) }
            compose.onNodeWithTag("browser.field.favicon", useUnmergedTree = true).assertDoesNotExist()
            compose.onNodeWithTag("browser.field.search-glyph", useUnmergedTree = true).assertExists()
            compose.onNodeWithTag("browser.pin.favicon.${pin.id}", useUnmergedTree = true).assertExists()
            compose.onNodeWithTag("browser.row.favicon.${page.id}", useUnmergedTree = true).assertExists()
            compose.runOnIdle { browser.openField(newTab = false) }
            compose.onNodeWithTag("browser.field.input").performTextReplacement("typed words")
            compose.onNodeWithTag("browser.field.favicon", useUnmergedTree = true).assertDoesNotExist()
            compose.onNodeWithTag("browser.field.search-glyph", useUnmergedTree = true).assertExists()
            compose.runOnIdle { browser.dismissSurface(); browser.show(BrowserSurface.GALLERY) }
            compose.onNodeWithTag("browser.gallery.favicon.${page.id}", useUnmergedTree = true).assertExists()
            record("actual-consumers", JSONObject().put("fakePageEngine", true).put("realBrowserScreen", true)
                .put("addressIconDp", 16).put("addressGapDp", 8).put("networkRequestsEnabled", false))
        } finally { scope.cancel() }
    }

    private fun redCenter(tag: String): Boolean {
        val pixels = compose.onNodeWithTag(tag).captureToImage().toPixelMap()
        val center = pixels[pixels.width / 2, pixels.height / 2]
        return center.red > .85f && center.green < .15f && center.blue < .15f
    }
    private fun png(): ByteArray {
        val image = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888).apply { eraseColor(NativeColor.RED) }
        return ByteArrayOutputStream().use { output -> image.compress(Bitmap.CompressFormat.PNG, 100, output); image.recycle(); output.toByteArray() }
    }
    private fun record(name: String, data: JSONObject) {
        val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/favicon-native").apply { check(isDirectory || mkdirs()) }
        File(folder, "$name.json").writeText(data.put("pairedIosFramesVerified", false).put("physicalDeviceSmoothnessVerified", false).toString(2))
        if (name in setOf("late-public-private", "actual-consumers")) File(folder, "$name.png").outputStream().use {
            check(compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it))
        }
    }
    private class IconServer(private val bytes: ByteArray) : Closeable {
        private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        val requests = AtomicInteger()
        val origin get() = "http://127.0.0.1:${server.localPort}"
        private val worker = thread(isDaemon = true, name = "native-icon-fixture") {
            while (!server.isClosed) {
                val socket = runCatching { server.accept() }.getOrNull() ?: break
                socket.use { connection ->
                    connection.soTimeout = 5_000
                    val input = connection.getInputStream().bufferedReader()
                    if (input.readLine() == null) return@use
                    while (!input.readLine().isNullOrEmpty()) { }
                    requests.incrementAndGet()
                    runCatching { connection.getOutputStream().apply {
                        write("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
                        write(bytes); flush()
                    } }
                }
            }
        }
        override fun close() { server.close(); worker.join(5_000); check(!worker.isAlive) }
    }
}
