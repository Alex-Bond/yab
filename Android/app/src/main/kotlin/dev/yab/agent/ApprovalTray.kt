package dev.yab.agent

import android.view.WindowManager
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import dev.yab.browser.ui.LocalBrowserAccessibility
import kotlin.math.roundToInt
import kotlinx.coroutines.delay

internal fun ApprovalReceipt.caption(): String = when (result?.phase) {
    ApprovalResultPhase.paying -> "Paying on your Mac"
    ApprovalResultPhase.paid -> "Paid"
    ApprovalResultPhase.declined -> "Payment not completed"
    ApprovalResultPhase.done -> "Completed on your Mac"
    ApprovalResultPhase.failed -> "Your Mac could not complete it"
    null -> "Sent to your Mac"
}

@Composable
internal fun ApprovalTrayPrompt(controller: ApprovalController, authentication: ApprovalAuthentication?, observeInScreen: Boolean) {
    val state by controller.state.collectAsState()
    LaunchedEffect(controller, observeInScreen) { if (observeInScreen) controller.observe() }
    val receipt = state.receipts.lastOrNull().takeIf { state.selected == null }
    val retry = receipt?.let(controller::retryRequest)
    val request = retry ?: receipt?.request ?: state.requests.firstOrNull { it.id == state.selected }
        ?: state.requests.firstOrNull { it.id !in state.deferred }
    val shownReceipt = receipt.takeIf { retry == null }
    val desired = remember(controller, request, shownReceipt, retry, state.ownerEpoch, state.presentationGeneration) {
        request?.let {
            ApprovalPresented(ApprovalPresentationKey(it.account, state.ownerEpoch, it.mac, it.id, it.fingerprint(), state.presentationGeneration),
                it, shownReceipt, if (shownReceipt == null) controller.captureDisplayed(it) else null, receipt.takeIf { retry != null })
        }
    }
    val presentation = controller.trayPresentation
    val windowPresentation = controller.windowPresentation
    val picturePresentation = controller.picturePresentation
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    // Reconcile before drawing: a retired owner is never retained for an exit in a new account.
    SideEffect { presentation.offer(desired, { controller.ownsPresentation(it.request, it.key.epoch) }, reduced) }
    val frame by presentation.frame.collectAsState()
    val windowFrame by windowPresentation.frame.collectAsState()
    val pictureFrame by picturePresentation.frame.collectAsState()
    val pageFrame by controller.windowPages.frame.collectAsState()
    LaunchedEffect(presentation, frame.running) {
        if (!frame.running) return@LaunchedEffect
        var previous = withFrameNanos { it }
        while (presentation.frame.value.running) {
            val now = withFrameNanos { it }
            presentation.advance((now - previous).coerceAtLeast(0) / 1_000_000_000.0)
            previous = now
        }
    }
    val shown = frame.content?.takeIf { controller.ownsPresentation(it.request, it.key.epoch) }
    val detailOwner = shown?.takeIf { it.receipt == null && it.action?.let(controller::isDisplayedCurrent) == true }?.key
    SideEffect {
        windowPresentation.reconcile(detailOwner, reduced)
        picturePresentation.reconcile(detailOwner, reduced)
        controller.windowPages.reconcile(detailOwner)
        controller.detailAnchors.reconcile(detailOwner)
    }
    val detailsRunning = windowFrame.running || pictureFrame.running || pageFrame.running
    LaunchedEffect(controller, detailsRunning) {
        controller.detailClock.idle()
        while (controller.detailClock.running) controller.detailClock.frame(withFrameNanos { it })
    }
    if (shown == null) return
    val visibleWindow = windowFrame.takeIf { it.target?.owner == detailOwner }
    val visiblePicture = pictureFrame.takeIf { it.target?.owner == detailOwner }
    val detailsVisible = visibleWindow?.target != null || visiblePicture?.target != null
    val draft = remember(shown.key, shown.receipt != null) { ApprovalTrayDraft(shown.request, shown.retry?.picks) }
    val credential = rememberApprovalCredentialAuthentication(authentication, controller, shown, draft)
    val credentialState = credential?.state?.collectAsState()?.value ?: ApprovalCredentialState()
    val interaction = rememberApprovalInteraction(credentialState.revision)
    val actionAuthentication = credential ?: authentication
    SideEffect { credential?.reconcile(); credential?.bindReview(credentialState.revision, interaction) }
    LaunchedEffect(credential, credentialState.revision) {
        credential?.expiryDelay()?.let { delay(it); credential.reconcile() }
    }
    val credentialNotice = when (credentialState.phase) {
        ApprovalCredentialPhase.CONFIRM -> if (shown.request.choices.isNotEmpty()) "PIN verified. Tap the same account again to sign in."
            else "PIN verified. Tap the approval button again to continue."
        ApprovalCredentialPhase.PIN -> "Complete device verification, then return to Yab."
        ApprovalCredentialPhase.NONE -> null
    }
    val detailActions = ApprovalDetailActions(controller, shown, reduced, interaction)
    val observer = LocalApprovalMotionObserver.current
    var drawnBounds by remember(shown.key) { mutableStateOf(Rect.Zero) }
    var drawnIslandBounds by remember(shown.key) { mutableStateOf(Rect.Zero) }
    Dialog(onDismissRequest = {
        if (visiblePicture?.target != null) detailActions.closePicture()
        else if (visibleWindow?.target != null) detailActions.foldWindow()
    }, properties = DialogProperties(usePlatformDefaultWidth = false,
        decorFitsSystemWindows = false, dismissOnBackPress = true, dismissOnClickOutside = false)) {
        val window = (LocalView.current.parent as? DialogWindowProvider)?.window
        val islandOnly = frame.phase in setOf(ApprovalTravel.ISLAND, ApprovalTravel.ISLAND_LEAVING)
        val passesThrough = islandOnly || (!reduced && frame.fold >= .5)
        SideEffect {
            window?.setDimAmount(0f); window?.setWindowAnimations(0)
            if (passesThrough) window?.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
            else window?.clearFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
        }
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val density = LocalDensity.current
            val safeTop = WindowInsets.statusBars.getTop(density) / density.density.toDouble()
            val lift = maxOf(WindowInsets.ime.getBottom(density), WindowInsets.navigationBars.getBottom(density)) / density.density.toDouble()
            val geometry = ApprovalGeometry(maxWidth.value.toDouble(), maxHeight.value.toDouble(), safeTop,
                frame.height, lift, frame.rise, frame.drag, frame.fold, window = visibleWindow?.progress ?: 0.0, trayFade = frame.fade)
            val footer: @Composable () -> Unit = {
                ApprovalTrayFooter(shown, state, frame.interactive,
                    frame.phase in setOf(ApprovalTravel.ENTERING, ApprovalTravel.READY), actionAuthentication, controller, draft, interaction)
            }
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = geometry.dim.coerceIn(0.0, 1.0).toFloat())))
            if (!islandOnly) {
                val rect = geometry.rect
                Box(Modifier.offset { IntOffset((rect.x * density.density).roundToInt(), (rect.y * density.density).roundToInt()) }
                    .width(rect.width.dp).height(rect.height.dp).clip(RoundedCornerShape(geometry.radius.dp))
                    .background(MaterialTheme.colorScheme.surface)
                    .graphicsLayer { alpha = frame.fade.toFloat() }
                    .graphicsLayer { scaleX = geometry.behindScale.toFloat(); scaleY = geometry.behindScale.toFloat(); transformOrigin = TransformOrigin(.5f, 1f) }
                    .onGloballyPositioned { drawnBounds = it.boundsInRoot() }
                    .drawWithContent {
                        drawContent()
                        observer?.invoke(ApprovalDrawFrame(System.nanoTime(), frame.phase, drawnBounds, density.density,
                            frame.rise, frame.fold, frame.fade, shown.receipt != null, result = shown.receipt?.result?.phase))
                    }
                    .testTag("approval.tray")
                    .pointerInput(frame.phase, detailsVisible) {
                        if (detailsVisible || frame.phase !in setOf(ApprovalTravel.ENTERING, ApprovalTravel.READY)) awaitPointerEventScope {
                            while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
                        }
                    }
                    .then(if (!detailsVisible && frame.phase in setOf(ApprovalTravel.ENTERING, ApprovalTravel.READY)) Modifier else Modifier.clearAndSetSemantics {})) {
                    key(shown.key, shown.receipt != null) {
                        Column(Modifier.fillMaxWidth().wrapContentHeight(unbounded = true, align = Alignment.Top)
                            .graphicsLayer { alpha = geometry.wordsOpacity.toFloat() }) {
                            ApprovalTrayContent(shown, state, frame.interactive && !detailsVisible, actionAuthentication, controller, draft, detailActions, interaction, footer,
                            credentialNotice = credentialNotice,
                            measured = { presentation.measure(shown.key, it / density.density.toDouble()) },
                            maxBody = geometry.bodyCap, headerModifier = Modifier.pointerInput(shown.key, frame.interactive, reduced, interaction, state.busy, state.failureRevision) {
                                val captured = shown.action ?: return@pointerInput
                                val failureRevision = state.failureRevision
                                fun sourceCurrent(): Boolean = interaction.current() && controller.isDisplayedCurrent(captured) && controller.state.value.let {
                                    it.busy == null && it.error == null && it.failureRevision == failureRevision
                                }
                                if (!sourceCurrent() || !frame.interactive || detailsVisible || reduced) return@pointerInput
                                val tracker = VelocityTracker()
                                var distance = 0f
                                var admitted = false
                                detectVerticalDragGestures(onDragStart = {
                                    admitted = sourceCurrent(); distance = 0f; tracker.resetTracking()
                                    if (admitted) presentation.beginDrag(shown.key)
                                }, onDragCancel = {
                                    admitted = false; presentation.cancelDrag(shown.key)
                                }, onVerticalDrag = { change, amount ->
                                    if (admitted && sourceCurrent()) {
                                        tracker.addWindowChange(change, Offset(drawnBounds.left, drawnBounds.top)); distance += amount
                                        change.consume(); presentation.drag(shown.key, distance / density.density.toDouble())
                                    } else { admitted = false; presentation.cancelDrag(shown.key) }
                                }, onDragEnd = {
                                    if (admitted && sourceCurrent() && presentation.releaseDrag(shown.key, tracker.calculateVelocity().y / density.density.toDouble())) {
                                        val submission = interaction.launch { ticket -> if (sourceCurrent()) controller.answer(shown.request.id, false, actionAuthentication, displayed = captured, interaction = ticket) }
                                        // Also runs if Activity disposal cancels the launch before its body starts.
                                        if (submission == null) presentation.submissionRetainedQuestion(shown.key)
                                        submission?.invokeOnCompletion {
                                            if (controller.state.value.requests.any { it.id == shown.request.id && it.fingerprint() == shown.key.facts })
                                                presentation.submissionRetainedQuestion(shown.key)
                                        }
                                    } else if (!admitted || !sourceCurrent()) presentation.cancelDrag(shown.key)
                                })
                            })
                        }
                    }
                }
            }
            ApprovalDetailLayers(shown, detailOwner, controller, geometry, visibleWindow, visiblePicture,
                detailActions, footer)
            val notice = shown.receipt
            if (notice != null && frame.island > .001 && frame.phase in setOf(ApprovalTravel.FOLDING, ApprovalTravel.ISLAND, ApprovalTravel.ISLAND_LEAVING)) {
                val words = notice.caption()
                val share = frame.island.coerceIn(0.0, 1.1)
                val wide = (words.length * 9.6 + 30 + 30 + 44).coerceAtMost(maxWidth.value - 24.0)
                val width = 126 + (wide - 126) * share
                val visible = (share * 3).coerceIn(0.0, 1.0) * frame.islandFade
                Box(Modifier.offset { IntOffset(((maxWidth.value - width) / 2 * density.density).roundToInt(), (geometry.island.y * density.density).roundToInt()) }
                    .width(width.dp).height(37.dp).graphicsLayer { alpha = visible.toFloat() }
                    .onGloballyPositioned { drawnIslandBounds = it.boundsInRoot() }
                    .drawWithContent {
                        drawContent()
                        observer?.invoke(ApprovalDrawFrame(System.nanoTime(), frame.phase, drawnIslandBounds, density.density,
                            frame.rise, frame.fold, visible, true, ApprovalDrawSurface.CAPSULE, notice.result?.phase))
                    }
                    .clip(RoundedCornerShape(50)).background(MaterialTheme.colorScheme.inverseSurface)
                    .padding(horizontal = 15.dp).testTag("approval.receipt.capsule"), contentAlignment = Alignment.Center) {
                    Text(words, color = MaterialTheme.colorScheme.inverseOnSurface, style = MaterialTheme.typography.labelLarge,
                        maxLines = 1, overflow = TextOverflow.Clip,
                        modifier = Modifier.graphicsLayer { alpha = ((share - .45) / .4).coerceIn(0.0, 1.0).toFloat() })
                }
            }
        }
    }
}

