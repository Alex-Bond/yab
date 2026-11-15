package dev.yab.browser

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.model.PageMenuLease
import dev.yab.browser.model.WebsiteProfile
import dev.yab.browser.ui.*
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Controlled synthetic content, real native frame clock and accessibility activation. This does
 * not verify the production menu integration, native typography/glass or paired iOS frames. */
@RunWith(AndroidJUnit4::class)
class BrowserPageMenuDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private data class Draw(val frame: PageMenuFrame, val pose: BrowserPageMenuPose, val nanos: Long)
    private class Fixture {
        val original = PageMenuLease("menu-device-fixture", 1, "tab", "space", WebsiteProfile("shared"), Any(), 1, 1)
        var current by mutableStateOf(original)
        var shown by mutableStateOf(true)
        var mounted by mutableStateOf(true)
        val actions = AtomicInteger()
        val releases = CopyOnWriteArrayList<PageMenuRelease>()
        val draws = CopyOnWriteArrayList<Draw>()
        var scope: BrowserPageMenuScope? = null
        lateinit var entry: BrowserPageMenuEntry
        lateinit var ui: OwnedPageMenuTestUi
    }

    @Test(timeout = 90_000)
    fun actualPlateRiseReversalCancelsTheOldExitAndLandsBeforeItsOneCapturedAction(): Unit = runBlocking {
        fixture("reversal", false) { f ->
            await("interactive real menu") { f.entry.presentation.frame.value.let { it.interactive && !it.running } }
            assertTrue(f.draws.any { it.frame.phase == PageMenuPhase.MOUNTED && it.pose.sheet == it.pose.row && it.pose.progress == 0.0 })
            assertTrue(f.draws.any { it.pose.progress > 0 && it.pose.progress < 1 })
            f.ui.click("Queue Fixture Action")
            await("real closing draw") { f.draws.any { it.frame.phase == PageMenuPhase.CLOSING && it.pose.progress in .05.. .95 } }
            assertFalse(main { f.scope!!.perform { f.actions.addAndGet(100) } })
            val before = f.entry.presentation.frame.value.progress
            main { f.shown = true }
            await("same captured menu reverses") { f.entry.presentation.frame.value.shown }
            assertTrue(before > 0)
            delay(450)
            assertEquals(0, f.actions.get()); assertTrue(f.releases.isEmpty())
            await("reopened menu becomes interactive") { f.entry.presentation.frame.value.let { it.interactive && !it.running } }
            f.ui.click("Queue Fixture Action")
            await("one landed action") { f.actions.get() == 1 && f.releases.size == 1 }
            assertEquals(listOf(PageMenuRelease.LANDED), f.releases.toList())
            assertEquals(PageMenuPhase.CLOSED, f.entry.presentation.frame.value.phase)
            delay(100); assertEquals(1, f.actions.get())
        }
    }

    @Test(timeout = 90_000)
    fun reducedDropAndSameAccountReconnectRevokeTheCapturedTextAndQueuedAction(): Unit = runBlocking {
        fixture("revocation", true) { f ->
            await("reduced menu interactive") { f.entry.presentation.frame.value.let { it.interactive && !it.running } }
            assertTrue(f.draws.any { it.frame.progress < .98 && it.pose.progress == 1.0 && it.pose.fade < 1 })
            val oldScope = main { f.scope!! }
            f.ui.click("Queue Fixture Action")
            await("queued close has started") { f.entry.presentation.frame.value.phase == PageMenuPhase.CLOSING }
            main { f.current = f.original.copy(accountEpoch = 2, nativeOwner = Any(), profile = WebsiteProfile("private", true)) }
            await("old menu released as revoked") { f.releases.contains(PageMenuRelease.REVOKED) }
            assertFalse(main { oldScope.perform { f.actions.incrementAndGet() } })
            delay(300)
            assertEquals(0, f.actions.get())
            assertEquals(PageMenuPhase.REVOKED, f.entry.presentation.frame.value.phase)
            f.ui.absent("Queue Fixture Action")
        }
    }

    private suspend fun fixture(kind: String, reduced: Boolean, body: suspend (Fixture) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        require(kind in setOf("reversal", "revocation"))
        val f = Fixture()
        f.ui = OwnedPageMenuTestUi(if (reduced) OwnedPageMenuTestUi.Case.COMPONENT_REVOCATION else OwnedPageMenuTestUi.Case.COMPONENT_REVERSAL)
        var scenario: ActivityScenario<EngineTestActivity>? = null
        var completed = false
        try {
            scenario = ActivityScenario.launch(EngineTestActivity::class.java)
            main {
                f.entry = BrowserPageMenuEntry(f.original, current = { f.current == f.original },
                    closing = { expected -> if (f.current == expected) f.shown = false },
                    released = { _, reason -> f.releases.add(reason); f.mounted = false },
                    // The fixture exercises no prediction or injected gesture physics.
                    predictedEndY = { translation, _ -> translation },
                    background = { modifier, pose -> Surface(modifier, shape = RoundedCornerShape(pose.radius.dp),
                        color = MaterialTheme.colorScheme.surfaceContainerHigh) {} },
                    address = { scope, modifier -> Box(modifier.padding(4.dp)) { Text("Fixture Page Menu") } },
                    menu = { scope ->
                        f.scope = scope
                        Column(Modifier.padding(16.dp)) {
                            Button(enabled = scope.enabled, onClick = { scope.perform(afterLanding = true) { f.actions.incrementAndGet() } },
                                modifier = Modifier.semantics { contentDescription = "Queue Fixture Action" }) {
                                Text("Queue Fixture Action", Modifier.clearAndSetSemantics {})
                            }
                            Text("Synthetic fixture rows")
                        }
                    }, site = { Text("Synthetic Site Settings") }, certificate = { Text("Synthetic Certificate") })
            }
            main { f.ui.bind {
                val expected = f.current; val entry = f.entry
                if (expected != f.original || !f.mounted || !entry.owned()) null else {
                    val current: () -> Boolean = { f.current == expected && f.entry === entry && f.mounted && entry.owned() }; current
                }
            } }
            checkNotNull(scenario).onActivity { activity ->
                activity.setContent {
                    BrowserTheme(BrowserAppearance.SYSTEM) {
                        CompositionLocalProvider(LocalBrowserAccessibility provides BrowserAccessibilityPreferences(reduceMotion = reduced),
                            LocalPageMenuAnimationsEnabled provides true,
                            LocalPageMenuDrawObserver provides { frame, pose, nanos ->
                                if (f.draws.size < 300) f.draws.add(Draw(frame, pose, nanos))
                                f.ui.frame(frame.phase.name, frame.running, frame.interactive)
                            }) {
                            BoxWithConstraints(Modifier.fillMaxSize()) {
                                if (f.mounted) BrowserPageMenuHost(f.entry, f.shown,
                                    BrowserPageMenuGeometry(maxWidth.value.toDouble(), maxHeight.value.toDouble(), 24.0,
                                        PageMenuRect(70.0, maxHeight.value - 76.0, (maxWidth.value - 140.0).toDouble(), 48.0),
                                        menuBody = 150.0))
                            }
                        }
                    }
                }
            }
            body(f); completed = true
        } finally {
            f.ui.finish(completed)
            val rows = JSONArray()
            val began = f.draws.firstOrNull()?.nanos ?: 0L
            f.draws.take(300).forEach { row -> rows.put(JSONObject().put("phase", row.frame.phase.name)
                .put("ms", ((row.nanos - began) / 1_000_000).coerceIn(0, 90_000))
                .put("progress", row.frame.progress.coerceIn(-2.0, 2.0)).put("interactive", row.frame.interactive)
                .put("sheet", JSONArray(listOf(row.pose.sheet.x, row.pose.sheet.y, row.pose.sheet.width, row.pose.sheet.height)))
                .put("fade", row.pose.fade).put("sink", row.pose.sink)) }
            val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
            File(folder, "page-menu-$kind-motion.json").writeText(JSONObject().put("completed", completed)
                .put("controlledSyntheticFixture", true).put("productionMenuIntegration", false)
                .put("pairedIosPresentedFrames", false).put("actions", f.actions.get())
                .put("releases", JSONArray(f.releases.map { it.name })).put("draws", rows).toString())
            scenario?.close()
        }
    }

    private suspend fun await(reason: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + 15_000_000_000L
        while (!condition()) { check(System.nanoTime() < deadline) { "Timed out: $reason" }; delay(16) }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
}
