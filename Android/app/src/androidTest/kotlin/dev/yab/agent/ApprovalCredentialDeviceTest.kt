package dev.yab.agent

import android.app.KeyguardManager
import android.app.UiAutomation
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.Process
import android.os.SystemClock
import android.system.Os
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inspector.WindowInspector
import androidx.activity.compose.setContent
import androidx.biometric.BiometricManager
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.BrowserTheme
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Explicit api29-pin profile only. Real Keyguard results; controlled transport, no provider claim. */
@RunWith(AndroidJUnit4::class)
class ApprovalCredentialDeviceTest {
    @Test(timeout = 240_000)
    fun actualApi29PinCancelReplacementRecreationAndFreshConfirmation(): Unit = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        check(args.getString("ownedEmulator") == "true" && args.getString("api29CredentialTest") == "true")
        check(Build.VERSION.SDK_INT == 29 && Build.HARDWARE in setOf("ranchu", "goldfish"))
        val nonce = checkNotNull(args.getString("approvalTestNonce")).also { check(it.matches(Regex("[0-9a-f]{32}"))) }
        val fixture = Fixture(nonce)
        val pin = readOwnedPin(nonce)
        var failure: Throwable? = null
        try { fixture.runCases(pin) }
        catch (error: Throwable) { failure = error }
        finally {
            pin.fill('\u0000')
            withContext(NonCancellable) {
                if (failure != null) runCatching { fixture.captureFailure() }
                try { fixture.close() } catch (error: Throwable) {
                    if (failure == null) { failure = error; runCatching { fixture.captureFailure(cleanup = true) } } else failure!!.addSuppressed(error)
                }
                try { fixture.save(failure == null) } catch (error: Throwable) { if (failure == null) failure = error else failure!!.addSuppressed(error) }
            }
        }
        failure?.let { throw it }
    }

    /** Read once, remove before OS entry. Parse/input exceptions never carry the payload as a cause. */
    private fun readOwnedPin(nonce: String): CharArray {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val parent = File(context.filesDir, "instrumentation")
        val file = File(parent, "approval-pin-$nonce.json")
        check(!Files.isSymbolicLink(parent.toPath()) && !Files.isSymbolicLink(file.toPath()))
        check(file.canonicalFile.parentFile == parent.canonicalFile && Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS))
        check(Os.lstat(file.path).st_uid == Process.myUid())
        val bytes = ByteArray(513)
        try {
            var count = 0
            file.inputStream().use { input ->
                while (count < bytes.size) { val read = input.read(bytes, count, bytes.size - count); if (read < 0) break; count += read }
            }
            check(count in 1..512) { "Owned credential input size refused" }
            val value = try { JSONObject(String(bytes, 0, count, Charsets.UTF_8)) }
                catch (_: Exception) { error("Owned credential input schema refused") }
            check(value.keys().asSequence().toSet() == setOf("nonce", "pin")) { "Owned credential input schema refused" }
            check(value.opt("nonce") == nonce) { "Owned credential input nonce refused" }
            val pin = (value.opt("pin") as? String)?.takeIf { it.matches(Regex("[0-9]{4,16}")) }
                ?: error("Owned credential input schema refused")
            return pin.toCharArray()
        } finally { bytes.fill(0); check(file.delete() && !file.exists()) { "Owned credential input removal failed" } }
    }

    private class Port(initial: ApprovalRequest) : AgentSyncPort {
        override val connection = MutableStateFlow(RemoteConnection("fixture-api29-account", listOf(RemoteMac("fixture-api29-mac", "Fixture Mac", true, emptySet()))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        val identity = ApprovalAuthenticationIdentity("fixture-api29-account", "fixture-api29-phone", 0)
        @Volatile var expected = initial
        val answers = CopyOnWriteArrayList<ApprovalAnswer>()
        @Volatile var liveTicketWriteCount = 0
            private set
        @Volatile var liveTicketAtWrite: ApprovalInteractionTicket? = null
            private set
        override fun approvalAuthenticationIdentity() = identity
        override suspend fun send(command: AgentSendCommand) = AgentSendReceipt()
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        override suspend fun answerApproval(answer: ApprovalAnswer) {
            val ticket = answer.requireCurrentInteraction()
            check(answer.request === expected && answer.approved && answer.choice == null && answer.picks == ApprovalPicks())
            check(answer.authenticationIdentity == identity && answer.expectedEpoch == 0L)
            check(answer.proof?.let { System.currentTimeMillis() - it.authenticatedAt in 0..60_000 } == true)
            ticket.withCurrent {
                check(answers.isEmpty()); check(liveTicketWriteCount == 0 && liveTicketAtWrite == null)
                liveTicketAtWrite = ticket; liveTicketWriteCount = 1
                answers += answer
            }
        }
    }

    private class Fixture(private val nonce: String) {
        private enum class SetupStep { NONE, SECURE, BIOMETRIC, LAUNCH, BIND, PUBLISH, READY }
        private enum class AwaitStep(val reason: String) {
            NONE(""), READY("Original owned approval UI ready"), PIN_STOP("Owned system credential screen and actual STOP"),
            PIN_RETURN("Actual return from credential screen"), PIN_CANCEL("Actual system credential cancellation"),
            CONFIRM("Actual RESULT_OK confirmation notice"), ANSWER("One actual guarded answer")
        }
        private enum class FailureCode { NONE, SECURE_CHECK, BIOMETRIC_CHECK, ACTIVITY_LAUNCH, ACTIVITY_BIND,
            REQUEST_PUBLICATION, READY_CHECK, AWAIT_CONDITION, AWAIT_TIMEOUT, FOREGROUND_REFUSED, FUNCTIONAL_CHECK, CLEANUP }
        private enum class RootKind { UNOBSERVED, NULL, OWN, SETTINGS, PINNED_HOME, OTHER }
        private enum class DialogState { UNOBSERVED, WAITING, ROOT_CAP_REFUSED, AMBIGUOUS, AX_PENDING, BOUND, FOCUS_WAIT, AX_REFUSED, REVOKED }
        private enum class CancelStep { NONE, SESSION, PROJECTION, TARGET, POINTER, SOURCE, TARGET_CURRENT, SOURCE_AFTER, RETURN, COMPLETE }
        private enum class PointerStep { NONE, SOURCE_BEFORE_DOWN, DOWN, DOWN_SENT, SOURCE_BEFORE_UP, UP, COMPLETE,
            CANCEL_SOURCE, CANCEL, CANCELLED }
        private enum class BackStep { NONE, CAPTURE, SOURCE, ROOT_REFRESH, FIELD_REFRESH, ACTIVE_ROOT, STABLE, DOWN, UP, RETURN, COMPLETE, REFUSED }
        private enum class BackCaptureStep { NONE, SESSION, EMPTY_LEASE, SOURCE_BEFORE, ROOT_READ, ROOT_MATCH, WALK,
            FIELD_MATCH, FIELD_COPY, FIELD_REQUIRED, ROOT_COPY, ROOT_CLASS, FIELD_CLASS, METADATA, SOURCE_AFTER, COMPLETE }
        private val instrumentation = InstrumentationRegistry.getInstrumentation()
        private lateinit var automation: UiAutomation
        private val context = instrumentation.targetContext
        private val own = context.packageName
        private val original = ApprovalRequest("fixture-api29-question", "fixture-api29-account", "fixture-api29-mac", 1,
            System.currentTimeMillis() + 300_000, "Claude", "API29 original facts", "Owned credential fixture", requestDigest = "fixture-api29-original", sourceEpoch = 0)
        private val replacement = original.copy(revision = 2, title = "API29 replacement facts", requestDigest = "fixture-api29-replacement")
        private val port = Port(original)
        private val controller = ApprovalController(port)
        private var scenario: ActivityScenario<EngineTestActivity>? = null
        @Volatile private var activity: EngineTestActivity? = null
        // Main-owned, captured only once per actual Activity. Expected Keyguard focus loss does
        // not borrow a new window; structural loss permanently refuses this original lease.
        private var dialog: DialogLease? = null
        private var dialogRevoked = false
        private var dialogState = DialogState.UNOBSERVED
        private var processRootCount = 0
        private var dialogCandidateCount = 0
        private var dialogCaptureCount = 0
        private val stops = AtomicInteger()
        private val resumes = AtomicInteger()
        private val destroys = AtomicInteger()
        private val rows = JSONArray()
        private var phase = "SETUP"
        private var credential: SettingsSession? = null
        private var backLease: CredentialBackLease? = null
        private var backStep = BackStep.NONE
        private var backCaptureStep = BackCaptureStep.NONE
        private var backPairs = 0
        private var backUpOmitted = false
        private var backInputClosed = false
        private var backLeaseCaptured = false
        private var backNodesReleased = true
        private var enterUpOmitted = false
        private var cancelConfirmed = false
        private var replacementConfirmed = false
        private var recreationConfirmed = false
        private var confirmationSeen = false
        private var beforeSecondTap = -1
        private var cleanupConfirmed = false
        private var setup = SetupStep.NONE
        private val setupSteps = JSONArray()
        private var secureObserved = false
        private var secure = false
        private var biometricObserved = false
        private var weakBiometricUnavailable = false
        private var lastAwait = AwaitStep.NONE
        private var awaitAttempts = 0
        private var awaitActive = false
        private var failureCode = FailureCode.NONE
        private var rootKind = RootKind.UNOBSERVED
        private var approveObserved = false
        private var approveTreeComplete = false
        private var approvePresent = false
        private var approveHit = false
        private var approveMatches = 0
        private var approveVisibleMatches = 0
        private var approveEnabledMatches = 0
        private var approveEligibleMatches = 0
        private var approveActionableMatches = 0
        private var approveExtraAdvertised = 0
        private var approveExtraRequested = 0
        private var approveExactTagMatches = 0
        private var approveRefreshRefused = 0
        private var approveTaggedTextLabels = 0
        private var approveLabelRefreshRequested = 0
        private var pendingObserved = false
        private var pendingPresent = false
        private var cancelStep = CancelStep.NONE
        private var pointerStep = PointerStep.NONE
        private var pointerFailureStep = PointerStep.NONE
        private var settingsObserved = false
        private var settingsTreeComplete = false
        private var settingsPasswordNodes = 0
        private var settingsPasswordEligible = 0
        private var settingsCancelNodes = 0
        private var settingsCancelEligible = 0
        private var settingsAlternateCancelNodes = 0
        private var settingsAlternateCancelVisibleEnabled = 0
        private var failureProjection: JSONObject? = null

        private fun setup(step: SetupStep) {
            setup = step
            check(setupSteps.length() < 6)
            setupSteps.put(JSONObject().put("step", step.name).put("completed", false))
        }
        private fun setupCompleted() { setupSteps.getJSONObject(setupSteps.length() - 1).put("completed", true) }
        private fun rootObserved(pkg: String?) {
            rootKind = when (pkg) { own -> RootKind.OWN; SETTINGS -> RootKind.SETTINGS
                "com.android.launcher3" -> RootKind.PINNED_HOME; else -> RootKind.OTHER }
            if (pkg != own && pkg != SETTINGS) failureCode = FailureCode.FOREGROUND_REFUSED
        }

        suspend fun runCases(pin: CharArray) {
            // Connect the existing public AX client off Main before asking a native root for its
            // accessibility window ID. No foreign window query is made by WindowInspector.
            automation = withContext(Dispatchers.Default) { instrumentation.uiAutomation }
            setup(SetupStep.SECURE)
            secure = context.getSystemService(KeyguardManager::class.java).isDeviceSecure; secureObserved = true
            check(secure); setupCompleted()
            setup(SetupStep.BIOMETRIC)
            weakBiometricUnavailable = BiometricManager.from(context).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK) != BiometricManager.BIOMETRIC_SUCCESS
            biometricObserved = true; check(weakBiometricUnavailable); setupCompleted()
            setup(SetupStep.LAUNCH)
            scenario = ActivityScenario.launch(Intent(context, EngineTestActivity::class.java))
            setupCompleted(); setup(SetupStep.BIND)
            bind(); setupCompleted(); setup(SetupStep.PUBLISH)
            main { controller.replaceValidated(listOf(original)) }; setupCompleted(); setup(SetupStep.READY)
            ready(); setupCompleted()
            cancelCase()
            lateReplacementCase(pin)
            recreationCase(pin)
            finalConfirmationCase(pin)
        }
        private fun bind() {
            checkNotNull(scenario).onActivity { owned ->
                val previous = activity
                check(previous == null || (previous !== owned && previous.isDestroyed))
                activity = owned
                dialog = null; dialogRevoked = false; dialogState = DialogState.UNOBSERVED
                owned.lifecycle.addObserver(LifecycleEventObserver { _, event -> when (event) {
                    Lifecycle.Event.ON_STOP -> stops.incrementAndGet()
                    Lifecycle.Event.ON_RESUME -> resumes.incrementAndGet()
                    Lifecycle.Event.ON_DESTROY -> destroys.incrementAndGet()
                    else -> Unit
                } })
                owned.setContent { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller, BiometricApprovalGate(owned)) } }
            }
        }
        private suspend fun cancelCase() {
            phase = "REAL_CANCEL"; launchPin(); cancelPin()
            ready(); assertTrue(port.answers.isEmpty()); assertFalse(appLabel(CONFIRM).present)
            cancelConfirmed = true; sample()
        }
        private suspend fun lateReplacementCase(pin: CharArray) {
            phase = "LATE_REPLACEMENT"; launchPin()
            main { port.expected = replacement; controller.replaceValidated(listOf(replacement)) }
            enterPin(pin); ready()
            assertFalse(appLabel(CONFIRM).present); assertTrue(port.answers.isEmpty())
            sample()
        }
        private suspend fun recreationCase(pin: CharArray) {
            phase = "READY_RECREATION"; launchPin(); replacementConfirmed = true; enterPin(pin); confirmation()
            val old = checkNotNull(activity); val before = destroys.get()
            check(sourceCurrent(old, port.expected, true) && ownResumed())
            checkNotNull(scenario).recreate(); bind(); ready()
            assertNotSame(old, activity); assertTrue(destroys.get() > before)
            assertFalse(appLabel(CONFIRM).present); assertTrue(port.answers.isEmpty())
            sample()
        }
        private suspend fun finalConfirmationCase(pin: CharArray) {
            phase = "FRESH_PIN"; launchPin(); recreationConfirmed = true; enterPin(pin); confirmation()
            ready()
            assertTrue(appLabel(CONFIRM).present)
            phase = "FRESH_SECOND_TAP"; beforeSecondTap = port.answers.size
            assertEquals(0, beforeSecondTap); tapApprove()
            await(AwaitStep.ANSWER) { port.answers.size == 1 }
            val delivered = port.answers.single()
            assertSame(replacement, delivered.request)
            assertEquals(port.identity, delivered.authenticationIdentity)
            assertEquals(1, port.liveTicketWriteCount); assertSame(delivered.interaction, port.liveTicketAtWrite)
            assertTrue(main { controller.state.value.receipts.singleOrNull()?.request === replacement })
            phase = "COMPLETE"; sample()
        }
        private suspend fun launchPin() {
            backCaptureStep = BackCaptureStep.NONE
            val source = checkNotNull(activity); val request = port.expected; val before = stops.get()
            tapApprove()
            await(AwaitStep.PIN_STOP) {
                val value = settings()
                if (value != null && stops.get() > before && sourceCurrent(source, request, false)) {
                    backCaptureStep = BackCaptureStep.SESSION
                    val session = SettingsSession(source, value.window, value.root, value.field)
                    credential = session
                    backCaptureStep = BackCaptureStep.EMPTY_LEASE
                    check(backLease == null)
                    backLease = captureBackLease(session, request); true
                } else false
            }
            assertTrue(port.answers.isEmpty()); sample()
        }
        private suspend fun enterPin(pin: CharArray) {
            val session = checkNotNull(credential)
            val request = port.expected
            for (digit in pin) key(session, request, KeyEvent.KEYCODE_0 + (digit - '0'))
            // TextView's editor listener may finish Settings on ENTER DOWN. Never retarget UP to
            // the returning app or any foreign window after that legitimate terminal transition.
            settingsCurrent(session, request); val down = SystemClock.uptimeMillis()
            injectKey(down, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER)
            if (settingsAdmitted(session, request)) injectKey(down, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER)
            else { enterUpOmitted = true; checkKnownTransition(); check(main { activity === session.source && !session.source.isDestroyed && port.expected === request && port.answers.isEmpty() }) }
            await(AwaitStep.PIN_RETURN) { ownResumed() }
            credential = null
            releaseBackLease()
        }
        private suspend fun cancelPin() {
            cancelStep = CancelStep.SESSION; pointerStep = PointerStep.NONE; pointerFailureStep = PointerStep.NONE
            val session = checkNotNull(credential)
            val lease = checkNotNull(backLease)
            check(lease.session === session && !lease.revoked)
            // This same deadline, pair count and any pending DOWN survive failure cleanup.
            if (lease.deadline == 0L) lease.deadline = SystemClock.elapsedRealtime() + 25_000
            lastAwait = AwaitStep.PIN_CANCEL; awaitAttempts = 0; awaitActive = true
            while (SystemClock.elapsedRealtime() < lease.deadline) {
                awaitAttempts = (awaitAttempts + 1).coerceAtMost(255)
                backStep = BackStep.RETURN; cancelStep = CancelStep.RETURN
                if (backReturned(lease)) {
                    if (lease.downPending) { backUpOmitted = true; lease.downPending = false }
                    lease.inputClosed = true; backInputClosed = true
                    awaitActive = false; credential = null
                    backStep = BackStep.COMPLETE; cancelStep = CancelStep.COMPLETE
                    releaseBackLease(); return
                }
                if (!lease.inputClosed && (lease.downPending || lease.pairs < 2)) backPair(lease)
                delay(100)
            }
            if (failureCode == FailureCode.NONE) failureCode = FailureCode.AWAIT_TIMEOUT
            error("Timed out: ${AwaitStep.PIN_CANCEL.reason}")
        }
        /** Initial acquisition only, after the original PIN_STOP projection and source passed. */
        private suspend fun captureBackLease(session: SettingsSession, request: ApprovalRequest): CredentialBackLease {
            backStep = BackStep.CAPTURE
            backCaptureStep = BackCaptureStep.SOURCE_BEFORE
            check(sourceCurrent(session.source, request, false))
            backCaptureStep = BackCaptureStep.ROOT_READ
            val root = checkNotNull(automation.rootInActiveWindow) { "Original credential Back root unavailable" }
            var field: AccessibilityNodeInfo? = null
            var retainedRoot: AccessibilityNodeInfo? = null
            try {
                val bounds = Rect().also(root::getBoundsInScreen)
                backCaptureStep = BackCaptureStep.ROOT_MATCH
                check(root.packageName?.toString() == SETTINGS && root.windowId == session.window && bounds == session.root)
                backCaptureStep = BackCaptureStep.WALK
                walk(root, SETTINGS, session.window) { node ->
                    if (node.viewIdResourceName == "$SETTINGS:id/password_entry" && node.isVisibleToUser && node.isEnabled &&
                        node.isPassword && node.isEditable && node.isFocused) {
                        val rect = Rect().also(node::getBoundsInScreen)
                        if (!rect.isEmpty && bounds.contains(rect)) {
                            backCaptureStep = BackCaptureStep.FIELD_MATCH
                            check(field == null && rect == session.field) { "Original credential Back field changed" }
                            backCaptureStep = BackCaptureStep.FIELD_COPY
                            field = AccessibilityNodeInfo.obtain(node)
                            backCaptureStep = BackCaptureStep.WALK
                        }
                    }
                }
                backCaptureStep = BackCaptureStep.FIELD_REQUIRED
                val password = checkNotNull(field) { "Original credential Back field unavailable" }
                backCaptureStep = BackCaptureStep.ROOT_COPY
                retainedRoot = AccessibilityNodeInfo.obtain(root)
                val lease = CredentialBackLease(session, request, retainedRoot, password,
                    run { backCaptureStep = BackCaptureStep.ROOT_CLASS; checkNotNull(root.className?.toString()) }, root.viewIdResourceName,
                    run { backCaptureStep = BackCaptureStep.FIELD_CLASS; checkNotNull(password.className?.toString()) })
                backCaptureStep = BackCaptureStep.METADATA
                check(backMetadata(lease) != null && run { backCaptureStep = BackCaptureStep.SOURCE_AFTER; backSource(lease, false) })
                backPairs = 0; backUpOmitted = false; backInputClosed = false
                backLeaseCaptured = true; backNodesReleased = false
                retainedRoot = null; field = null
                backCaptureStep = BackCaptureStep.COMPLETE
                return lease
            } finally { retainedRoot?.recycle(); field?.recycle(); root.recycle() }
        }
        /** Only properties of the retained original nodes; no parent/field reacquisition. */
        private fun backMetadata(lease: CredentialBackLease): BackGeometry? {
            val root = lease.root; val field = lease.field; val window = lease.session.window
            if (root.windowId != window || field.windowId != window || root.packageName?.toString() != SETTINGS ||
                field.packageName?.toString() != SETTINGS || root.className?.toString() != lease.rootClass ||
                root.viewIdResourceName != lease.rootId || field.className?.toString() != lease.fieldClass ||
                field.viewIdResourceName != "$SETTINGS:id/password_entry" || !root.isVisibleToUser || !root.isEnabled ||
                !field.isVisibleToUser || !field.isEnabled || !field.isPassword || !field.isEditable || !field.isFocused) return null
            val bounds = Rect().also(root::getBoundsInScreen); val password = Rect().also(field::getBoundsInScreen)
            return if (!bounds.isEmpty && !password.isEmpty && bounds.contains(password)) BackGeometry(bounds, password) else null
        }
        private fun backBudget(lease: CredentialBackLease) {
            check(backLease === lease && !lease.revoked && lease.deadline != 0L && SystemClock.elapsedRealtime() < lease.deadline) {
                "Original credential Back budget refused"
            }
        }
        private suspend fun backSource(lease: CredentialBackLease, foreground: Boolean): Boolean {
            val current = lease.request.expiresAt > System.currentTimeMillis() && port.approvalAuthenticationIdentity() == port.identity &&
                main { controller.state.value.ownerAccount == lease.request.account && controller.state.value.ownerEpoch == 0L } &&
                sourceCurrent(lease.session.source, lease.request, foreground)
            return current && lease.request.expiresAt > System.currentTimeMillis() && port.approvalAuthenticationIdentity() == port.identity
        }
        private suspend fun backReturned(lease: CredentialBackLease): Boolean {
            try {
                backBudget(lease)
                if (!backSource(lease, true) || !ownResumed()) return false
                // Seeing the original app again permanently stops further credential input,
                // even while its asynchronous result/pending notice is still settling.
                lease.inputClosed = true; backInputClosed = true
                if (lease.downPending) { backUpOmitted = true; lease.downPending = false }
                val returned = !appLabel(PENDING).present && !appLabel(CONFIRM).present
                backBudget(lease)
                val source = backSource(lease, true)
                backBudget(lease)
                return returned && source
            } catch (error: Throwable) { refuseBack(lease); throw error }
        }
        private suspend fun backCurrent(lease: CredentialBackLease): BackGeometry? {
            try {
                backBudget(lease)
                check(!lease.inputClosed)
                backStep = BackStep.SOURCE
                check(backSource(lease, false) || backSource(lease, true)) { "Original credential Back source changed" }
                // Detect a known return/foreign transition before refreshing an obsolete node.
                val before = automation.rootInActiveWindow
                if (before == null) { lease.inputClosed = true; backInputClosed = true; return null }
                try {
                    val pkg = before.packageName?.toString(); rootObserved(pkg)
                    if (pkg == own) { lease.inputClosed = true; backInputClosed = true; return null }
                    check(pkg == SETTINGS && before == lease.root) { "Original credential Back active root changed" }
                } finally { before.recycle() }
                backStep = BackStep.SOURCE; check(backSource(lease, false))
                backStep = BackStep.ROOT_REFRESH
                val rootBefore = AccessibilityNodeInfo.obtain(lease.root)
                try { check(lease.root.refresh() && lease.root == rootBefore) { "Original credential Back root expired" } }
                finally { rootBefore.recycle() }
                backStep = BackStep.FIELD_REFRESH
                val fieldBefore = AccessibilityNodeInfo.obtain(lease.field)
                try { check(lease.field.refresh() && lease.field == fieldBefore) { "Original credential Back field expired" } }
                finally { fieldBefore.recycle() }
                val geometry = checkNotNull(backMetadata(lease)) { "Original credential Back metadata changed" }
                backStep = BackStep.ACTIVE_ROOT
                val active = automation.rootInActiveWindow
                if (active == null) { lease.inputClosed = true; backInputClosed = true; return null }
                try {
                    val pkg = active.packageName?.toString(); rootObserved(pkg)
                    if (pkg == own) { lease.inputClosed = true; backInputClosed = true; return null }
                    check(pkg == SETTINGS && active == lease.root && active.windowId == lease.session.window &&
                        Rect().also(active::getBoundsInScreen) == geometry.root) { "Original credential Back active root changed" }
                } finally { active.recycle() }
                // AX refresh/root reads may be slow. This final deadline and original source
                // check is deliberately after them, immediately before returning input authority.
                backStep = BackStep.SOURCE; check(backSource(lease, false)); backBudget(lease)
                return geometry
            } catch (error: Throwable) { refuseBack(lease); throw error }
        }
        private suspend fun backPair(lease: CredentialBackLease) {
            if (!lease.downPending) {
                val first = backCurrent(lease) ?: return
                backStep = BackStep.STABLE; delay(32)
                val second = backCurrent(lease) ?: return
                if (first != second) return // Same retained nodes may resize; await a stable pair.
                check(lease.pairs < 2); lease.pairs++; backPairs = lease.pairs
                lease.downAt = SystemClock.uptimeMillis(); lease.downPending = true
                backStep = BackStep.DOWN
                try { injectKey(lease.downAt, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK) }
                catch (error: Throwable) { refuseBack(lease); throw error }
                delay(32)
            }
            if (backCurrent(lease) == null) {
                backUpOmitted = true; lease.downPending = false; return
            }
            backStep = BackStep.UP
            try { injectKey(lease.downAt, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_BACK); lease.downPending = false }
            catch (error: Throwable) { refuseBack(lease); throw error }
        }
        private fun refuseBack(lease: CredentialBackLease) {
            lease.revoked = true; lease.inputClosed = true; backInputClosed = true
            if (lease.downPending) backUpOmitted = true
            backStep = BackStep.REFUSED
        }
        private fun releaseBackLease() {
            val lease = backLease ?: return
            backLease = null
            try { lease.root.recycle() } finally { lease.field.recycle(); backNodesReleased = true }
        }
        private suspend fun key(session: SettingsSession, request: ApprovalRequest, code: Int) {
            settingsCurrent(session, request); val down = SystemClock.uptimeMillis(); injectKey(down, KeyEvent.ACTION_DOWN, code)
            settingsCurrent(session, request); injectKey(down, KeyEvent.ACTION_UP, code)
        }
        private fun injectKey(down: Long, action: Int, code: Int) {
            val event = KeyEvent(down, SystemClock.uptimeMillis(), action, code, 0, 0, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD)
            // Do not attach the original exception: framework error text can include digit keycodes.
            val accepted = try { automation.injectInputEvent(event, true) } catch (_: Exception) { false }
            check(accepted) { "Owned credential input refused" }
        }
        private suspend fun confirmation() {
            await(AwaitStep.CONFIRM) { ownResumed() && appLabel(CONFIRM).present }
            confirmationSeen = true; assertTrue(port.answers.isEmpty()); assertNull(main { controller.state.value.busy }); sample()
        }
        private suspend fun ready() {
            await(AwaitStep.READY) { main { controller.trayPresentation.frame.value.let {
                    it.phase == ApprovalTravel.READY && !it.running && controller.state.value.busy == null
                } } && ownResumed() && appLabel("Approve").hit != null && !appLabel(PENDING).present &&
                main { controller.trayPresentation.frame.value.let {
                    it.phase == ApprovalTravel.READY && !it.running && controller.state.value.busy == null
                } } }
        }
        private suspend fun tapApprove() {
            val source = checkNotNull(activity); val request = port.expected
            val before = checkNotNull(appLabel("Approve").hit) { "Unique owned approval control unavailable" }
            delay(32)
            check(appLabel("Approve").hit == before)
            tap(before, {
                check(sourceCurrent(source, request, true)); check(appLabel("Approve").hit == before)
                check(sourceCurrent(source, request, true))
            }, { sourceCurrent(source, request, true) && appLabel("Approve").hit?.let { it.window == before.window && it.root == before.root } == true &&
                sourceCurrent(source, request, true) })
        }
        private suspend fun tap(hit: Hit, current: suspend () -> Unit, cleanupCurrent: suspend () -> Boolean) {
            var pressed = false; val down = SystemClock.uptimeMillis(); var failure: Throwable? = null
            fun event(action: Int) {
                val properties = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER }
                val point = MotionEvent.PointerCoords().apply { x = hit.bounds.exactCenterX(); y = hit.bounds.exactCenterY(); pressure = 1f; size = 1f }
                val value = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 1, arrayOf(properties), arrayOf(point),
                    0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
                try { check(automation.injectInputEvent(value, true)) { "Owned credential fixture pointer refused" } }
                finally { value.recycle() }
            }
            try {
                pointerStep = PointerStep.SOURCE_BEFORE_DOWN; current()
                pointerStep = PointerStep.DOWN; event(MotionEvent.ACTION_DOWN); pressed = true
                pointerStep = PointerStep.DOWN_SENT; delay(32)
                pointerStep = PointerStep.SOURCE_BEFORE_UP; current()
                pointerStep = PointerStep.UP; event(MotionEvent.ACTION_UP); pressed = false
                pointerStep = PointerStep.COMPLETE
            }
            catch (error: Throwable) { pointerFailureStep = pointerStep; failure = error; throw error }
            finally { if (pressed) withContext(NonCancellable) { try {
                pointerStep = PointerStep.CANCEL_SOURCE
                if (cleanupCurrent()) { pointerStep = PointerStep.CANCEL; event(MotionEvent.ACTION_CANCEL); pointerStep = PointerStep.CANCELLED }
            }
                catch (error: Throwable) { val originalFailure = failure; if (originalFailure != null) originalFailure.addSuppressed(error) else throw error } } }
        }

        private data class Hit(val bounds: Rect, val root: Rect, val window: Int)
        private data class AppProjection(val present: Boolean, val hit: Hit?)
        private data class SettingsProjection(val window: Int, val root: Rect, val field: Rect, val cancel: Hit?)
        private data class SettingsSession(val source: EngineTestActivity, val window: Int, val root: Rect, val field: Rect)
        private data class BackGeometry(val root: Rect, val field: Rect)
        private class CredentialBackLease(val session: SettingsSession, val request: ApprovalRequest,
            val root: AccessibilityNodeInfo, val field: AccessibilityNodeInfo, val rootClass: String, val rootId: String?, val fieldClass: String) {
            var deadline = 0L
            var pairs = 0
            var downPending = false
            var downAt = 0L
            var inputClosed = false
            var revoked = false
        }
        private data class DialogRoot(val source: EngineTestActivity, val view: View, val token: IBinder, val window: Int, val bounds: Rect)
        private data class DialogLease(val native: DialogRoot, val accessibilityBounds: Rect)
        private data class TaggedLabel(val node: AccessibilityNodeInfo, val hit: Hit)
        private data class TaggedCandidate(val node: AccessibilityNodeInfo, val hit: Hit,
            val labels: MutableList<TaggedLabel> = mutableListOf())
        private suspend fun appLabel(label: String): AppProjection {
            require(label in setOf("Approve", CONFIRM, PENDING))
            val lease = main { dialog?.takeIf { dialogCurrent(it.native, true) } } ?: return AppProjection(false, null)
            val request = main { port.expected }
            if (label == "Approve") {
                approveObserved = true; approveTreeComplete = false; approvePresent = false; approveHit = false
                approveMatches = 0; approveVisibleMatches = 0; approveEnabledMatches = 0; approveEligibleMatches = 0; approveActionableMatches = 0
                approveExtraAdvertised = 0; approveExtraRequested = 0; approveExactTagMatches = 0; approveRefreshRefused = 0
                approveTaggedTextLabels = 0; approveLabelRefreshRequested = 0
            }
            if (label == PENDING) { pendingObserved = true; pendingPresent = false }
            val root = automation.rootInActiveWindow ?: run { rootKind = RootKind.NULL; return AppProjection(false, null) }
            val taggedCandidates = mutableListOf<TaggedCandidate>()
            try {
                val pkg = root.packageName?.toString()
                rootObserved(pkg)
                check(pkg == own || pkg == SETTINGS) { "Unexpected foreground refused" }
                if (pkg != own) return AppProjection(false, null)
                val bounds = Rect().also(root::getBoundsInScreen); val visible = mutableListOf<Hit>(); val actionable = mutableListOf<Hit>()
                check(root.windowId == lease.native.window && bounds == lease.accessibilityBounds) { "Original approval dialog AX window changed" }
                val project: (AccessibilityNodeInfo, List<TaggedCandidate>) -> TaggedCandidate? = { node, ancestors ->
                    val matches = node.text?.toString() == label || node.contentDescription?.toString() == label
                    if (label == "Approve" && matches) {
                        approveMatches++
                        if (node.isVisibleToUser) approveVisibleMatches++
                        if (node.isVisibleToUser && node.isEnabled) approveEnabledMatches++
                    }
                    var candidate: TaggedCandidate? = null
                    if (node.isVisibleToUser && node.isEnabled) {
                        val rect = Rect().also(node::getBoundsInScreen)
                        if (!rect.isEmpty && bounds.contains(rect) && lease.native.bounds.contains(rect)) {
                            val hit = Hit(rect, Rect(bounds), root.windowId)
                            val click = node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK }
                            if (matches) {
                                visible += hit
                                if (node.isClickable || click) actionable += hit
                                if (label == "Approve") { approveEligibleMatches = visible.size; approveActionableMatches = actionable.size }
                            }
                            if (label == "Approve" && node.className?.toString() == "android.widget.TextView" &&
                                node.text?.toString() == "Approve" && !node.isClickable && !click) {
                                for (ancestor in ancestors) if (ancestor.hit.bounds.contains(rect)) {
                                    check(taggedCandidates.size + approveTaggedTextLabels < 4) { "Owned approval label bound refused" }
                                    ancestor.labels += TaggedLabel(AccessibilityNodeInfo.obtain(node), hit)
                                    approveTaggedTextLabels++
                                }
                            }
                            // A merging clickable's description can live on a fake child. Identify
                            // the real control by its advertised tag first, not a child's label.
                            if (label == "Approve" && node.isClickable && click && TEST_TAG_KEY in node.availableExtraData) {
                                check(taggedCandidates.size + approveTaggedTextLabels < 4) { "Owned approval tag request bound refused" }
                                val retained = TaggedCandidate(AccessibilityNodeInfo.obtain(node), hit)
                                taggedCandidates += retained; candidate = retained
                                approveExtraAdvertised = taggedCandidates.size
                            }
                        }
                    }
                    candidate
                }
                if (label == "Approve") walkApproval(root, own, root.windowId, project)
                else walk(root, own, root.windowId) { node -> project(node, emptyList()) }
                check(main { dialog === lease && dialogCurrent(lease.native, true) }) { "Original approval dialog changed" }
                if (label == "Approve") { approveTreeComplete = true; approvePresent = visible.isNotEmpty() }
                val hit = if (label == "Approve") taggedApproveHit(lease, request, taggedCandidates)
                    else actionable.singleOrNull() ?: visible.singleOrNull()
                val result = AppProjection(visible.isNotEmpty(), hit)
                if (label == "Approve") { approveTreeComplete = true; approvePresent = result.present; approveHit = result.hit != null }
                if (label == PENDING) pendingPresent = result.present
                return result
            } finally { taggedCandidates.forEach { candidate ->
                candidate.labels.forEach { it.node.recycle() }; candidate.node.recycle()
            }; root.recycle() }
        }
        /** Original complete provenance walk, with bounded RAM ancestry only; no parent query. */
        private fun walkApproval(root: AccessibilityNodeInfo, pkg: String, window: Int,
            body: (AccessibilityNodeInfo, List<TaggedCandidate>) -> TaggedCandidate?) {
            var count = 0
            fun visit(node: AccessibilityNodeInfo, ancestors: List<TaggedCandidate>) {
                val children = node.childCount
                check(++count <= 512 && children <= 128) { "Owned credential tree bound refused" }
                check(node.packageName?.toString() == pkg && node.windowId == window) { "Owned credential tree identity refused" }
                val candidate = body(node, ancestors)
                val path = if (candidate == null) ancestors else ancestors + candidate
                for (i in 0 until children) {
                    val child = checkNotNull(node.getChild(i)) { "Incomplete owned credential tree" }
                    try { visit(child, path) } finally { child.recycle() }
                }
            }
            visit(root, emptyList())
        }
        private fun taggedCandidateCurrent(value: TaggedCandidate, lease: DialogLease): Boolean {
            val node = value.node; val bounds = Rect().also(node::getBoundsInScreen)
            return node.packageName?.toString() == own && node.windowId == lease.native.window &&
                node.isClickable && node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK } &&
                node.isVisibleToUser && node.isEnabled && !bounds.isEmpty && bounds == value.hit.bounds &&
                value.hit.window == lease.native.window && value.hit.root == lease.accessibilityBounds &&
                lease.accessibilityBounds.contains(bounds) && lease.native.bounds.contains(bounds) &&
                TEST_TAG_KEY in node.availableExtraData
        }
        private fun taggedLabelCurrent(value: TaggedLabel, candidate: TaggedCandidate, lease: DialogLease): Boolean {
            val node = value.node; val bounds = Rect().also(node::getBoundsInScreen)
            return node.packageName?.toString() == own && node.windowId == lease.native.window &&
                node.className?.toString() == "android.widget.TextView" && node.text?.toString() == "Approve" &&
                !node.isClickable && node.actionList.none { it.id == AccessibilityNodeInfo.ACTION_CLICK } &&
                node.isVisibleToUser && node.isEnabled && !bounds.isEmpty && bounds == value.hit.bounds &&
                value.hit.window == lease.native.window && value.hit.root == lease.accessibilityBounds &&
                candidate.hit.bounds.contains(bounds) && lease.accessibilityBounds.contains(bounds) && lease.native.bounds.contains(bounds)
        }
        /** Extra data is an explicit read, after the complete original walk. Never act on it. */
        private suspend fun taggedApproveHit(lease: DialogLease, request: ApprovalRequest, candidates: List<TaggedCandidate>): Hit? {
            val hits = mutableListOf<Hit>()
            for (candidate in candidates) {
                // Independent unrecycled snapshot: public equals compares source-node and window
                // identity even when refresh replaces the other node's cached properties.
                val original = AccessibilityNodeInfo.obtain(candidate.node)
                try {
                    check(original !== candidate.node)
                    check(sourceCurrent(lease.native.source, request, true) && main { dialog === lease }) { "Original approval source changed" }
                    check(taggedCandidateCurrent(candidate, lease)) { "Original approval tag candidate changed" }
                    approveExtraRequested++
                    val refreshed = try { candidate.node.refreshWithExtraData(TEST_TAG_KEY, Bundle()) } catch (_: Exception) { false }
                    check(sourceCurrent(lease.native.source, request, true) && main { dialog === lease }) { "Original approval source changed" }
                    if (!refreshed) { approveRefreshRefused++; return null }
                    check(candidate.node == original && taggedCandidateCurrent(candidate, lease)) { "Original approval tag candidate changed" }
                    val exactTag = try {
                        val tag = candidate.node.extras.getCharSequence(TEST_TAG_KEY)
                        tag?.length == APPROVE_TAG.length && tag.toString() == APPROVE_TAG
                    } catch (_: Exception) { false }
                    if (exactTag) {
                        approveExactTagMatches++
                        val label = candidate.labels.singleOrNull()
                        if (label != null) {
                            val originalLabel = AccessibilityNodeInfo.obtain(label.node)
                            try {
                                check(originalLabel !== label.node)
                                check(sourceCurrent(lease.native.source, request, true) && main { dialog === lease }) { "Original approval source changed" }
                                check(candidate.node == original && taggedCandidateCurrent(candidate, lease) && taggedLabelCurrent(label, candidate, lease)) { "Original approval label changed" }
                                approveLabelRefreshRequested++
                                val refreshedLabel = try { label.node.refresh() } catch (_: Exception) { false }
                                check(sourceCurrent(lease.native.source, request, true) && main { dialog === lease }) { "Original approval source changed" }
                                if (!refreshedLabel) { approveRefreshRefused++; return null }
                                check(candidate.node == original && label.node == originalLabel &&
                                    taggedCandidateCurrent(candidate, lease) && taggedLabelCurrent(label, candidate, lease)) { "Original approval label changed" }
                                hits += label.hit
                            } finally { originalLabel.recycle() }
                        }
                    }
                } finally { original.recycle() }
            }
            return hits.singleOrNull().takeIf { approveExactTagMatches == 1 }
        }
        private fun settings(): SettingsProjection? {
            settingsObserved = true; settingsTreeComplete = false
            settingsPasswordNodes = 0; settingsPasswordEligible = 0; settingsCancelNodes = 0; settingsCancelEligible = 0
            settingsAlternateCancelNodes = 0; settingsAlternateCancelVisibleEnabled = 0
            val root = automation.rootInActiveWindow ?: run { rootKind = RootKind.NULL; return null }
            try {
                val pkg = root.packageName?.toString()
                rootObserved(pkg)
                check(pkg == SETTINGS || pkg == own) { "Unexpected foreground refused" }
                if (pkg != SETTINGS) return null
                val bounds = Rect().also(root::getBoundsInScreen); val fields = mutableListOf<Rect>(); val cancels = mutableListOf<Hit>()
                walk(root, SETTINGS, root.windowId) { node ->
                    // Fixed counters only; alternate ID observation never participates in admission.
                    when (node.viewIdResourceName) {
                        "$SETTINGS:id/password_entry" -> settingsPasswordNodes++
                        "$SETTINGS:id/cancelButton" -> settingsCancelNodes++
                        "$SETTINGS:id/cancel_button" -> {
                            settingsAlternateCancelNodes++
                            if (node.isVisibleToUser && node.isEnabled) settingsAlternateCancelVisibleEnabled++
                        }
                    }
                    if (node.isVisibleToUser && node.isEnabled) {
                        val rect = Rect().also(node::getBoundsInScreen)
                        if (!rect.isEmpty && bounds.contains(rect)) {
                            if (node.viewIdResourceName == "$SETTINGS:id/password_entry" && node.isPassword && node.isEditable && node.isFocused) fields += rect
                            if (node.viewIdResourceName == "$SETTINGS:id/cancelButton") cancels += Hit(rect, Rect(bounds), root.windowId)
                        }
                    }
                }
                settingsTreeComplete = true
                settingsPasswordEligible = fields.size.coerceIn(0, 512); settingsCancelEligible = cancels.size.coerceIn(0, 512)
                return fields.singleOrNull()?.let { SettingsProjection(root.windowId, Rect(bounds), it, cancels.singleOrNull()) }
            } finally { root.recycle() }
        }
        private fun walk(root: AccessibilityNodeInfo, pkg: String, window: Int, body: (AccessibilityNodeInfo) -> Unit) {
            var count = 0
            fun visit(node: AccessibilityNodeInfo) {
                val children = node.childCount
                check(++count <= 512 && children <= 128) { "Owned credential tree bound refused" }
                check(node.packageName?.toString() == pkg && node.windowId == window) { "Owned credential tree identity refused" }
                body(node)
                for (i in 0 until children) {
                    val child = checkNotNull(node.getChild(i)) { "Incomplete owned credential tree" }
                    try { visit(child) } finally { child.recycle() }
                }
            }
            visit(root)
        }
        private suspend fun settingsCurrent(session: SettingsSession, request: ApprovalRequest) { check(settingsAdmitted(session, request)) { "Original credential window changed" } }
        private suspend fun settingsAdmitted(session: SettingsSession, request: ApprovalRequest): Boolean =
            sourceCurrent(session.source, request, false) && settingsMatches(session) && sourceCurrent(session.source, request, false)
        private fun settingsMatches(session: SettingsSession): Boolean = settings()?.let {
            it.window == session.window && it.root == session.root && it.field == session.field
        } == true
        private suspend fun sourceCurrent(source: EngineTestActivity, request: ApprovalRequest, foreground: Boolean): Boolean = main {
            activity === source && !source.isDestroyed && port.expected === request && controller.state.value.requests.any { it === request } &&
                port.answers.isEmpty() && dialog?.let { it.native.source === source && dialogCurrent(it.native, foreground) } == true &&
                if (foreground) source.lifecycle.currentState == Lifecycle.State.RESUMED else source.lifecycle.currentState != Lifecycle.State.RESUMED
        }
        private fun contextOwns(source: EngineTestActivity, original: Context): Boolean {
            var current = original
            repeat(8) {
                if (current === source) return true
                val next = (current as? ContextWrapper)?.baseContext ?: return false
                if (next === current) return false
                current = next
            }
            return false
        }
        private fun nativeBounds(view: View): Rect {
            val point = IntArray(2); view.getLocationOnScreen(point)
            return Rect(point[0], point[1], point[0] + view.width, point[1] + view.height)
        }
        /** Main only. Neither package names nor a replacement focused root can renew this lease. */
        private fun dialogCurrent(value: DialogRoot, foreground: Boolean): Boolean {
            if (dialogRevoked) return false
            val view = value.view
            val structural = activity === value.source && !value.source.isDestroyed && view !== value.source.window.decorView &&
                view.rootView === view && view.isAttachedToWindow && view.isShown && view.windowToken === value.token &&
                contextOwns(value.source, view.context) && (view.layoutParams as? WindowManager.LayoutParams)?.type == WindowManager.LayoutParams.TYPE_APPLICATION &&
                nativeBounds(view) == value.bounds
            if (!structural) { dialogRevoked = true; dialogState = DialogState.REVOKED; return false }
            if (foreground && !view.hasWindowFocus()) { dialogState = DialogState.FOCUS_WAIT; return false }
            dialogState = DialogState.BOUND
            return true
        }
        /** Main only. Initial acquisition is permitted until one exact AX-backed lease is bound. */
        private fun candidate(source: EngineTestActivity): DialogRoot? {
            check(dialog == null && !dialogRevoked)
            val roots = WindowInspector.getGlobalWindowViews()
            processRootCount = roots.size.coerceAtMost(9)
            if (roots.size > 8) { dialogState = DialogState.ROOT_CAP_REFUSED; error("Owned dialog root bound refused") }
            val matches = roots.filter { view -> view !== source.window.decorView && view.rootView === view &&
                contextOwns(source, view.context) && (view.layoutParams as? WindowManager.LayoutParams)?.type == WindowManager.LayoutParams.TYPE_APPLICATION &&
                view.isAttachedToWindow && view.isShown && view.hasWindowFocus() && view.windowToken != null }
            dialogCandidateCount = matches.size.coerceAtMost(9)
            if (matches.isEmpty()) { dialogState = DialogState.WAITING; return null }
            if (matches.size != 1) { dialogState = DialogState.AMBIGUOUS; error("Unique owned dialog unavailable") }
            val view = matches.single(); val bounds = nativeBounds(view)
            if (bounds.isEmpty) { dialogState = DialogState.WAITING; return null }
            val node = view.createAccessibilityNodeInfo()
            val window = try { node?.windowId ?: -1 } finally { node?.recycle() }
            if (window < 0) { dialogState = DialogState.AX_PENDING; return null }
            return DialogRoot(source, view, checkNotNull(view.windowToken), window, bounds)
        }
        private suspend fun ownResumed(): Boolean {
            val observed = main {
                val source = activity
                if (source == null || source.isDestroyed || source.lifecycle.currentState != Lifecycle.State.RESUMED || dialogRevoked) null
                else dialog?.native?.takeIf { dialogCurrent(it, true) } ?: if (dialog == null) candidate(source) else null
            } ?: return false
            val root = automation.rootInActiveWindow ?: run { rootKind = RootKind.NULL; return false }
            try {
                val pkg = root.packageName?.toString(); rootObserved(pkg)
                check(pkg == own || pkg == SETTINGS) { "Unexpected foreground refused" }
                if (pkg != own) return false
                val bounds = Rect().also(root::getBoundsInScreen)
                if (root.windowId != observed.window || bounds.isEmpty) {
                    // Initial AX delivery may lag the already focused native Dialog. Wait only
                    // before binding, without granting input or admitting another own window.
                    if (main { dialog == null }) { dialogState = DialogState.AX_PENDING; return false }
                    dialogState = DialogState.AX_REFUSED; error("Owned dialog AX provenance refused")
                }
                return main {
                    if (!dialogCurrent(observed, true) || observed.source.lifecycle.currentState != Lifecycle.State.RESUMED) false
                    else {
                        val current = dialog
                        if (current == null) {
                            dialog = DialogLease(observed, Rect(bounds)); dialogCaptureCount++
                        } else check(current.native === observed && current.accessibilityBounds == bounds) { "Original dialog AX bounds changed" }
                        true
                    }
                }
            } finally { root.recycle() }
        }
        private fun checkKnownTransition() {
            val root = automation.rootInActiveWindow ?: run { rootKind = RootKind.NULL; return }
            try { val pkg = root.packageName?.toString(); rootObserved(pkg); check(pkg in setOf(own, SETTINGS)) { "Unexpected credential terminal transition" } }
            finally { root.recycle() }
        }
        private suspend fun sample() {
            check(rows.length() < 16)
            rows.put(JSONObject().put("phase", phase).put("stops", stops.get().coerceAtMost(99)).put("resumes", resumes.get().coerceAtMost(99))
                .put("destroys", destroys.get().coerceAtMost(99)).put("answers", port.answers.size.coerceAtMost(2))
                .put("busy", main { controller.state.value.busy != null }).put("confirmationSeen", confirmationSeen))
        }
        /** Fixed app-only failure evidence. No new accessibility query or admission decision. */
        suspend fun captureFailure(cleanup: Boolean = false) {
            if (failureProjection != null) return
            if (failureCode == FailureCode.NONE) failureCode = if (cleanup) FailureCode.CLEANUP else if (phase != "SETUP") FailureCode.FUNCTIONAL_CHECK else when (setup) {
                SetupStep.SECURE -> FailureCode.SECURE_CHECK; SetupStep.BIOMETRIC -> FailureCode.BIOMETRIC_CHECK
                SetupStep.LAUNCH -> FailureCode.ACTIVITY_LAUNCH; SetupStep.BIND -> FailureCode.ACTIVITY_BIND
                SetupStep.PUBLISH -> FailureCode.REQUEST_PUBLICATION; SetupStep.READY -> FailureCode.READY_CHECK
                SetupStep.NONE -> FailureCode.FUNCTIONAL_CHECK
            }
            var app: JSONObject? = null
            try { withTimeout(2_000) { app = main {
                val source = activity; val state = controller.state.value; val frame = controller.trayPresentation.frame.value
                val manager = context.getSystemService(KeyguardManager::class.java)
                JSONObject().put("observed", true).put("activityPresent", source != null)
                    .put("activityNotDestroyed", source?.isDestroyed == false)
                    .put("activityResumed", source?.lifecycle?.currentState == Lifecycle.State.RESUMED)
                    .put("activityHasFocus", source?.hasWindowFocus() == true)
                    .put("expectedRequestPresent", state.requests.any { it === port.expected })
                    .put("accountCurrent", state.ownerAccount == port.expected.account).put("epochCurrent", state.ownerEpoch == 0L)
                    .put("busy", state.busy != null).put("errorPresent", state.error != null)
                    .put("trayEntering", frame.phase == ApprovalTravel.ENTERING).put("trayReady", frame.phase == ApprovalTravel.READY)
                    .put("trayInteractive", frame.interactive).put("trayExpectedRequest", frame.content?.request === port.expected)
                    .put("deviceLocked", manager.isDeviceLocked).put("keyguardLocked", manager.isKeyguardLocked)
            } } } catch (_: Throwable) { app = null /* Diagnostic failure never bypasses original cleanup or replaces the error. */ }
            failureProjection = diagnostic().put("app", app ?: JSONObject().put("observed", false)).put("appProjectionCaptured", app != null)
        }
        private fun diagnostic(): JSONObject = JSONObject().put("diagnosticOnly", true).put("setupStep", setup.name).put("setupSteps", setupSteps)
            .put("secureObserved", secureObserved).put("deviceSecure", secure).put("biometricObserved", biometricObserved)
            .put("weakBiometricUnavailable", weakBiometricUnavailable).put("awaitStep", lastAwait.name)
            .put("awaitAttempts", awaitAttempts.coerceIn(0, 255)).put("awaitActive", awaitActive).put("failureCode", failureCode.name)
            .put("lastRootKind", rootKind.name).put("approveObserved", approveObserved).put("approveTreeComplete", approveTreeComplete)
            .put("approvePresent", approvePresent).put("approveHit", approveHit).put("pendingObserved", pendingObserved).put("pendingPresent", pendingPresent)
            .put("approveMatches", approveMatches.coerceIn(0, 512)).put("approveVisibleMatches", approveVisibleMatches.coerceIn(0, 512))
            .put("approveEnabledMatches", approveEnabledMatches.coerceIn(0, 512)).put("approveEligibleMatches", approveEligibleMatches.coerceIn(0, 512))
            .put("approveActionableMatches", approveActionableMatches.coerceIn(0, 512))
            .put("approveExtraAdvertised", approveExtraAdvertised.coerceIn(0, 4)).put("approveExtraRequested", approveExtraRequested.coerceIn(0, 4))
            .put("approveExactTagMatches", approveExactTagMatches.coerceIn(0, 4)).put("approveRefreshRefused", approveRefreshRefused.coerceIn(0, 4))
            .put("approveTaggedTextLabels", approveTaggedTextLabels.coerceIn(0, 4)).put("approveLabelRefreshRequested", approveLabelRefreshRequested.coerceIn(0, 4))
            .put("dialogState", dialogState.name).put("dialogCaptured", dialogCaptureCount > 0).put("dialogRevoked", dialogRevoked)
            .put("processRootCount", processRootCount.coerceIn(0, 9)).put("dialogCandidateCount", dialogCandidateCount.coerceIn(0, 9))
            .put("dialogCaptureCount", dialogCaptureCount.coerceIn(0, 2))
            .put("cancelStep", cancelStep.name).put("pointerStep", pointerStep.name).put("pointerFailureStep", pointerFailureStep.name)
            .put("settingsObserved", settingsObserved).put("settingsTreeComplete", settingsTreeComplete)
            .put("settingsPasswordNodes", settingsPasswordNodes.coerceIn(0, 512)).put("settingsPasswordEligible", settingsPasswordEligible.coerceIn(0, 512))
            .put("settingsCancelNodes", settingsCancelNodes.coerceIn(0, 512)).put("settingsCancelEligible", settingsCancelEligible.coerceIn(0, 512))
            .put("settingsAlternateCancelNodes", settingsAlternateCancelNodes.coerceIn(0, 512))
            .put("settingsAlternateCancelVisibleEnabled", settingsAlternateCancelVisibleEnabled.coerceIn(0, 512))
            .put("backStep", backStep.name).put("backCaptureStep", backCaptureStep.name)
            .put("backPairs", backPairs.coerceIn(0, 2)).put("backUpOmitted", backUpOmitted)
            .put("backInputClosed", backInputClosed).put("backLeaseCaptured", backLeaseCaptured).put("backNodesReleased", backNodesReleased)
        suspend fun close() {
            var failure: Throwable? = null
            try { credential?.let { cancelPin() } }
            catch (error: Throwable) { failure = error }
            try { scenario?.close() }
            catch (error: Throwable) { val first = failure; if (first == null) failure = error else first.addSuppressed(error) }
            finally {
                scenario = null; dialog = null
                try { releaseBackLease() }
                catch (error: Throwable) { val first = failure; if (first == null) failure = error else first.addSuppressed(error) }
            }
            cleanupConfirmed = failure == null
            failure?.let { throw it }
        }
        fun save(passed: Boolean) {
            val parent = File(checkNotNull(context.getExternalFilesDir(null)), "instrumentation")
            check(parent.isDirectory || parent.mkdirs())
            val value = JSONObject().put("schema", 1).put("nonce", nonce).put("passed", passed).put("phase", phase)
                .put("api29", Build.VERSION.SDK_INT == 29).put("productionPrompt", true).put("realKeyguardResult", confirmationSeen)
                .put("realCancel", cancelConfirmed).put("lateReplacementRefused", replacementConfirmed).put("readyRecreationRefused", recreationConfirmed)
                .put("answersBeforeSecondTap", beforeSecondTap).put("answers", port.answers.size.coerceAtMost(2))
                .put("enterUpOmittedAfterOwnedTransition", enterUpOmitted).put("cleanupConfirmed", cleanupConfirmed)
                .put("secretInputRemovedBeforeEntry", true).put("screenshotsTaken", false).put("originalTicketReferenceObserved", false)
                .put("actualBridgeCasAccepted", false).put("providerAccepted", false).put("hardwareBiometricAccepted", false).put("rows", rows)
                .put("diagnostics", failureProjection ?: diagnostic())
            val text = value.toString(); check(text.toByteArray().size <= 16_384)
            File(parent, "approval-api29-credential.json").writeText(text)
        }
        private suspend fun await(step: AwaitStep, condition: suspend () -> Boolean) {
            lastAwait = step; awaitAttempts = 0; awaitActive = true
            val deadline = SystemClock.elapsedRealtime() + 25_000
            while (SystemClock.elapsedRealtime() < deadline) {
                awaitAttempts = (awaitAttempts + 1).coerceAtMost(255)
                val ready = try { condition() } catch (error: Throwable) {
                    if (failureCode == FailureCode.NONE) failureCode = FailureCode.AWAIT_CONDITION
                    throw error
                }
                if (ready) { awaitActive = false; return }; delay(100)
            }
            if (failureCode == FailureCode.NONE) failureCode = FailureCode.AWAIT_TIMEOUT
            error("Timed out: ${step.reason}")
        }
        private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
        companion object {
            private const val TEST_TAG_KEY = "androidx.compose.ui.semantics.testTag"
            private const val APPROVE_TAG = "approval.yes"
            private const val SETTINGS = "com.android.settings"
            private const val CONFIRM = "PIN verified. Tap the approval button again to continue."
            private const val PENDING = "Complete device verification, then return to Yab."
        }
    }
}
