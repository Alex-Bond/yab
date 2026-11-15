package dev.yab.browser.engine

import android.content.Context
import android.util.AttributeSet
import android.view.InputDevice
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityManager
import dev.yab.browser.model.HistorySwipeDirection
import kotlin.math.abs
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoView
import org.mozilla.geckoview.PanZoomController

internal interface HistorySwipeConsumer {
    fun current(): Boolean
    fun begin(direction: HistorySwipeDirection, width: Float): Boolean
    fun move(distance: Float)
    fun end(distance: Float, velocity: Float, cancelled: Boolean)
}

internal enum class HistoryInputStage { DOWN_NATIVE, DOWN_APZ, APZ_CALLBACK, PAGE_CALLBACK, CLAIM_GATE, CLAIM, MOVE_NATIVE, MOVE_HELD, UP, CANCEL, DETACH }
internal enum class HistoryClaimGate { NO_TICKET, PAGE_POLICY_REFUSED, CONSUMER_REFUSED, READY, HANDOFF_REFUSED }
internal data class HistoryInputObservation(val stage: HistoryInputStage, val ticketCurrent: Boolean,
    val sessionCurrent: Boolean, val attached: Boolean, val focused: Boolean, val claimed: Boolean, val nativeCancelled: Boolean,
    val claimGate: HistoryClaimGate? = null, val pagePhase: HistoryTouchPhase? = null,
    val pageAccepted: Boolean? = null, val pageHeld: Boolean? = null, val pageContacts: Int? = null,
    val pageTicketMatches: Boolean? = null)

/** Original DOWN goes to APZ ONCE. A missing PREARMED/page/native ACK leaves the entire stream native. */
internal class HistorySwipeView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : GeckoView(context, attrs) {
    init {
        // Programmatic GeckoView has no app resource id or native autofill hints.
        // Android's AUTO heuristic otherwise skips its entire virtual HTML tree.
        importantForAutofill = android.view.View.IMPORTANT_FOR_AUTOFILL_YES
    }
    private var autofillBinding: Any? = null
    private var captureAutofill: (() -> (() -> Boolean)?)? = null
    private var providedAutofill: (() -> Boolean)? = null

    fun bindAutofill(owner: Any?, capture: (() -> (() -> Boolean)?)?) {
        if (autofillBinding !== owner) providedAutofill = null
        autofillBinding = owner; captureAutofill = capture
    }

    fun revokeAutofill(cancelFramework: Boolean = false) {
        providedAutofill = null
        if (cancelFramework) context.getSystemService(android.view.autofill.AutofillManager::class.java)?.cancel()
    }

    override fun onProvideAutofillVirtualStructure(structure: android.view.ViewStructure, flags: Int) {
        val original = captureAutofill?.invoke()
        providedAutofill = original
        if (original == null || !original()) return
        super.onProvideAutofillVirtualStructure(structure, flags)
        if (!original()) providedAutofill = null
    }

    override fun autofill(values: android.util.SparseArray<android.view.autofill.AutofillValue>) {
        // Framework delivery can beat Compose's removal of a just-locked view.
        // Only the exact document and lifetime that supplied its HTML structure
        // can receive the native values; unlocking never revives an old receipt.
        if (providedAutofill?.invoke() != true) return
        super.autofill(values)
    }
    private val screenOrigin = IntArray(2)
    private var reportedOrigin: List<Int>? = null
    private val originMatrix = android.graphics.Matrix()
    private val clientOrigin = FloatArray(2)
    private var reportedSession: GeckoSession? = null
    private val originObserver = android.view.ViewTreeObserver.OnPreDrawListener {
        publishViewportOrigin(); true
    }

    /** Compose can position AndroidView without a transparent-region traversal.
     * GeckoView 158 publishes its native screen origin in that traversal. Keep it
     * current before drawing, so accessibility/autofill rectangles use screen pixels. */
    private fun publishViewportOrigin() {
        val original = session ?: return
        if (!isAttachedToWindow || width <= 0 || height <= 0) return
        getLocationOnScreen(screenOrigin)
        val current = listOf(screenOrigin[0], screenOrigin[1], width, height)
        fun nativeOriginMatches(): Boolean {
            original.getClientToScreenMatrix(originMatrix)
            clientOrigin[0] = 0f; clientOrigin[1] = 0f; originMatrix.mapPoints(clientOrigin)
            return abs(clientOrigin[0] - screenOrigin[0]) < 1f && abs(clientOrigin[1] - screenOrigin[1]) < 1f
        }
        if (reportedSession === original && reportedOrigin == current && nativeOriginMatches()) return
        super.gatherTransparentRegion(android.graphics.Region())
        // A surface can still be acquiring its display during the first pre-draw.
        // Do not cache an origin Gecko has not accepted, or one reset after a kill.
        if (nativeOriginMatches()) { reportedSession = original; reportedOrigin = current }
    }

