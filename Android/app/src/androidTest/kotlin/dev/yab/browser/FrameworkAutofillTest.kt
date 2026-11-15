package dev.yab.browser

import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.accessibilityservice.AccessibilityServiceInfo
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.BrowserController
import java.util.ArrayDeque
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Framework bind → AssistStructure → native dataset UI → actual web form values. */
@RunWith(AndroidJUnit4::class)
class FrameworkAutofillTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val fixture = BrowserInstrumentedTest()
    private var nativeView: org.mozilla.geckoview.GeckoView? = null
    private lateinit var nativeUi: OwnedBrowserTestUi
    private var lifecycleBinding: Pair<androidx.lifecycle.LifecycleOwner, androidx.lifecycle.LifecycleEventObserver>? = null

    @Test(timeout = 240_000)
    fun realAndroidProviderFillsFormsAndCannotFillAnotherContainerOrLockedPrivateView(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true") { "Autofill provider changes require the owned disposable emulator" }
        check(shell("getprop ro.kernel.qemu").trim() == "1") { "Refusing to change a physical device's provider" }
        val user = shell("am get-current-user").trim().also { check(it.matches(Regex("[0-9]+"))) }
        val component = instrumentation.context.packageName + "/dev.yab.browser.autofill.FixtureAutofillService"
        check(component.matches(Regex("[A-Za-z0-9_.$/]+")))
        val previous = shell("settings --user $user get secure autofill_service").trim()
        check(previous.isEmpty() || previous == "null" || previous.matches(Regex("[A-Za-z0-9_.$/]+"))) { "Unexpected provider format; preserving it" }
        OwnedLoopbackSiteSettings.reset()
        val originalFlags = instrumentation.uiAutomation.serviceInfo.flags
        val testFlags = originalFlags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        instrumentation.uiAutomation.serviceInfo = instrumentation.uiAutomation.serviceInfo.apply { flags = testFlags }
        try {
            shell("settings --user $user put secure autofill_service $component")
            await("test framework provider selected") { shell("settings --user $user get secure autofill_service").trim() == component }
            BrowserInstrumentedTest.FixtureServer().use { server ->
                var lifecycleEngine: GeckoEngine? = null
                fixture.withBrowser(configure = { lifecycleEngine = it }, viewBound = {
                    nativeView = it
                    observeNativeLifecycle(it, checkNotNull(lifecycleEngine))
                }) { browser, engine ->
                    nativeUi = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.AUTOFILL)
                    main { nativeUi.bind(browser, engine) }
                    val first = main {
                        fixture.ownSpace(browser, "Autofill first container")
                        browser.openUrl(server.url("/autofill/first"))
                        browser.state.value.space!!.id
                    }
                    page(browser, engine, "first")
                    fillFromFramework("first")
                    readValues(browser, engine, "fixture-first", "invented-password-first")
                    fixture.shot("autofill-framework-filled-first.png")
                    main { browser.openUrl(server.url("/autofill/authenticated"), newTab = false) }
                    page(browser, engine, "authenticated")
                    fillFromFramework("authenticated")
                    readValues(browser, engine, "fixture-authenticated", "invented-password-authenticated")
                    fixture.shot("autofill-framework-authentication-return.png")

                    val second = main {
                        fixture.ownSpace(browser, "Autofill second container")
                        browser.openUrl(server.url("/autofill/second"))
                        browser.state.value.space!!.id
                    }
                    page(browser, engine, "second")
                    readValues(browser, engine, "", "")
                    delay(500)
                    readValues(browser, engine, "", "")
                    fillFromFramework("second")
                    readValues(browser, engine, "fixture-second", "invented-password-second")

                    main { browser.selectSpace(first); browser.openUrl(server.url("/autofill/stale"), newTab = false) }
                    page(browser, engine, "stale")
                    focusUsername()
                    val stale = clickable(dataset("stale"), "stale native dataset")
                    fixture.shot("autofill-framework-before-container-swap.png")
                    main { browser.selectSpace(second); browser.openUrl(server.url("/autofill/destination"), newTab = false) }
                    page(browser, engine, "destination")
                    // This is the original Android popup node, not a synthetic fill call.
                    // Android may invalidate it, or Gecko may retain its old session mapping.
                    stale.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    delay(300)
                    readValues(browser, engine, "", "")
                    delay(500)
                    readValues(browser, engine, "", "")
                    assertNull("Old container's dataset stayed visible over the new document", exactNode("Yab fixture stale"))

                    main {
                        browser.openUrl(server.url("/autofill/private"), privately = true)
                        browser.unlockPrivate(true)
                    }
                    page(browser, engine, "private")
                    focusUsername()
                    val privateDataset = clickable(dataset("private"), "private native dataset")
                    main { browser.lockPrivate() }
                    await("private view removed") { browser.state.value.privateContentBlocked }
                    privateDataset.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    delay(300)
                    assertNull("Autofill suggestion remained above locked Private", exactNode("Yab fixture private"))
                    main { browser.unlockPrivate(true) }
                    page(browser, engine, "private")
                    readValues(browser, engine, "", "")
                    delay(500)
                    readValues(browser, engine, "", "")
                    // A fresh, explicit user choice after unlock is still supported.
                    fillFromFramework("private")
                    readValues(browser, engine, "fixture-private", "invented-password-private")
                    assertFalse(browser.publicSnapshot().toString().contains("invented-password-private"))
                    fixture.shot("autofill-framework-private-after-unlock.png")
                }
            }
        } finally {
            main { lifecycleBinding?.let { (owner, observer) -> owner.lifecycle.removeObserver(observer) }; lifecycleBinding = null }
            // This tag logs only our fixture's field-presence booleans and case
            // names. No broad log buffer, DOM input values or provider credentials.
            val out = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/autofill-fixture").apply { mkdirs() }
            File(out, "service.log").writeText(shell("logcat -d -s YabAutofillFixture:I '*:S'"))
            File(out, "framework-state.txt").writeText(shell("dumpsys autofill").take(60_000))
            NativeWebControlDiagnostics.capture("Framework autofill fixture completion")
            if (instrumentation.uiAutomation.serviceInfo.flags == testFlags) {
                instrumentation.uiAutomation.serviceInfo = instrumentation.uiAutomation.serviceInfo.apply { flags = originalFlags }
            }
            // Never overwrite a provider selected by another actor while the test ran.
            if (shell("settings --user $user get secure autofill_service").trim() == component) {
                if (previous.isEmpty() || previous == "null") shell("settings --user $user delete secure autofill_service")
                else shell("settings --user $user put secure autofill_service $previous")
                assertEquals("The original Autofill provider was not restored", previous.ifEmpty { "null" },
                    shell("settings --user $user get secure autofill_service").trim())
            }
        }
    }

    private suspend fun fillFromFramework(sample: String) {
        focusUsername()
        clickNode(dataset(sample), "native Android dataset $sample")
        if (sample == "authenticated") {
            fun originalAuthButton(): AccessibilityNodeInfo? {
                if (android.os.Build.VERSION.SDK_INT >= 34) check(instrumentation.uiAutomation.clearCache())
                val root = instrumentation.uiAutomation.rootInActiveWindow ?: return null
                if (root.packageName?.toString() != instrumentation.context.packageName) return null
                return root.findAccessibilityNodeInfosByText("USE FIXTURE CREDENTIAL").singleOrNull {
                    it.className?.toString() == "android.widget.Button" && it.isEnabled && it.isVisibleToUser &&
                        it.text?.toString()?.equals("Use fixture credential", ignoreCase = true) == true
                }
            }
            await("actual owned dataset authentication Activity") { originalAuthButton() != null }
            assertTrue(requireNotNull(originalAuthButton()).performAction(AccessibilityNodeInfo.ACTION_CLICK))
            await("original form returns after native dataset authentication") { main {
                nativeView?.let { it.isAttachedToWindow && it.isShown && it.hasWindowFocus() } == true
            } }
        }
        await("selected native dataset dismissed") { exactNode("Yab fixture $sample") == null }
    }

    private fun observeNativeLifecycle(view: android.view.View, engine: GeckoEngine) {
        var context: android.content.Context = view.context
        repeat(16) {
            if (context is android.app.Activity) return@repeat
            context = (context as? android.content.ContextWrapper)?.baseContext ?: return@repeat
        }
        val owner = checkNotNull(context as? androidx.lifecycle.LifecycleOwner)
        if (lifecycleBinding?.first === owner) return
        check(lifecycleBinding == null)
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            when (event) {
                androidx.lifecycle.Lifecycle.Event.ON_START -> engine.foreground()
                androidx.lifecycle.Lifecycle.Event.ON_STOP -> engine.background()
                else -> Unit
            }
        }
        lifecycleBinding = owner to observer
        owner.lifecycle.addObserver(observer)
    }

    private suspend fun dataset(sample: String): AccessibilityNodeInfo {
        try { await("real AutofillService dataset $sample", 30_000) { exactNode("Yab fixture $sample") != null } }
        catch (failure: Throwable) {
            NativeWebControlDiagnostics.capture("Autofill dataset missing $sample")
            main {
                val path = org.json.JSONArray()
                var view: android.view.View? = nativeView
                repeat(16) {
                    val current = view ?: return@repeat
                    path.put(org.json.JSONObject().put("class", current.javaClass.name)
                        .put("attached", current.isAttachedToWindow).put("shown", current.isShown)
                        .put("importantForAutofill", current.importantForAutofill)
                        .put("autofillType", current.autofillType).put("laidOut", current.isLaidOut)
                        .put("windowFocused", current.hasWindowFocus())
                        .put("frameworkEnabled", current.context.getSystemService(android.view.autofill.AutofillManager::class.java)?.isEnabled)
                        .put("children", (current as? android.view.ViewGroup)?.childCount ?: 0))
                    view = current.parent as? android.view.View
                }
                val folder = java.io.File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/autofill-fixture").apply { mkdirs() }
                java.io.File(folder, "native-view-path.json").writeText(org.json.JSONObject()
                    .put("viewPath", path).put("nativeAcceptance", false).toString(2))
            }
            throw failure
        }
        return exactNode("Yab fixture $sample")!!
    }

    private suspend fun focusUsername() {
        // Secure setting propagation is asynchronous. Require the framework's
        // app-side manager, not just the settings string, before the first focus.
        await("owned framework Autofill manager enabled") { main {
            nativeView?.let { view -> view.isAttachedToWindow && view.isLaidOut && view.hasWindowFocus() &&
                view.context.getSystemService(android.view.autofill.AutofillManager::class.java)?.isEnabled == true } == true
        } }
        await("web username input") { usernameNode() != null }
        // Use the actual finger path through Gecko/APZ. Accessibility ACTION_FOCUS
        // does not establish the native user-input state used by Autofill.
        // The HTML label belongs to this exact original tab/profile/document.
        nativeUi.tap("Fixture username")
    }

    private fun usernameNode(): AccessibilityNodeInfo? {
        val nodes = ArrayDeque<AccessibilityNodeInfo>()
        roots().forEach(nodes::add)
        var examined = 0
        while (nodes.isNotEmpty() && examined++ < 2000) {
            val node = nodes.removeFirst()
            if (node.isEditable && !node.isPassword && node.isEnabled && node.isVisibleToUser &&
                node.packageName?.toString() == instrumentation.targetContext.packageName) return node
            repeat(node.childCount) { node.getChild(it)?.let(nodes::add) }
        }
        return null
    }

    private fun roots(): List<AccessibilityNodeInfo> = buildList {
        if (android.os.Build.VERSION.SDK_INT >= 34) check(instrumentation.uiAutomation.clearCache())
        instrumentation.uiAutomation.rootInActiveWindow?.let(::add)
        instrumentation.uiAutomation.windows.mapNotNull { it.root }.forEach(::add)
    }

    private fun exactNode(text: String): AccessibilityNodeInfo? = roots().asSequence()
        .flatMap { it.findAccessibilityNodeInfosByText(text).asSequence() }
        .firstOrNull { it.text?.toString() == text && it.isVisibleToUser }

    private fun clickNode(start: AccessibilityNodeInfo, description: String) {
        assertTrue("Could not select $description", clickable(start, description).performAction(AccessibilityNodeInfo.ACTION_CLICK))
    }

    private fun clickable(start: AccessibilityNodeInfo, description: String): AccessibilityNodeInfo {
        var node = start
        repeat(6) {
            if (node.isClickable && node.isEnabled) return node
            node = node.parent ?: return@repeat
        }
        error("No clickable node for $description")
    }

    private suspend fun page(browser: BrowserController, engine: GeckoEngine, sample: String) {
        await("Autofill fixture $sample loaded", 30_000) { browser.state.value.page.let { !it.loading && it.title == "Autofill fixture $sample" } }
        text(browser, engine, "Username= Password=")
    }

    private suspend fun readValues(browser: BrowserController, engine: GeckoEngine, username: String, password: String) {
        val deadline = SystemClock.elapsedRealtime() + 15_000
        var observed = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            await("read form control") { OwnedWebControl.find("Read fixture values", className = "android.widget.Button") != null }
            val previous = main { engine.readText(browser.state.value.tab!!).text }
            val next = Regex("Read=([0-9]+) Username=").find(previous)!!.groupValues[1].toInt() + 1
            clickNode(requireNotNull(OwnedWebControl.find("Read fixture values", className = "android.widget.Button")), "fixture read control")
            // A fresh counter prevents the initial blank result from passing before
            // the real button has read the actual input values.
            text(browser, engine, "Read=$next Username=")
            observed = main { engine.readText(browser.state.value.tab!!).text }
            if (observed.lineSequence().any { it.trim() == "Read=$next Username=$username Password=$password" }) return
            delay(100)
        }
        error("Framework fill did not produce the expected input values. Last DOM: $observed")
    }

    private suspend fun text(browser: BrowserController, engine: GeckoEngine, expected: String) {
        val deadline = SystemClock.elapsedRealtime() + 20_000
        var observed = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            observed = runCatching { main { engine.readText(browser.state.value.tab!!).text } }.getOrDefault("")
            if (observed.contains(expected)) return
            delay(100)
        }
        error("Actual DOM did not contain $expected. Last text: $observed")
    }

    private fun shell(command: String): String = ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command))
        .bufferedReader().use { it.readText() }

    private suspend fun await(label: String, timeout: Long = 15_000, ready: suspend () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeout
        while (SystemClock.elapsedRealtime() < deadline) { if (ready()) return; delay(100) }
        NativeWebControlDiagnostics.capture(label)
        error("Timed out waiting for $label")
    }

    private suspend fun <T> main(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }
}
