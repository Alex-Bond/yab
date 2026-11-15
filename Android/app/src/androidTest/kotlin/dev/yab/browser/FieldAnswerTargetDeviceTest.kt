package dev.yab.browser

import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.FieldAnswerTarget
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test

/** Actual isolated Gecko DOM bookmarks. Every field and value belongs to this loopback fixture. */
class FieldAnswerTargetDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    @Test(timeout = 240_000)
    fun originalSelectionOneShotUnsupportedDetachedNavigationAndBackgroundAreEnforced(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        Pages().use { pages ->
            BrowserInstrumentedTest().withBrowser { browser, engine ->
                suspend fun open(name: String) {
                    main { browser.openUrl(pages.url(name), newTab = false) }
                    await("owned $name document") { !browser.state.value.page.loading && browser.state.value.page.title == "Owned answer $name" &&
                        runCatching { main { engine.readText(browser.state.value.tab!!).text.contains("Ready=$name") } }.getOrDefault(false) }
                }
                suspend fun target(): FieldAnswerTarget {
                    var captured: FieldAnswerTarget? = null
                    await("native editable bookmark") { captured = main { engine.captureFieldAnswerTarget(browser.state.value.tab!!.id) }; captured != null }
                    return requireNotNull(captured)
                }
                suspend fun text() = main { engine.readText(browser.state.value.tab!!).text }
                open("first")
                val original = target()
                click("Focus second")
                await("real later focus") { text().contains("Focus=second") }
                assertTrue(main { original.insert("28800") })
                await("actual original selection changed") { text().contains("First=ab28800ef|Second=untouched|Events=1") }
                assertFalse(main { original.insert("again") })
                for (kind in listOf("password", "email", "number", "readonly", "disabled", "password-editable", "email-editable", "number-editable")) {
                    open(kind)
                    assertNull("Unsupported $kind", main { engine.captureFieldAnswerTarget(browser.state.value.tab!!.id) })
                }
                open("detached")
                val detached = target()
                click("Detach first")
                await("real removed editable") { text().contains("Detached=true") }
                assertFalse(main { detached.insert("not inserted") })
                open("navigation")
                val previousDocument = target()
                open("new-document")
                assertFalse(main { previousDocument.insert("not in new document") })
                assertTrue(text().contains("First=abcdef"))
                val previousForeground = target()
                main { engine.background(); engine.foreground() }
                assertFalse(previousForeground.ready)
                assertFalse(main { previousForeground.insert("not after background") })
                assertTrue(text().contains("First=abcdef"))
            }
        }
    }

    private suspend fun click(words: String) {
        await("actual $words button") {
            fun find(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
                if (node.isVisibleToUser && node.isEnabled && (node.text?.toString() == words || node.contentDescription?.toString() == words) && node.isClickable) return node
                repeat(node.childCount) { index -> node.getChild(index)?.let { child -> find(child)?.let { return it } } }
                return null
            }
            instrumentation.uiAutomation.rootInActiveWindow?.let { find(it)?.performAction(AccessibilityNodeInfo.ACTION_CLICK) } == true
        }
    }

    private class Pages : AutoCloseable {
        private val running = AtomicBoolean(true)
        private val server = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        fun url(name: String) = "http://127.0.0.1:${server.localPort}/$name"
        private val worker = Thread {
            while (running.get()) runCatching { server.accept().use { socket ->
                socket.soTimeout = 3000
                val reader = socket.getInputStream().bufferedReader()
                val path = reader.readLine()?.split(' ')?.getOrNull(1)?.removePrefix("/")?.takeIf { it.matches(Regex("[a-z-]{1,24}")) } ?: "first"
                var bytes = 0
                while (true) { val line = reader.readLine() ?: break; bytes += line.length; check(bytes <= 8192); if (line.isEmpty()) break }
                val editable = path.endsWith("-editable")
                val type = path.removeSuffix("-editable").takeIf { it in setOf("password", "email", "number") } ?: "text"
                val html = """<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'><title>Owned answer $path</title>
                    <style>body{padding:48px 12px;font:16px sans-serif}input,button{font:18px sans-serif;display:block;margin:8px 0;min-height:44px}pre{white-space:pre-wrap}</style>
                    <div ${if (editable) "contenteditable=true" else ""}><fieldset ${if (path == "disabled") "disabled" else ""}><input id=first type=$type value=abcdef ${if (path == "readonly") "readonly" else ""} ${if (editable) "contenteditable=true" else ""} autofocus></fieldset></div>
                    <input id=second value=untouched><button onclick='second.focus();update()'>Focus second</button><button onclick='f.remove();update()'>Detach first</button><pre id=out></pre>
                    <script>const f=document.getElementById('first');let events=0;function update(){out.textContent='Ready=$path|First='+f.value+'|Second='+second.value+'|Events='+events+'|Focus='+document.activeElement.id+'|Detached='+!f.isConnected}
                    f.addEventListener('input',()=>{events++;update()});document.addEventListener('focusin',update);addEventListener('load',()=>{f.focus();try{f.setSelectionRange(2,4)}catch{}update()});</script>""".trimIndent().toByteArray()
                socket.getOutputStream().apply { write("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${html.size}\r\nConnection: close\r\n\r\n".toByteArray()); write(html); flush() }
            } }
        }.apply { name = "owned-answer-pages"; isDaemon = true; start() }
        override fun close() { running.set(false); server.close(); worker.join(4000) }
    }

    private suspend fun await(name: String, predicate: suspend () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + 30_000
        while (!predicate()) { check(SystemClock.elapsedRealtime() < until) { "Timed out waiting for $name" }; delay(70) }
    }
    private suspend fun <T> main(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }
}
