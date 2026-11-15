package dev.yab.agent

import android.content.Intent
import android.graphics.Bitmap
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.BrowserAccessibilityPreferences
import dev.yab.browser.ui.BrowserTheme
import dev.yab.browser.ui.LocalBrowserAccessibility
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Actual draw/input clock on synthetic decrypted details. No provider, external file or biometric claim. */
@RunWith(AndroidJUnit4::class)
class ApprovalDetailDeviceTest {
    @Volatile private var fixtureInteraction: ApprovalInteraction? = null
    private val concurrentStart = AtomicBoolean()
    private val controlReceipts = JSONArray()
    private var controlProjection = JSONObject()
    private var bccProjection = JSONObject()
    private class Port : AgentSyncPort {
        override val connection = MutableStateFlow(RemoteConnection("fixture-account", listOf(RemoteMac("fixture-mac", "Fixture Mac", true, emptySet()))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        override suspend fun send(command: AgentSendCommand) = AgentSendReceipt()
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        override suspend fun answerApproval(answer: ApprovalAnswer): Unit = error("Reading a detail must never answer")
    }
    @Test(timeout = 90_000) fun actualMailWindowPictureAndPageReturnKeepTheirMeasuredAnchors(): Unit = runBlocking {
        fixture("mail-picture", false) { controller, _, frames, request, _ ->
            click("Read full email: First synthetic letter", controller)
            await("actual row-to-window frames") { frames.any { it.surface == ApprovalDrawSurface.WINDOW && it.detailProgress in .05.. .95 } &&
                controller.windowPresentation.frame.value.progress in .05.. .95 && "win:mail.0.picture" in controller.detailAnchors.frames.value }
            // A controlled source callback starts the nested spring before the parent is
            // settled. A later actual native click exercises the attachment control too.
            main {
                check(controller.windowPresentation.frame.value.running)
                val shown = checkNotNull(controller.trayPresentation.frame.value.content)
                ApprovalDetailActions(controller, shown, false, checkNotNull(fixtureInteraction)).openPicture(request.mails[0].files[0], request.previews[0], "win:mail.0.picture")
                check(controller.picturePresentation.frame.value.running); concurrentStart.set(true)
            }
            await("both concurrent details finish on the real shared clock") { controller.windowPresentation.frame.value.progress == 1.0 &&
                controller.picturePresentation.frame.value.progress == 1.0 }
            click("Close picture", controller)
            await("concurrent picture folds back without restarting its parent") { controller.picturePresentation.frame.value.target == null }
            shot("approval-mail-window.png")
            await("the actual returned window exposes its BCC") { hasText("bcc Fixture hidden recipient") }
            click("Open attachment: Fixture.jpg", controller)
            await("actual thumbnail-to-picture frames") { frames.any { it.surface == ApprovalDrawSurface.PICTURE && it.detailProgress in .05.. .95 } &&
                controller.picturePresentation.frame.value.progress == 1.0 }
            val picture = frames.last { it.surface == ApprovalDrawSurface.PICTURE && it.detailProgress == 1.0 }
            assertEquals(2.0, (picture.boundsPx.width / picture.boundsPx.height).toDouble(), .02)
            shot("approval-mail-picture.png")
            click("Close picture", controller)
            await("picture exits into its attachment") { controller.picturePresentation.frame.value.target == null }
            assertNotNull(controller.windowPresentation.frame.value.target)
            val window = frames.last { it.surface == ApprovalDrawSurface.WINDOW }.boundsPx
            swipe(window.left + window.width * .8f, window.top + 170 * picture.density,
                window.left + window.width * .2f, window.top + 170 * picture.density)
            await("actual horizontal page gesture") { controller.windowPages.frame.value.selected == 1 && !controller.windowPages.frame.value.running }
            click("Back", controller)
            await("window closes into the page now shown") { controller.windowPresentation.frame.value.target == null }
            assertTrue(controller.state.value.deferred.isEmpty()); assertTrue(controller.state.value.receipts.isEmpty())
        }
    }
    @Test(timeout = 90_000) fun recreatedDetailsAndQueuedOldRowsCannotSurviveAReconnectedOwner(): Unit = runBlocking {
        fixture("owner", false) { controller, port, frames, request, recompose ->
            click("Read full email: First synthetic letter", controller)
            await("open window") { controller.windowPresentation.frame.value.progress == 1.0 }
            click("Open attachment: Fixture.jpg", controller)
            await("open picture") { controller.picturePresentation.frame.value.progress == 1.0 }
            val old = main { checkNotNull(controller.trayPresentation.frame.value.content) }
            val oldAction = ApprovalDetailActions(controller, old, false, checkNotNull(fixtureInteraction))
            val recreated = System.nanoTime(); recompose()
            await("retained picture after Activity recreation") { frames.any { it.uptimeNanos >= recreated && it.surface == ApprovalDrawSurface.PICTURE && it.detailProgress == 1.0 } &&
                controller.picturePresentation.frame.value.target?.owner == old.key }
            main {
                port.connection.value = port.connection.value.copy(epoch = 1)
                controller.replaceValidated(listOf(request))
            }
            await("same-account new epoch clears all old detail content") { controller.windowPresentation.frame.value.target == null &&
                controller.picturePresentation.frame.value.target == null && controller.trayPresentation.frame.value.content?.key?.epoch == 1L }
            main { oldAction.openMail(0, "tray:mail.0") }
            assertNull(controller.windowPresentation.frame.value.target)
            assertTrue(controller.state.value.receipts.isEmpty()); assertTrue(controller.state.value.deferred.isEmpty())
        }
    }
    @Test(timeout = 90_000) fun reducedDetailsCrossfadeAtFullSizeAndNeutralBackDoesNotAnswer(): Unit = runBlocking {
        fixture("reduced", true) { controller, _, frames, _, _ ->
            click("Read full email: First synthetic letter", controller)
            await("actual reduced window fade") { frames.any { it.surface == ApprovalDrawSurface.WINDOW && it.opacity in .05.. .95 } &&
                !controller.windowPresentation.frame.value.running }
            val entered = frames.filter { it.surface == ApprovalDrawSurface.WINDOW }
            assertTrue(entered.isNotEmpty()); assertTrue(entered.all { it.detailProgress == 1.0 })
            assertTrue(entered.maxOf { it.boundsPx.top } - entered.minOf { it.boundsPx.top } < 1f)
            click("Open attachment: Fixture.jpg", controller)
            await("actual reduced picture fade") { frames.any { it.surface == ApprovalDrawSurface.PICTURE && it.opacity in .05.. .95 } &&
                !controller.picturePresentation.frame.value.running }
            assertTrue(frames.filter { it.surface == ApprovalDrawSurface.PICTURE }.all { it.detailProgress == 1.0 })
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
            await("neutral Back closes picture only") { controller.picturePresentation.frame.value.target == null }
            assertNotNull(controller.windowPresentation.frame.value.target)
            assertTrue(controller.state.value.receipts.isEmpty()); assertTrue(controller.state.value.deferred.isEmpty())
        }
    }
    private suspend fun fixture(name: String, reduced: Boolean,
        body: suspend (ApprovalController, Port, CopyOnWriteArrayList<ApprovalDrawFrame>, ApprovalRequest, suspend () -> Unit) -> Unit) {
        require(name in setOf("mail-picture", "owner", "reduced"))
        val instrumentation = InstrumentationRegistry.getInstrumentation(); val context = instrumentation.targetContext
        val port = Port(); val controller = ApprovalController(port)
        val bitmap = Bitmap.createBitmap(64, 32, Bitmap.Config.ARGB_8888)
        val bytes = try {
            bitmap.eraseColor(android.graphics.Color.rgb(64, 128, 180))
            ByteArrayOutputStream().use { output -> check(bitmap.compress(Bitmap.CompressFormat.JPEG, 85, output)); output.toByteArray() }
        } finally { bitmap.recycle() }
        val file = ApprovalFile("picture", "Fixture.jpg", "image/jpeg", bytes.size.toLong(), previewPages = 1, width = 1600, height = 800)
        val preview = ApprovalPreview(file.id, 0, java.util.Base64.getEncoder().encodeToString(bytes))
        val request = ApprovalRequest("fixture-detail-question", "fixture-account", "fixture-mac", 1,
            System.currentTimeMillis() + 300_000, "Claude", "Read these synthetic letters?", "Public detail fixture", ApprovalKind.MAIL_BATCH,
            mails = listOf(ApprovalMail("Fixture sender", listOf("Fixture recipient"), "First synthetic letter", "Synthetic first body.\n\nRead every word before allowing.",
                bcc = listOf("Fixture hidden recipient"), files = listOf(file)),
                ApprovalMail("Second fixture sender", listOf("Second fixture recipient"), "Second synthetic letter", "Synthetic second body.")),
            previews = listOf(preview))
        val frames = CopyOnWriteArrayList<ApprovalDrawFrame>(); val capped = AtomicBoolean()
        val scenario = ActivityScenario.launch<EngineTestActivity>(Intent(context, EngineTestActivity::class.java))
        var passed = false
        fun bind() = scenario.onActivity { activity -> activity.setContent {
            CompositionLocalProvider(LocalBrowserAccessibility provides BrowserAccessibilityPreferences(reduceMotion = reduced),
                LocalApprovalMotionObserver provides { frame -> if (frames.size < 2400) frames.add(frame) else capped.set(true) }) {
                BrowserTheme(BrowserAppearance.LIGHT) {
                    val interaction = rememberApprovalInteraction()
                    SideEffect { fixtureInteraction = interaction }
                    ApprovalPrompt(controller, null)
                }
            }
        } }
        try {
            bind(); main { controller.replaceValidated(listOf(request)) }
            await("actual ready tray and measured rows") { fixtureInteraction?.current() == true && controller.trayPresentation.frame.value.phase == ApprovalTravel.READY &&
                "tray:mail.0" in controller.detailAnchors.frames.value }
            body(controller, port, frames, request) { scenario.recreate(); bind() }
            check(!capped.get()) { "Bounded detail frame receipt truncated" }; passed = true
        } finally {
            try {
                if (!passed && name == "mail-picture") runCatching { shot("approval-mail-window.png") }
                    .onFailure { bccProjection.put("failedSceneScreenshotUnavailable", true) }
                val rows = JSONArray()
                frames.filter { it.surface in setOf(ApprovalDrawSurface.WINDOW, ApprovalDrawSurface.PICTURE) }.forEach { frame ->
                    rows.put(JSONObject().put("uptimeNanos", frame.uptimeNanos).put("surface", frame.surface.name)
                        .put("leftPx", frame.boundsPx.left).put("topPx", frame.boundsPx.top).put("widthPx", frame.boundsPx.width)
                        .put("heightPx", frame.boundsPx.height).put("opacity", frame.opacity).put("progress", frame.detailProgress))
                }
                val folder = File(context.getExternalFilesDir(null), "instrumentation"); check(folder.isDirectory || folder.mkdirs())
                val tray = controller.trayPresentation.frame.value
                val drawn = frames.lastOrNull { it.surface == ApprovalDrawSurface.TRAY }
                val source = JSONObject().put("phase", tray.phase.name).put("interactive", tray.interactive)
                    .put("rise", tray.rise).put("fold", tray.fold).put("height", tray.height)
                    .put("firstMailAnchorMeasured", "tray:mail.0" in controller.detailAnchors.frames.value)
                    .put("windowPresent", controller.windowPresentation.frame.value.target != null)
                    .put("picturePresent", controller.picturePresentation.frame.value.target != null)
                    .put("detailState", main { detailState(controller) })
                drawn?.let { source.put("drawnTrayBounds", JSONArray(listOf(it.boundsPx.left, it.boundsPx.top,
                    it.boundsPx.right, it.boundsPx.bottom).map { value -> value.coerceIn(-1_000_000f, 1_000_000f) })) }
                File(folder, "approval-detail-$name.json").writeText(JSONObject().put("passed", passed).put("clock", "real-device-draw")
                    .put("framesTruncated", capped.get()).put("controlledConcurrentStart", concurrentStart.get())
                    .put("providerAcceptance", false).put("iosFrameComparisonVerified", false).put("frames", rows)
                    .put("syntheticControlDiagnostics", controlReceipts).put("syntheticBccDiagnostics", bccProjection)
                    .put("trayAtEnd", source).toString())
            } finally { try { scenario.close() } finally { fixtureInteraction = null } }
        }
    }
    private suspend fun click(description: String, controller: ApprovalController) {
        val control = when (description) {
            "Read full email: First synthetic letter" -> "FIRST_MAIL"
            "Open attachment: Fixture.jpg" -> "ATTACHMENT"
            "Close picture" -> "CLOSE_PICTURE"
            "Back" -> "BACK"
            else -> error("Only fixed synthetic detail controls may be inspected")
        }
        val owner = main {
            val shown = checkNotNull(controller.trayPresentation.frame.value.content)
            check(shown.action?.let(controller::isDisplayedCurrent) == true)
            shown.key
        }
        suspend fun current() = main {
            controller.trayPresentation.frame.value.content?.let { shown ->
                shown.key == owner && shown.action?.let(controller::isDisplayedCurrent) == true
            } == true
        }
        fun visibleBounds(): android.graphics.Rect {
            val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
            val root = checkNotNull(automation.rootInActiveWindow)
            try {
                check(root.packageName?.toString() == InstrumentationRegistry.getInstrumentation().targetContext.packageName)
                val node = checkNotNull(actionNode(description))
                try {
                    check(node.windowId == root.windowId)
                    val rootBounds = android.graphics.Rect().also(root::getBoundsInScreen)
                    val row = android.graphics.Rect().also(node::getBoundsInScreen)
                    check(!row.isEmpty && rootBounds.contains(row))
                    return row
                } finally { node.recycle() }
            } finally { root.recycle() }
        }
        var clicked = false
        var pressed = false
        var down = 0L
        var point: android.graphics.Rect? = null
        var failure: Throwable? = null
        var ownerAfterDown: Boolean? = null
        var boundsAfterDown: android.graphics.Rect? = null
        val beforeInput = main { detailState(controller) }
        var afterUp: JSONObject? = null
        fun touch(action: Int) {
            val row = checkNotNull(point)
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, row.exactCenterX(), row.exactCenterY(), 0)
                .apply { source = InputDevice.SOURCE_TOUCHSCREEN }
            try { check(InstrumentationRegistry.getInstrumentation().uiAutomation.injectInputEvent(event, true)) }
            finally { event.recycle() }
        }
        try {
            await("known synthetic detail control") { actionNode(description)?.let { it.recycle(); true } == true }
            // The controller can settle before its next drawn/accessibility frame.
            // Measure the same fixed control until its actual geometry is stable;
            // the originally captured owner remains required throughout the tap.
            var measured = visibleBounds()
            var unchangedAt = SystemClock.elapsedRealtime()
            await("stable synthetic detail bounds before pointer down") {
                val now = SystemClock.elapsedRealtime()
                val next = runCatching { visibleBounds() }.getOrNull()
                if (next == null || next != measured) {
                    if (next != null) measured = next
                    unchangedAt = now
                    false
                } else now - unchangedAt >= 96
            }
            check(current()) { "Synthetic detail owner changed before its tap" }
            point = visibleBounds().also { check(it == measured) { "Synthetic detail moved before its tap" } }
            down = SystemClock.uptimeMillis()
            touch(MotionEvent.ACTION_DOWN); pressed = true
            delay(32)
            ownerAfterDown = current()
            if (ownerAfterDown == true) boundsAfterDown = runCatching { visibleBounds() }.getOrNull()
            check(ownerAfterDown == true && boundsAfterDown == measured) { "Synthetic detail owner or geometry changed during its tap" }
            touch(MotionEvent.ACTION_UP); pressed = false; clicked = true
            afterUp = main { detailState(controller) }
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            val cancelError = if (pressed) runCatching { touch(MotionEvent.ACTION_CANCEL) }.exceptionOrNull() else null
            if (controlReceipts.length() < 16) controlReceipts.put(JSONObject().put("control", control)
                .put("clicked", clicked).put("input", "OWNED_EXACT_LABEL_NATIVE_TOUCH").put("talkBackActionVerified", false)
                .put("cancelAttempted", pressed).put("cancelConfirmed", pressed && cancelError == null)
                .put("ownerAfterDown", ownerAfterDown ?: JSONObject.NULL)
                .put("beforeInput", beforeInput).put("afterUp", afterUp ?: JSONObject.NULL)
                .put("downBounds", point?.let { JSONArray(listOf(it.left, it.top, it.right, it.bottom)) } ?: JSONObject.NULL)
                .put("afterDownBounds", boundsAfterDown?.let { JSONArray(listOf(it.left, it.top, it.right, it.bottom)) } ?: JSONObject.NULL)
                .put("projection", controlProjection))
            if (cancelError != null) failure?.addSuppressed(cancelError) ?: throw cancelError
        }
    }
    /** Only bounded numeric state of this synthetic question, never request contents. */
    private fun detailState(controller: ApprovalController): JSONObject {
        fun frame(value: ApprovalDetailFrame) = JSONObject().put("present", value.target != null)
            .put("opening", value.opening).put("progress", value.progress).put("drag", value.drag)
            .put("running", value.running)
        val pages = controller.windowPages.frame.value
        return JSONObject().put("window", frame(controller.windowPresentation.frame.value))
            .put("picture", frame(controller.picturePresentation.frame.value))
            .put("pageSelected", pages.selected).put("pageRunning", pages.running)
            .put("pageGesture", pages.gesture?.name ?: JSONObject.NULL)
            .put("detailClockRunning", controller.detailClock.running)
    }
    private fun actionNode(description: String): AccessibilityNodeInfo? {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val own = InstrumentationRegistry.getInstrumentation().targetContext.packageName
        var visited = 0
        var rootOwned = 0; var rootMissing = 0; var rootForeign = 0; var rootPackageMissing = 0
        var descriptionMatches = 0; var textMatches = 0; var descriptionContains = 0
        var packageMissing = 0; var packageForeign = 0
        var childrenTruncated = false
        val matched = JSONArray()
        val rootBounds = android.graphics.Rect()
        val candidates = mutableListOf<AccessibilityNodeInfo>()
        fun find(node: AccessibilityNodeInfo) {
            if (++visited > 512) return
            val packageName = node.packageName?.toString()
            if (packageName != own) {
                if (packageName == null) packageMissing++ else packageForeign++
                return
            }
            val exactDescription = node.contentDescription?.toString() == description
            val exactText = node.text?.toString() == description
            val contains = node.contentDescription?.toString()?.contains(description) == true
            if (exactDescription) descriptionMatches++
            if (exactText) textMatches++
            if (contains) descriptionContains++
            if ((exactDescription || exactText || contains) && matched.length() < 4) {
                val bounds = android.graphics.Rect(); node.getBoundsInScreen(bounds)
                var nearestDepth: Int? = null
                var parent = node.parent
                for (depth in 1..5) {
                    val candidate = parent ?: break
                    try {
                        if (nearestDepth == null && candidate.packageName?.toString() == own && candidate.isVisibleToUser &&
                            candidate.isEnabled && candidate.isClickable) nearestDepth = depth
                        parent = candidate.parent
                    } finally { candidate.recycle() }
                }
                parent?.recycle()
                matched.put(JSONObject().put("exactDescription", exactDescription).put("exactText", exactText)
                    .put("visible", node.isVisibleToUser).put("enabled", node.isEnabled).put("clickable", node.isClickable)
                    .put("actionClick", node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK })
                    .put("clickableAncestorDepth", nearestDepth ?: JSONObject.NULL).put("boundsNonempty", !bounds.isEmpty)
                    .put("intersectsRoot", android.graphics.Rect.intersects(rootBounds, bounds))
                    .put("bounds", JSONArray(listOf(bounds.left, bounds.top, bounds.right, bounds.bottom).map { it.coerceIn(-1_000_000, 1_000_000) })))
            }
            if (exactDescription && node.isVisibleToUser && node.isEnabled) candidates.add(AccessibilityNodeInfo.obtain(node))
            if (node.childCount > 128) childrenTruncated = true
            for (index in 0 until node.childCount.coerceAtMost(128)) {
                val child = node.getChild(index) ?: continue
                try { find(child) } finally { child.recycle() }
            }
        }
        // As in the passing Popup fixture, use the active root. getWindows()
        // requires FLAG_RETRIEVE_INTERACTIVE_WINDOWS and otherwise returned an
        // empty list in all3 actual ce35 cases before any control was searched.
        // No service flag, permission or foreign/background window is enabled.
        val root = automation.rootInActiveWindow
        var found: AccessibilityNodeInfo? = null
        if (root == null) rootMissing++
        else {
            when (root.packageName?.toString()) { own -> rootOwned++; null -> rootPackageMissing++; else -> rootForeign++ }
            root.getBoundsInScreen(rootBounds)
            try { find(root) } finally { root.recycle() }
        }
        if (visited <= 512 && !childrenTruncated && candidates.size == 1) found = candidates.removeAt(0)
        candidates.forEach { it.recycle() }
        controlProjection = JSONObject().put("rootAcquisition", "ROOT_IN_ACTIVE_WINDOW").put("activeRootPresent", root != null)
            .put("interactiveWindowsRequested", automation.serviceInfo.flags and android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS != 0)
            .put("ownedRoots", rootOwned)
            .put("missingRoots", rootMissing).put("foreignRoots", rootForeign).put("rootPackageMissing", rootPackageMissing)
            .put("visited", visited.coerceAtMost(513)).put("capped", visited > 512)
            .put("childrenTruncated", childrenTruncated)
            .put("nodePackageMissing", packageMissing).put("nodePackageForeign", packageForeign)
            .put("exactDescriptionMatches", descriptionMatches).put("exactTextMatches", textMatches)
            .put("descriptionContainsKnownControl", descriptionContains).put("matchedStates", matched)
            .put("uniqueVisibleExactLabel", found != null)
        return found
    }
    private fun hasText(words: String): Boolean {
        require(words == "bcc Fixture hidden recipient")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val root = instrumentation.uiAutomation.rootInActiveWindow ?: return false
        try {
            val own = instrumentation.targetContext.packageName
            if (root.packageName?.toString() != own) return false
            val rootBounds = android.graphics.Rect().also(root::getBoundsInScreen)
            val indexed = root.findAccessibilityNodeInfosByText(words)
            val indexedCount = indexed.size
            indexed.forEach { it.recycle() }
            var visited = 0
            var childrenTruncated = false
            var exactVisible = 0
            val rows = JSONArray()
            fun visit(node: AccessibilityNodeInfo) {
                if (++visited > 512 || node.packageName?.toString() != own || node.windowId != root.windowId) return
                val exact = node.text?.toString() == words
                if (exact) {
                    val bounds = android.graphics.Rect().also(node::getBoundsInScreen)
                    val inside = !bounds.isEmpty && rootBounds.contains(bounds)
                    if (node.isVisibleToUser && inside) exactVisible++
                    if (rows.length() < 8) rows.put(JSONObject().put("visible", node.isVisibleToUser)
                        .put("exactText", true).put("sameWindow", true).put("insideRoot", inside)
                        .put("bounds", JSONArray(listOf(bounds.left, bounds.top, bounds.right, bounds.bottom)
                            .map { it.coerceIn(-1_000_000, 1_000_000) })))
                }
                if (node.childCount > 128) childrenTruncated = true
                for (index in 0 until node.childCount.coerceAtMost(128)) {
                    val child = node.getChild(index) ?: continue
                    try { visit(child) } finally { child.recycle() }
                }
            }
            // The native controls already use this same bounded active-root walk.
            // Keep exact full BCC text, visibility, window and geometry requirements.
            visit(root)
            bccProjection = JSONObject().put("indexedQueryMatches", indexedCount.coerceAtMost(999))
                .put("visited", visited.coerceAtMost(513)).put("traversalCapped", visited > 512)
                .put("childrenTruncated", childrenTruncated).put("exactVisibleMatches", exactVisible.coerceAtMost(999))
                .put("knownBccMatches", rows)
            return visited <= 512 && !childrenTruncated && exactVisible == 1
        } finally { root.recycle() }
    }
    private suspend fun swipe(x: Float, y: Float, endX: Float, endY: Float) {
        val down = SystemClock.uptimeMillis()
        fun event(action: Int, xAt: Float, yAt: Float) {
            val value = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, xAt, yAt, 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
            try { check(InstrumentationRegistry.getInstrumentation().uiAutomation.injectInputEvent(value, true)) } finally { value.recycle() }
        }
        event(MotionEvent.ACTION_DOWN, x, y)
        for (index in 1..12) { delay(16); event(MotionEvent.ACTION_MOVE, x + (endX - x) * index / 12, y + (endY - y) * index / 12) }
        event(MotionEvent.ACTION_UP, endX, endY)
    }
    private fun shot(name: String) {
        require(name in setOf("approval-mail-window.png", "approval-mail-picture.png"))
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val root = checkNotNull(instrumentation.uiAutomation.rootInActiveWindow)
        try { check(root.packageName?.toString() == instrumentation.targetContext.packageName) } finally { root.recycle() }
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {
            val output = ByteArrayOutputStream(); check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
            check(output.size() in 1..4 * 1024 * 1024)
            val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation"); check(folder.isDirectory || folder.mkdirs())
            File(folder, name).writeBytes(output.toByteArray())
        } finally { bitmap.recycle() }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
    private suspend fun await(name: String, predicate: () -> Boolean) {
        val deadline = System.nanoTime() + 20_000_000_000L
        while (!predicate()) { check(System.nanoTime() < deadline) { "Timed out: $name" }; delay(20) }
    }
}
