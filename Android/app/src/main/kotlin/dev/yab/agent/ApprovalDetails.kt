package dev.yab.agent

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.abs
import kotlin.math.roundToInt

internal class ApprovalDetailActions(private val controller: ApprovalController, private val shown: ApprovalPresented,
    private val reduced: Boolean, val interaction: ApprovalInteraction) {
    fun current() = interaction.current() && shown.receipt == null && shown.action?.let(controller::isDisplayedCurrent) == true
    fun openMail(index: Int, anchor: String) {
        if (!current() || index !in shown.content.mails.indices || controller.picturePresentation.frame.value.target != null) return
        val from = controller.detailAnchors.frames.value[anchor] ?: return
        val value = ApprovalDetailTarget(shown.key, ApprovalDetailKind.MAIL, anchor, index, from = from,
            paper = shown.content.mails.size == 1 && shown.content.mails[index].date == null)
        if (controller.windowPresentation.open(value, shown.key, reduced)) controller.windowPages.open(shown.key, shown.content.mails.size, index, reduced)
    }
    fun foldWindow(velocity: Double? = null) {
        if (!current() || controller.picturePresentation.frame.value.target != null) return
        val index = controller.windowPages.frame.value.selected
        val anchor = "tray:mail.$index"
        controller.windowPresentation.returnTo(shown.key, index, anchor, controller.detailAnchors.frames.value[anchor])
        controller.windowPresentation.close(shown.key, velocity)
    }
    fun openPicture(file: ApprovalFile, preview: ApprovalPreview?, anchor: String) {
        if (!current()) return
        // A callback from a removed row cannot substitute another file or preview in the current request.
        val files = shown.request.files + shown.content.mails.flatMap { it.files }
        if (file !in files || (preview != null && (preview.file != file.id || preview !in shown.request.previews))) return
        val from = controller.detailAnchors.frames.value[anchor] ?: return
        controller.picturePresentation.open(ApprovalDetailTarget(shown.key, ApprovalDetailKind.PICTURE,
            anchor, preview?.page ?: 0, file, preview, from), shown.key, reduced)
    }
    fun closePicture() { if (current()) controller.picturePresentation.close(shown.key) }
    fun page(index: Int): Boolean {
        if (!current()) return false
        controller.windowPages.goTo(shown.key, index)
        return true
    }
}

/** Re-measure during actual draws too, as a parent spring can transform a stationary layout. */
@Composable
internal fun Modifier.approvalAnchor(owner: ApprovalPresentationKey, anchor: String, registry: ApprovalDetailAnchors): Modifier {
    val density = LocalDensity.current.density.toDouble()
    val measured = remember(owner, anchor) { ApprovalAnchorMeasurement() }
    fun update() {
        val coordinates = measured.coordinates?.takeIf { it.isAttached } ?: return
        val bounds = coordinates.boundsInRoot()
        val rect = ApprovalRect(bounds.left / density, bounds.top / density, bounds.width / density, bounds.height / density)
        measured.rect = rect; registry.put(owner, anchor, rect)
    }
    DisposableEffect(owner, anchor, registry) {
        onDispose { measured.rect?.let { registry.remove(owner, anchor, it) } }
    }
    return this.onGloballyPositioned { measured.coordinates = it; update() }.drawWithContent { update(); drawContent() }
}
private class ApprovalAnchorMeasurement { var coordinates: LayoutCoordinates? = null; var rect: ApprovalRect? = null }