@Composable
private fun ApprovalTrayContent(shown: ApprovalPresented, state: ApprovalUiState, interactive: Boolean,
    authentication: ApprovalAuthentication?, controller: ApprovalController, draft: ApprovalTrayDraft, details: ApprovalDetailActions, interaction: ApprovalInteraction, footer: @Composable () -> Unit,
    credentialNotice: String?,
    measured: (Int) -> Unit, maxBody: Double, headerModifier: Modifier) {
    val request = shown.request
    val receipt = shown.receipt
    val action = shown.action
    val content = shown.content
    val failureRevision = state.failureRevision
    val controlOwner = remember(shown.key, failureRevision, interaction) { Any() }
    val failed = state.error != null && action?.let(controller::isDisplayedCurrent) == true
    val enabled = interaction.current() && interactive && state.busy == null && !failed && action != null && controller.isDisplayedCurrent(action)
    val canEditPayment = { interaction.current() && interactive && controller.state.value.let {
        it.busy == null && it.error == null && it.failureRevision == failureRevision
    } && action?.let(controller::isDisplayedCurrent) == true }
    Row(headerModifier.fillMaxWidth().height(60.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(receipt?.caption() ?: request.title, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
        if (receipt == null && !failed) key(controlOwner, enabled) {
            val control = remember { ApprovalTrayControl(enabled, canEditPayment) {
                interaction.launch { ticket -> if (canEditPayment()) action?.let {
                    controller.answer(request.id, false, authentication, displayed = it, interaction = ticket)
                } }
            } }
            DisposableEffect(control) { onDispose { control.dispose() } }
            TextButton(enabled = enabled, modifier = Modifier.size(36.dp).semantics { contentDescription = "Decline approval" },
                onClick = { control.invoke() }) { Text("×") }
        }
    }
    Column(Modifier.fillMaxWidth().heightIn(max = maxBody.dp).onSizeChanged { measured(it.height) }) {
        Column(Modifier.weight(1f, fill = false).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (receipt != null) {
                Text(request.title)
                receipt.result?.takeIf { it.phase == ApprovalResultPhase.done }?.words?.let { Text(it) }
                if (receipt.result == null) Text("Waiting for the actual result. Approval is not confirmation of completion.")
            } else {
                val consent = content.consent
                if (consent != null) {
                    Text(consent.question, fontWeight = FontWeight.Bold)
                    Text(consent.context)
                    consent.first?.let { Text(it, Modifier.testTag("approval.search.first")) }
                    consent.lifetime?.let { Text(it, Modifier.testTag("approval.search.scope")) }
                    consent.terms?.let { Text(it) }
                } else {
                    Text(request.asker + " · " + request.summary)
                    content.lines.forEach { Text(it) }
                }
                request.payment?.let { ApprovalPaymentEditor(it, draft.picks, declinedCard = shown.retry?.picks?.card,
                    enabled = enabled, controlOwner = controlOwner, canEdit = canEditPayment) { value -> if (canEditPayment()) draft.picks = value } }
                content.mails.forEachIndexed { index, mail ->
                    ApprovalMailRow(mail, Modifier.approvalAnchor(shown.key, "tray:mail.$index", controller.detailAnchors), enabled,
                        paper = content.mails.size == 1 && mail.date == null) {
                        if (canEditPayment()) details.openMail(index, "tray:mail.$index")
                    }
                }
                request.person?.let { Text("To: $it") }; if (consent == null) request.text?.let { Text(it) }
                request.files.forEach { file -> ApprovalFilePreview(file, request.previews, enabled = enabled, canInteract = canEditPayment,
                    previewModifier = { preview -> Modifier.approvalAnchor(shown.key, "tray:file.${file.id}.${preview.page}", controller.detailAnchors) },
                    onPreview = { preview -> if (canEditPayment()) details.openPicture(file, preview, "tray:file.${file.id}.${preview.page}") }) }
                request.choices.forEach { value ->
                    key(controlOwner, enabled, value) {
                        val control = remember { ApprovalTrayControl(enabled, canEditPayment) {
                            val captured = action
                            interaction.launch { ticket -> if (canEditPayment()) captured?.let {
                                controller.answer(request.id, true, authentication, choice = value, displayed = it, interaction = ticket)
                            } }
                        } }
                        DisposableEffect(control) { onDispose { control.dispose() } }
                        TextButton(enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)
                            .semantics { contentDescription = "Sign in as $value" }, onClick = { control.invoke() }) { Text(value) }
                    }
                }
                credentialNotice?.let { Text(it, Modifier.testTag("approval.credential.confirmation")) }
            }
        }
        footer()
    }
}

/** An actual keyed Header/Account control never adopts a later rendered action. */
private class ApprovalTrayControl(private val enabled: Boolean, private val current: () -> Boolean,
    private val action: () -> Unit) {
    private var disposed = false
    fun dispose() { disposed = true }
    fun invoke() { if (!disposed && enabled && current()) action() }
}

internal class ApprovalTrayDraft(request: ApprovalRequest, retry: ApprovalPicks? = null) {
    var revision by mutableStateOf(0L)
        private set
    private var selectedChoice by mutableStateOf<String?>(null)
    var choice: String?
        get() = selectedChoice
        set(value) { if (selectedChoice != value) { selectedChoice = value; revision++ } }
    private var selectedPicks by mutableStateOf(request.payment?.let { payment -> retry?.forRetry(payment) ?: ApprovalPicks(
        card = payment.card.takeIf { payment.takesCard }, place = payment.place.takeIf { payment.takesPlace }) } ?: ApprovalPicks())
    var picks: ApprovalPicks
        get() = selectedPicks
        set(value) { if (selectedPicks != value) { selectedPicks = value; revision++ } }
}

@Composable
private fun ApprovalTrayFooter(shown: ApprovalPresented, state: ApprovalUiState, interactive: Boolean, presented: Boolean,
    authentication: ApprovalAuthentication?, controller: ApprovalController, draft: ApprovalTrayDraft, interaction: ApprovalInteraction) {
    val request = shown.request; val receipt = shown.receipt; val action = shown.action
    val failureRevision = state.failureRevision
    val failure = state.error.takeIf { action?.let(controller::isDisplayedCurrent) == true }
    val model = ApprovalFooterPresentation.from(shown, state.busy == request.id, failure)
    val failed = action?.let(controller::captureFailure)?.takeIf { it.revision == state.failureRevision }
    val enabled = interaction.current() && presented && when (model.action) {
        ApprovalFooterAction.APPROVE -> interactive && state.busy == null && action?.let(controller::isDisplayedCurrent) == true
        ApprovalFooterAction.CLOSE_FAILURE -> interactive && failed?.let(controller::failureCurrent) == true
        ApprovalFooterAction.CLOSE_RESULT -> receipt != null && state.busy == null && state.selected == null && state.receipts.lastOrNull() == receipt &&
            controller.ownsPresentation(request, shown.key.epoch)
        ApprovalFooterAction.NONE -> false
    }
    val current = {
        val frame = controller.trayPresentation.frame.value
        val live = controller.state.value
        interaction.current() && frame.phase in setOf(ApprovalTravel.ENTERING, ApprovalTravel.READY) && frame.content?.key == shown.key &&
            controller.ownsPresentation(request, shown.key.epoch) && live.failureRevision == failureRevision &&
            (if (receipt != null) live.selected == null && live.receipts.lastOrNull() == receipt && controller.retryRequest(receipt) == null
             else action?.let(controller::isDisplayedCurrent) == true) &&
            ApprovalFooterPresentation.from(shown, live.busy == request.id, live.error.takeIf { receipt == null }) == model &&
            when (model.action) {
                ApprovalFooterAction.APPROVE -> live.busy == null && live.error == null && frame.interactive
                ApprovalFooterAction.CLOSE_FAILURE -> frame.interactive && failed?.let(controller::failureCurrent) == true
                ApprovalFooterAction.CLOSE_RESULT -> live.busy == null
                ApprovalFooterAction.NONE -> false
            }
    }
    val footerOwner = remember(shown.key, model, failureRevision, interaction) { Any() }
    ApprovalFooter(footerOwner, model, request.payment?.site.orEmpty(), enabled, current) {
        when (model.action) {
            ApprovalFooterAction.APPROVE -> {
                val capturedPicks = draft.picks; val capturedChoice = draft.choice
                interaction.launch { ticket -> if (current()) action?.let {
                    controller.answer(request.id, true, authentication, capturedChoice, capturedPicks, displayed = it, interaction = ticket)
                } }
            }
            ApprovalFooterAction.CLOSE_FAILURE -> interaction.credentialReviewTicket()?.let { ticket ->
                if (failed != null && controller.closeFailure(failed, ticket)) authentication?.cancelApprovalAuthentication()
            }
            ApprovalFooterAction.CLOSE_RESULT -> controller.dismissPresentedResult(shown.key)
            ApprovalFooterAction.NONE -> Unit
        }
    }
}
