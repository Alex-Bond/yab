package dev.yab.android

import android.content.ComponentName
import android.content.Intent
import android.os.SystemClock
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import java.io.Closeable
import java.io.File
import org.json.JSONArray
import org.json.JSONObject

/** ActivityScenario 1.7 filters every lifecycle callback by the original intent's action/data.
 * MainActivity correctly replaces that intent in onNewIntent. These two fixtures deliberately
 * exercise that path before recreation, so follow the real retained store and task instead.
 * Never resume an activity, dismiss another window or relaunch a lost owner to satisfy a test. */
internal class NativeMainActivityFixture private constructor(
    private val kind: Kind,
    private val task: Int,
    private val store: ViewModelStore,
    private val lifetime: Lifetime,
) : Closeable {
    private class Lifetime : ViewModel() {
        @Volatile var cleared = false
            private set
        override fun onCleared() { cleared = true }
    }
    enum class Kind { APP_WORKSPACE, PARKED_CHAT }
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val samples = JSONArray()
    private val started = SystemClock.elapsedRealtime()

    fun onActivity(action: (MainActivity) -> Unit) {
        val expected = awaitCurrent()
        instrumentation.runOnMainSync {
            check(owned(expected) && resumed().singleOrNull() === expected && expected.hasWindowFocus())
            action(expected)
        }
    }

    fun recreate() {
        val previous = awaitCurrent()
        instrumentation.runOnMainSync {
            check(owned(previous) && resumed().singleOrNull() === previous && previous.hasWindowFocus())
            previous.recreate()
        }
        val replacement = awaitCurrent(excluding = previous)
        check(replacement !== previous)
        record("recreated", true)
    }

    private fun owned(activity: MainActivity) = !activity.isDestroyed && activity.taskId == task &&
        activity.packageName == instrumentation.targetContext.packageName && activity.viewModelStore === store

    /** Called only on Main. A same-class activity with another retained store is not this scene. */
    private fun resumed() = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
        .filterIsInstance<MainActivity>().filter(::owned)

    private fun awaitCurrent(excluding: MainActivity? = null): MainActivity {
        val deadline = SystemClock.elapsedRealtime() + 15_000
        while (true) {
            var current: MainActivity? = null
            instrumentation.runOnMainSync {
                val matches = resumed().filter { it !== excluding }
                check(matches.size <= 1) { "Ambiguous owned activity replacement" }
                current = matches.singleOrNull()?.takeIf { it.hasWindowFocus() }
            }
            current?.let { return it }
            if (SystemClock.elapsedRealtime() >= deadline) {
                record("owner_not_resumed", false)
                error("The original retained activity did not resume with its own focused window")
            }
            SystemClock.sleep(30)
        }
    }

    override fun close() {
        val deadline = SystemClock.elapsedRealtime() + 10_000
        while (true) {
            var gone = false
            instrumentation.runOnMainSync {
                val finishing = mutableSetOf<MainActivity>()
                for (stage in Stage.values()) {
                    ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(stage)
                        .filterIsInstance<MainActivity>().filter(::owned).forEach(finishing::add)
                }
                finishing.forEach { if (!it.isFinishing) it.finish() }
                // An empty monitor snapshot during recreation proves nothing. Only this
                // exact retained store's normal final clear confirms the owner has ended.
                gone = lifetime.cleared
            }
            if (gone) { record("closed", true); return }
            check(SystemClock.elapsedRealtime() < deadline) { "Owned activity did not confirm destruction" }
            SystemClock.sleep(30)
        }
    }

    private fun record(phase: String, passed: Boolean) {
        if (samples.length() >= 8) samples.remove(0)
        samples.put(JSONObject().put("phase", phase).put("passed", passed)
            .put("elapsedMs", (SystemClock.elapsedRealtime() - started).coerceIn(0, 300_000)))
        val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation")
        check(folder.isDirectory || folder.mkdirs())
        File(folder, "native-main-activity-${kind.name.lowercase()}.json").writeText(
            JSONObject().put("schema", 1).put("case", kind.name).put("retainedStoreAndTaskOwner", true)
                .put("forcedResume", false).put("replacementLaunch", false).put("samples", samples).toString(2))
    }

    companion object {
        fun launch(intent: Intent, kind: Kind): NativeMainActivityFixture {
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
            check(intent.component == ComponentName(instrumentation.targetContext, MainActivity::class.java))
            val first = instrumentation.startActivitySync(Intent(intent).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            check(first is MainActivity && first.packageName == instrumentation.targetContext.packageName)
            var fixture: NativeMainActivityFixture? = null
            instrumentation.runOnMainSync {
                val lifetime = ViewModelProvider(first, object : ViewModelProvider.Factory {
                    @Suppress("UNCHECKED_CAST")
                    override fun <T : ViewModel> create(modelClass: Class<T>): T {
                        check(modelClass == Lifetime::class.java)
                        return Lifetime() as T
                    }
                })["native-main-fixture-owner", Lifetime::class.java]
                fixture = NativeMainActivityFixture(kind, first.taskId, first.viewModelStore, lifetime)
            }
            return checkNotNull(fixture).also {
                try { it.awaitCurrent(); it.record("launched", true) }
                catch (failure: Throwable) {
                    runCatching { it.close() }.exceptionOrNull()?.let(failure::addSuppressed)
                    throw failure
                }
            }
        }
    }
}