    private val policy = HistorySwipePolicy().apply { newDocument() }
    private var channel: HistoryTouchChannel? = null
    private var consumer: HistorySwipeConsumer? = null
    private var observation: AutoCloseable? = null
    private var activeConsumer: HistorySwipeConsumer? = null
    private var ticket: HistoryDownTicket? = null
    private var inputSession: GeckoSession? = null
    private var tracker: VelocityTracker? = null
    private var tracking = false
    private var claimed = false
    private var nativeCancelled = false
    private var abandoned = false
    private var startX = 0f
    private var startY = 0f
    private var distance = 0f
    private var direction: HistorySwipeDirection? = null
    private var blockedArmSequence: Long? = null
    private val scale get() = resources.displayMetrics.density
    private val exploration get() = context.getSystemService(AccessibilityManager::class.java)?.isTouchExplorationEnabled != false
    val historyGestureReady get() = policy.prearmed && current()
    var historyLastApz: HistoryApzResult? = null; private set
    /** Opt-in fixed enums/booleans for owned native fixtures. Default production does not collect input. */
    var historyInputObserver: ((HistoryInputObservation) -> Unit)? = null
    private fun observe(stage: HistoryInputStage, ticketCurrent: Boolean = ticket != null,
        sessionCurrent: Boolean = inputSession === session, claimGate: HistoryClaimGate? = null,
        page: HistoryTouchReceipt? = null) {
        val receive = historyInputObserver ?: return
        receive(HistoryInputObservation(stage, ticketCurrent, sessionCurrent, isAttachedToWindow,
            hasWindowFocus(), claimed, nativeCancelled, claimGate, page?.phase, page?.accepted,
            page?.held, page?.contacts, page?.let { value -> ticket?.let {
                value.sequence == it.expectedDomSequence && value.serial == it.arm.serial && value.token == it.arm.token
            } == true }))
    }

    fun bindHistory(next: HistoryTouchChannel?, target: HistorySwipeConsumer?) {
        if (next?.identity !== channel?.identity) {
            policy.pendingSerial?.let { channel?.disarm(it) }
            cancelPresentation(); policy.invalidate(); observation?.close(); observation = null; channel = next
            observation = next?.observe { receipt ->
                if (channel !== next || !next.current()) return@observe
                policy.receive(receipt)
                observe(HistoryInputStage.PAGE_CALLBACK, page = receipt)
                if (receipt.phase == HistoryTouchPhase.ARMED && !receipt.accepted) {
                    blockedArmSequence = receipt.sequence
                    next.sync()
                }
                arm()
            }
            next?.sync()
        }
        consumer = target
        configure(current())
        arm()
    }

    /** Native PageStart, before any input to the replacement document. Never call this on port bind. */
    fun historyDocumentStarted() {
        cancelPresentation(); observation?.close(); observation = null; channel = null
        policy.newDocument(inputInFlight = tracking); blockedArmSequence = null
    }