@Composable
internal fun ApprovalMailRow(mail: ApprovalMail, modifier: Modifier = Modifier, enabled: Boolean = false,
    paper: Boolean = false, onClick: (() -> Unit)? = null) {
    val body = modifier.fillMaxWidth().clip(RoundedCornerShape(if (paper) 22.dp else 0.dp))
        .then(if (paper) Modifier.background(MaterialTheme.colorScheme.onSurface.copy(alpha = .08f)) else Modifier)
        // The morph's decorative copy must never shield the live header below it.
        .then(if (onClick != null) Modifier.clickable(enabled = enabled, onClickLabel = "Read full email", onClick = onClick) else Modifier)
        .semantics { if (enabled) contentDescription = "Read full email: ${mail.subject}" }
    if (paper) Column(body.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            ApprovalPaperHeader("To", mail.to.joinToString())
            if (mail.cc.isNotEmpty()) ApprovalPaperHeader("Cc", mail.cc.joinToString())
            if (mail.bcc.isNotEmpty()) ApprovalPaperHeader("Bcc", mail.bcc.joinToString())
            ApprovalPaperHeader("Subject", mail.subject)
        }
        androidx.compose.material3.HorizontalDivider()
        Text(mail.body, fontSize = 16.sp, maxLines = 6, overflow = TextOverflow.Ellipsis)
        if (mail.files.isNotEmpty()) Text(mail.files.joinToString { it.name }, fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Text("Show All", Modifier.clip(RoundedCornerShape(50)).background(MaterialTheme.colorScheme.onSurface.copy(alpha = .12f))
                .padding(horizontal = 12.dp, vertical = 5.dp), fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
    } else Row(body.heightIn(min = 64.dp).padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        val who = if (mail.date == null) mail.to.firstOrNull().orEmpty() else mail.from
        Box(Modifier.size(36.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primary), contentAlignment = Alignment.Center) {
            Text(who.split(' ').filter { it.isNotBlank() }.take(2).map { it.first() }.joinToString(""), fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onPrimary)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(who, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(mail.subject, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val words = mail.body.lineSequence().filter { it.isNotBlank() }.toList()
            Text(if (words.size > 1 && words[0].length < 24) words[1] else words.firstOrNull().orEmpty(),
                fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text("›", fontSize = 20.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ApprovalPaperHeader(label: String, words: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.width(58.dp), fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(words, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
internal fun ApprovalDetailLayers(shown: ApprovalPresented, owner: ApprovalPresentationKey?, controller: ApprovalController,
    geometry: ApprovalGeometry, window: ApprovalDetailFrame?, picture: ApprovalDetailFrame?, actions: ApprovalDetailActions,
    footer: @Composable () -> Unit) {
    val anchors by controller.detailAnchors.frames.collectAsState()
    if (owner == null) return
    val windowTarget = window?.target?.takeIf { it.owner == owner }
    val pictureTarget = picture?.target?.takeIf { it.owner == owner }
    BackHandler(enabled = pictureTarget != null || windowTarget != null) {
        if (pictureTarget != null) actions.closePicture() else actions.foldWindow()
    }
    if (windowTarget != null && windowTarget.index in shown.content.mails.indices) {
        ApprovalMailWindow(shown, controller, geometry, requireNotNull(window), windowTarget,
            anchors[windowTarget.anchor] ?: windowTarget.from ?: geometry.windowRect,
            pictureTarget != null, actions, footer)
    }
    if (pictureTarget != null) ApprovalPictureLayer(shown, geometry, requireNotNull(picture), pictureTarget,
        anchors[pictureTarget.anchor] ?: pictureTarget.from ?: geometry.windowRect, controller, actions)
}

@Composable
private fun ApprovalMailWindow(shown: ApprovalPresented, controller: ApprovalController, geometry: ApprovalGeometry,
    motion: ApprovalDetailFrame, target: ApprovalDetailTarget, from: ApprovalRect, pictureVisible: Boolean,
    actions: ApprovalDetailActions, footer: @Composable () -> Unit) {
    val density = LocalDensity.current
    val observer = LocalApprovalMotionObserver.current
    val pageState by controller.windowPages.frame.collectAsState()
    val open = geometry.windowRect
    val rect = ApprovalDetailGeometry.window(from, open, motion.progress, motion.drag)
    val radius = (if (target.paper) 22.0 else 0.0).let { it + (38 - it) * motion.progress.coerceIn(0.0, 1.0) }
    val interactive = motion.opening && !pictureVisible && actions.current()
    var bounds by remember(shown.key) { mutableStateOf(Rect.Zero) }
    val pages = shown.content.mails
    // Group opacity needs shadow outsets too. This is render allocation only;
    // the window's layout, input bounds and measured anchors stay unchanged.
    val shadowHalo = 3 * 30.0 + 10
    Box(Modifier.offset { IntOffset(((rect.x - shadowHalo) * density.density).roundToInt(), ((rect.y - shadowHalo) * density.density).roundToInt()) }
        .wrapContentSize(Alignment.TopStart, unbounded = true).requiredSize((rect.width + shadowHalo * 2).coerceAtLeast(1.0).dp, (rect.height + shadowHalo * 2).coerceAtLeast(1.0).dp)
        .graphicsLayer { alpha = motion.opacity.toFloat() }) {
        Box(Modifier.offset(shadowHalo.dp, shadowHalo.dp).requiredSize(rect.width.coerceAtLeast(1.0).dp, rect.height.coerceAtLeast(1.0).dp)
            .graphicsLayer { scaleX = ApprovalDetailGeometry.windowScale(motion.drag).toFloat(); scaleY = scaleX; transformOrigin = TransformOrigin(.5f, 0f) }
            .dropShadow(RoundedCornerShape(radius.dp),
                Shadow(radius = 30.dp, color = Color.Black.copy(alpha = (.2 * motion.progress.coerceIn(0.0, 1.0)).toFloat()), offset = DpOffset(0.dp, 10.dp)))
            .clip(RoundedCornerShape(radius.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = ApprovalDetailGeometry.windowGround(motion.progress).toFloat()))
            .onGloballyPositioned { bounds = it.boundsInRoot() }
            .drawWithContent {
                drawContent(); observer?.invoke(ApprovalDrawFrame(System.nanoTime(), ApprovalTravel.READY, bounds, density.density,
                    0.0, 0.0, motion.opacity, false, ApprovalDrawSurface.WINDOW, detailProgress = motion.progress))
            }
            .testTag("approval.window")
            .then(if (interactive) Modifier else Modifier.clearAndSetSemantics {})
            .approvalWindowDrag(shown.key, controller, interactive, open.width, density.density.toDouble(), { bounds }, actions)
            .pointerInput(shown.key, interactive) {
                if (!interactive) awaitPointerEventScope { while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() } }
            }) {
            // Lay the words out at their final width from the first frame, then crop the growing edge.
            Column(Modifier.wrapContentSize(Alignment.TopStart, unbounded = true).requiredSize(open.width.dp, open.height.dp)
                .graphicsLayer { alpha = ApprovalDetailGeometry.windowWords(motion.progress).toFloat() }) {
                Row(Modifier.fillMaxWidth().height(60.dp).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = { actions.foldWindow() }, enabled = interactive,
                        modifier = Modifier.size(36.dp).testTag("approval.window.fold").semantics { contentDescription = "Back" }) { Text("⌄") }
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                        if (pages.size > 1) Text("${pageState.selected + 1} of ${pages.size}", fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                        val mail = pages[pageState.selected.coerceIn(pages.indices)]
                        Text(if (mail.date == null) "To ${mail.to.joinToString()}" else mail.from, maxLines = 1,
                            fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, overflow = TextOverflow.Ellipsis)
                    }
                    Spacer(Modifier.size(36.dp))
                }
                BoxWithConstraints(Modifier.fillMaxWidth().weight(1f).clipToBounds()) {
                    val viewportWidth = maxWidth.value.toDouble(); val viewportHeight = maxHeight.value.toDouble()
                    val viewportPixels = density.density.toDouble()
                    val accessibility = Modifier.semantics {
                        customActions = listOfNotNull(
                            if (pageState.selected > 0) CustomAccessibilityAction("Previous message") { actions.page(pageState.selected - 1) } else null,
                            if (pageState.selected < pages.lastIndex) CustomAccessibilityAction("Next message") { actions.page(pageState.selected + 1) } else null)
                    }
                    Box(Modifier.fillMaxSize().then(accessibility)) {
                        pages.forEachIndexed { index, mail ->
                            if (abs(index - pageState.page) < 1.6) key(shown.key, index) {
                                var contentHeight by remember { mutableStateOf(0) }
                                SideEffect { if (index == pageState.selected) controller.windowPages.measure(shown.key, index,
                                    viewportWidth, viewportHeight, contentHeight / viewportPixels) }
                                Box(Modifier.offset { IntOffset(((index - pageState.page) * viewportWidth * viewportPixels).roundToInt(),
                                    if (index == pageState.selected) (-pageState.scroll * viewportPixels).roundToInt() else 0) }
                                    .width(viewportWidth.dp).wrapContentHeight(unbounded = true)
                                    .onSizeChanged { contentHeight = it.height }
                                    .then(if (index == pageState.selected) Modifier else Modifier.clearAndSetSemantics {})) {
                                    ApprovalMailPage(mail, index, shown, controller, interactive && index == pageState.selected,
                                        pictureVisible, actions)
                                }
                            }
                        }
                    }
                    Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(MaterialTheme.colorScheme.surface)) { footer() }
                }
            }
            Box(Modifier.wrapContentSize(Alignment.TopStart, unbounded = true).requiredSize(from.width.dp, from.height.dp)
                .graphicsLayer { alpha = ApprovalDetailGeometry.windowGhost(motion.progress).toFloat() }.clearAndSetSemantics {}) {
                ApprovalMailRow(pages[target.index.coerceIn(pages.indices)], paper = target.paper)
            }
        }
    }
}

private fun Modifier.approvalWindowDrag(owner: ApprovalPresentationKey, controller: ApprovalController, interactive: Boolean,
    width: Double, pixels: Double, drawn: () -> Rect, actions: ApprovalDetailActions): Modifier = pointerInput(owner, interactive, width, actions.interaction) {
    if (!interactive) return@pointerInput
    val tracker = VelocityTracker(); var distance = Offset.Zero
    var pages: ApprovalWindowDragToken? = null
    var detail: ApprovalDetailDragToken? = null
    fun cancelOriginal() {
        pages?.let(controller.windowPages::cancel)
        detail?.let(controller.windowPresentation::cancel)
        pages = null; detail = null
    }
    try {
        detectDragGestures(onDragStart = {
            cancelOriginal()
            if (actions.current()) {
                tracker.resetTracking(); distance = Offset.Zero
                pages = controller.windowPages.begin(owner)
                detail = controller.windowPresentation.beginDrag(owner)
            }
        }, onDrag = { change, amount ->
            val pageToken = pages; val detailToken = detail
            if (actions.current() && pageToken != null && detailToken != null &&
                controller.windowPages.gestureCurrent(pageToken) && controller.windowPresentation.gestureCurrent(detailToken)) {
                val bounds = drawn()
                tracker.addPosition(change.uptimeMillis, change.position + Offset(bounds.left, bounds.top))
                distance += amount; change.consume()
                if (controller.windowPages.drag(owner, distance.x / pixels, distance.y / pixels, expected = pageToken) == ApprovalWindowGesture.PULL)
                    controller.windowPresentation.drag(owner, distance.y.coerceAtLeast(0f) / pixels, expected = detailToken)
            }
        }, onDragCancel = { cancelOriginal() }, onDragEnd = {
            val pageToken = pages; val detailToken = detail
            if (actions.current() && pageToken != null && detailToken != null &&
                controller.windowPages.gestureCurrent(pageToken) && controller.windowPresentation.gestureCurrent(detailToken)) {
                val speed = tracker.calculateVelocity()
                if (controller.windowPages.end(owner, speed.x / pixels, speed.y / pixels, expected = pageToken)) {
                    val frame = controller.windowPresentation.frame.value
                    if (frame.drag > 130 || frame.drag > 40 && speed.y / pixels > 650) actions.foldWindow(speed.y / pixels)
                    else controller.windowPresentation.releaseDrag(owner, speed.y / pixels, expected = detailToken)
                } else controller.windowPresentation.cancel(detailToken)
            }
            cancelOriginal()
        })
    } finally { cancelOriginal() }

}

@Composable
private fun ApprovalMailPage(mail: ApprovalMail, index: Int, shown: ApprovalPresented, controller: ApprovalController,
    interactive: Boolean, pictureVisible: Boolean, actions: ApprovalDetailActions) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(top = 6.dp, bottom = 120.dp)
        .testTag("approval.window.page.$index"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
            Box(Modifier.size(44.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primary), contentAlignment = Alignment.Center) {
                Text(mail.from.split(' ').filter { it.isNotBlank() }.take(2).map { it.first() }.joinToString("").ifBlank { "Y" }, color = MaterialTheme.colorScheme.onPrimary)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(mail.from.ifBlank { "You" }, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                Text("to ${mail.to.joinToString()}", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (mail.cc.isNotEmpty()) Text("cc ${mail.cc.joinToString()}", fontSize = 14.sp)
                if (mail.bcc.isNotEmpty()) Text("bcc ${mail.bcc.joinToString()}", Modifier.testTag("approval.window.bcc"), fontSize = 14.sp)
            }
            Text(mail.date?.let(::approvalMailDate) ?: "Draft", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(mail.subject, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        SelectionContainer { Text(mail.body, fontSize = 17.sp, lineHeight = 20.sp) }
        mail.files.forEach { file ->
            val preview = shown.request.previews.firstOrNull { it.file == file.id && it.page == 0 }
            val anchor = "win:mail.$index.${file.id}"
            val pictureTarget by controller.picturePresentation.frame.collectAsState()
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(MaterialTheme.colorScheme.onSurface.copy(alpha = .08f))
                .clickable(enabled = interactive && !pictureVisible) { actions.openPicture(file, preview, anchor) }
                .semantics { contentDescription = "Open attachment: ${file.name}" }
                .padding(8.dp).testTag("approval.attachment.${file.id}"), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.size(36.dp, 46.dp).approvalAnchor(shown.key, anchor, controller.detailAnchors)
                    .graphicsLayer { alpha = if (pictureTarget.target?.anchor == anchor) 0f else 1f }) {
                    ApprovalFilePage(file, preview, Modifier.fillMaxSize(), "${file.name}, page 1", thumbnail = true)
                }
                Column(Modifier.weight(1f)) {
                    Text(file.name, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${file.size / 1000} KB" + if (file.pages > 0) " · ${file.pages} pages" else "", fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
private fun ApprovalPictureLayer(shown: ApprovalPresented, geometry: ApprovalGeometry, motion: ApprovalDetailFrame,
    target: ApprovalDetailTarget, from: ApprovalRect, controller: ApprovalController, actions: ApprovalDetailActions) {
    val file = target.file ?: return
    val density = LocalDensity.current
    val observer = LocalApprovalMotionObserver.current
    val fit = ApprovalDetailGeometry.fitPicture(geometry.screenWidth, geometry.screenHeight, geometry.safeTop,
        file.mime.startsWith("image/"), file.width, file.height)
    val rect = ApprovalDetailGeometry.picture(from, fit, motion.progress, motion.drag)
    var bounds by remember(shown.key) { mutableStateOf(Rect.Zero) }
    val interactive = motion.opening && actions.current()
    Box(Modifier.fillMaxSize().graphicsLayer { alpha = motion.opacity.toFloat() }.testTag("approval.picture")
        .pointerInput(shown.key, interactive, actions.interaction) {
            if (!interactive) {
                awaitPointerEventScope { while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() } }
                return@pointerInput
            }
            val tracker = VelocityTracker(); var distance = 0f
            var original: ApprovalDetailDragToken? = null
            fun cancelOriginal() { original?.let(controller.picturePresentation::cancel); original = null }
            try {
                detectVerticalDragGestures(onDragStart = {
                    cancelOriginal()
                    if (actions.current()) {
                        tracker.resetTracking(); distance = 0f
                        original = controller.picturePresentation.beginDrag(shown.key)
                    }
                }, onDragCancel = { cancelOriginal() }, onVerticalDrag = { change, amount ->
                    val token = original
                    if (actions.current() && token != null && controller.picturePresentation.gestureCurrent(token)) {
                        tracker.addPosition(change.uptimeMillis, change.position); distance += amount; change.consume()
                        controller.picturePresentation.drag(shown.key, distance / density.density.toDouble(), expected = token)
                    }
                }, onDragEnd = {
                    val token = original
                    if (actions.current() && token != null && controller.picturePresentation.gestureCurrent(token))
                        controller.picturePresentation.releaseDrag(shown.key, tracker.calculateVelocity().y / density.density.toDouble(), expected = token)
                    cancelOriginal()
                })
            } finally { cancelOriginal() }
        }.then(if (interactive) Modifier else Modifier.clearAndSetSemantics {})) {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = ApprovalDetailGeometry.pictureBlack(motion.progress, motion.drag).toFloat()))
            .clickable(enabled = interactive, onClick = actions::closePicture))
        Box(Modifier.approvalRect(rect).clip(RoundedCornerShape((6 + ((if (file.mime.startsWith("image/")) 0 else 4) - 6) * motion.progress).coerceAtLeast(0.0).dp))
            .onGloballyPositioned { bounds = it.boundsInRoot() }
            .drawWithContent {
                drawContent(); observer?.invoke(ApprovalDrawFrame(System.nanoTime(), ApprovalTravel.READY, bounds, density.density,
                    0.0, 0.0, motion.opacity, false, ApprovalDrawSurface.PICTURE, detailProgress = motion.progress))
            }) {
            ApprovalFilePage(file, target.preview, Modifier.fillMaxSize(), "${file.name}, page ${target.index + 1}")
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = (geometry.safeTop + 6).dp)
            .graphicsLayer { alpha = ApprovalDetailGeometry.pictureHeader(motion.progress, motion.drag).coerceIn(0.0, 1.0).toFloat() },
            verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = actions::closePicture, enabled = interactive,
                modifier = Modifier.size(36.dp).clip(CircleShape).background(Color.White.copy(alpha = .18f))
                    .testTag("approval.picture.close").semantics { contentDescription = "Close picture" }) { Text("×", color = Color.White) }
            Text(file.name, Modifier.weight(1f).padding(horizontal = 8.dp), fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.size(36.dp))
        }
    }
}

@Composable
private fun ApprovalFilePage(file: ApprovalFile, preview: ApprovalPreview?, modifier: Modifier, description: String, thumbnail: Boolean = false) {
    val image = approvalPreviewBitmap(preview, if (thumbnail) 256 else 2048)
    if (image != null) Image(image.asImageBitmap(), description, modifier,
        contentScale = if (file.mime.startsWith("image/")) ContentScale.Crop else ContentScale.Fit)
    else Box(modifier.background(Color.White), contentAlignment = Alignment.Center) {
        Text(if (preview == null) "${file.name}\nPreview has not arrived from your Mac" else "${file.name}\nPreview unavailable",
            Modifier.padding(8.dp), color = Color.DarkGray, fontSize = 12.sp)
    }
}

@Composable
private fun Modifier.approvalRect(rect: ApprovalRect): Modifier {
    val density = LocalDensity.current.density
    return this.offset { IntOffset((rect.x * density).roundToInt(), (rect.y * density).roundToInt()) }
        .width(rect.width.coerceAtLeast(1.0).dp).height(rect.height.coerceAtLeast(1.0).dp)
}

private fun approvalMailDate(seconds: Double): String = runCatching {
    val date = java.time.Instant.ofEpochSecond(seconds.toLong()).atZone(java.time.ZoneId.systemDefault())
    val format = if (date.toLocalDate() == java.time.LocalDate.now()) java.time.format.DateTimeFormatter.ofLocalizedTime(java.time.format.FormatStyle.SHORT)
        else java.time.format.DateTimeFormatter.ofPattern("MMM d")
    date.format(format)
}.getOrDefault("")