    private fun current() = isAttachedToWindow && isShown && hasWindowFocus() && session != null && !exploration &&
        channel?.interactive() == true && consumer?.current() == true
    private fun arm() {
        configure(current())
        val value = policy.requestArm() ?: return
        if (value.afterSequence == blockedArmSequence || channel?.arm(value) != true) policy.armRefused(value)
    }
    private fun configure(allowed: Boolean) {
        if (!allowed) policy.pendingSerial?.let { channel?.disarm(it) }
        policy.configure(allowed)
    }
    private fun cancelPresentation() {
        if (claimed && !abandoned) activeConsumer?.end(distance, 0f, true)
        if (tracking) abandoned = true
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val action = event.actionMasked
        if (action == MotionEvent.ACTION_DOWN) {
            // Parent/framework cancellation cannot be interpreted as a successful release.
            if (tracking) { activeConsumer?.end(distance, 0f, true); finish() }
            tracking = true; claimed = false; nativeCancelled = false; abandoned = false
            historyLastApz = null
            startX = event.x; startY = event.y; distance = 0f; direction = null
            inputSession = session; activeConsumer = consumer
            tracker = VelocityTracker.obtain().also { it.addMovement(event) }
            val finger = event.isFromSource(InputDevice.SOURCE_TOUCHSCREEN) && event.pointerCount == 1 &&
                event.getToolType(0) == MotionEvent.TOOL_TYPE_FINGER
            configure(finger && current())
            ticket = policy.down()
            observe(if (ticket == null) HistoryInputStage.DOWN_NATIVE else HistoryInputStage.DOWN_APZ)
            val downTicket = ticket ?: return super.onTouchEvent(event)
            val downSession = inputSession
            val callbackHandler = handler
            fun deliver(result: PanZoomController.InputResultDetail?) {
                // GeckoResult accepts an any-thread callback. The original View handler
                // owns every policy/View/consumer access, including the refusal path.
                callbackHandler?.post {
                    observe(HistoryInputStage.APZ_CALLBACK, ticket === downTicket, inputSession === downSession && session === downSession)
                    if (ticket === downTicket && tracking && !abandoned && inputSession === downSession &&
                        session === downSession && handler === callbackHandler && current()) {
                        val projected = project(result); historyLastApz = projected; policy.apz(downTicket, projected)
                    }
                }
            }
            // This API already dispatches the DOWN. Never call super for it again.
            try {
                onTouchEventForDetailResult(event).accept({ result -> deliver(result) }, { deliver(null) })
            } catch (_: RuntimeException) {
                deliver(null)
            }
            return true
        }
        if (!tracking) return super.onTouchEvent(event)
        tracker?.addMovement(event)
        if (event.pointerCount != 1 || action == MotionEvent.ACTION_POINTER_DOWN || action == MotionEvent.ACTION_POINTER_UP) {
            policy.multipleContacts(); cancelPresentation()
        }
        distance = (event.x - startX) / scale
        if (inputSession !== session || !current()) { configure(false); cancelPresentation() }
        if (action == MotionEvent.ACTION_MOVE && !abandoned && !claimed) {
            val dx = event.x - startX; val dy = event.y - startY
            // Functional Android recognition only; UIKit's undocumented history physics remains unverified.
            if (abs(dx) > ViewConfiguration.get(context).scaledTouchSlop && abs(dx) > abs(dy) * 1.7f) {
                val route = if (dx > 0) HistorySwipeDirection.BACK else HistorySwipeDirection.FORWARD
                val value = ticket
                val permitted = value != null && policy.mayClaim(value, route)
                val began = permitted && activeConsumer?.begin(route, width / scale) == true
                observe(HistoryInputStage.CLAIM_GATE, claimGate = when {
                    value == null -> HistoryClaimGate.NO_TICKET
                    !permitted -> HistoryClaimGate.PAGE_POLICY_REFUSED
                    !began -> HistoryClaimGate.CONSUMER_REFUSED
                    else -> HistoryClaimGate.READY
                })
                if (value != null && began) {
                    if (policy.handoff(value)) {
                        direction = route; claimed = true
                        val cancel = MotionEvent.obtain(event).apply { this.action = MotionEvent.ACTION_CANCEL }
                        try { super.onTouchEvent(cancel); nativeCancelled = true } finally { cancel.recycle() }
                        observe(HistoryInputStage.CLAIM)
                        parent?.requestDisallowInterceptTouchEvent(true)
                    } else {
                        observe(HistoryInputStage.CLAIM_GATE, claimGate = HistoryClaimGate.HANDOFF_REFUSED)
                        activeConsumer?.end(distance, 0f, true)
                    }
                }
            }
        }
        if (action == MotionEvent.ACTION_MOVE) observe(if (claimed && !abandoned) HistoryInputStage.MOVE_HELD else HistoryInputStage.MOVE_NATIVE)
        if (claimed && !abandoned && action == MotionEvent.ACTION_MOVE) activeConsumer?.move(distance)
        if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
            observe(if (action == MotionEvent.ACTION_UP) HistoryInputStage.UP else HistoryInputStage.CANCEL)
            val accepted = policy.up(ticket, direction, cancelled = action == MotionEvent.ACTION_CANCEL)
            tracking = false // A synchronous accepted navigation sees the physical stream already ended.
            tracker?.computeCurrentVelocity(1000)
            if (claimed && !abandoned) activeConsumer?.end(distance, (tracker?.xVelocity ?: 0f) / scale, !accepted)
            val handled = if (nativeCancelled || inputSession !== session) true else super.onTouchEvent(event)
            finish(); arm(); return handled
        }
        return if (nativeCancelled || inputSession !== session) true else super.onTouchEvent(event)
    }

    private fun finish() {
        tracker?.recycle(); tracker = null; ticket = null; tracking = false; claimed = false
        nativeCancelled = false; inputSession = null; activeConsumer = null; direction = null
        parent?.requestDisallowInterceptTouchEvent(false)
    }
    override fun onDetachedFromWindow() {
        revokeAutofill()
        if (viewTreeObserver.isAlive) viewTreeObserver.removeOnPreDrawListener(originObserver)
        reportedSession = null; reportedOrigin = null
        observe(HistoryInputStage.DETACH)
        cancelPresentation(); policy.invalidate(); observation?.close(); observation = null; channel = null
        tracker?.recycle(); tracker = null
        super.onDetachedFromWindow()
    }
    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        if (hasWindowFocus) arm() else { configure(false); cancelPresentation() }
    }
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        viewTreeObserver.addOnPreDrawListener(originObserver)
        post { arm() }
    }
    private fun project(value: PanZoomController.InputResultDetail?): HistoryApzResult {
        if (value == null) return HistoryApzResult(false, false, false, false, false, false, false)
        val result = value.handledResult(); val scroll = value.scrollableDirections(); val over = value.overscrollDirections()
        return HistoryApzResult(result == PanZoomController.INPUT_RESULT_HANDLED,
            result == PanZoomController.INPUT_RESULT_HANDLED_CONTENT, result == PanZoomController.INPUT_RESULT_IGNORED,
            scroll and PanZoomController.SCROLLABLE_FLAG_LEFT != 0, scroll and PanZoomController.SCROLLABLE_FLAG_RIGHT != 0,
            over and PanZoomController.OVERSCROLL_FLAG_HORIZONTAL != 0,
            result in PanZoomController.INPUT_RESULT_UNHANDLED..PanZoomController.INPUT_RESULT_IGNORED && scroll and 15 == scroll && over and 3 == over)
    }
}
