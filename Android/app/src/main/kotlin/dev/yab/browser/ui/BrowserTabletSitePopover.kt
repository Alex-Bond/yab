package dev.yab.browser.ui

import android.animation.ValueAnimator
import android.content.Context
import android.content.res.Configuration
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.isTraversalGroup
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.android.R
import dev.yab.browser.engine.SiteDecision
import dev.yab.browser.engine.SitePermission
import dev.yab.browser.engine.SiteSettingsStore
import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.BrowserSurface
import dev.yab.browser.model.PageMenuLease
import java.text.DateFormat
import java.util.Date
import kotlin.math.max
import kotlin.math.min

/** Phone fixes the content width/inset/height range; its native arrow raster is separate evidence. */
internal data class TabletSitePopoverGeometry(val width: Double, val height: Double,
    val anchor: PageMenuRect, val safeTop: Double) {
    init { require(listOf(width, height, safeTop).all(Double::isFinite) && width >= 296 &&
        height > safeTop + 80 && safeTop >= 0 && anchor.valid() && anchor.x >= 0 && anchor.y >= 0 &&
        anchor.right <= width && anchor.bottom <= height && max(safeTop, anchor.bottom) + 8 + 44 <= height - 8) }
    fun frame(contentHeight: Double): PageMenuRect {
        require(contentHeight.isFinite() && contentHeight >= 0)
        val w = 280.0
        val x = (anchor.x + anchor.width / 2 - w / 2).coerceIn(8.0, width - 8 - w)
        val y = max(safeTop, anchor.bottom) + 8
        return PageMenuRect(x, y, w, min(min(480.0, max(44.0, contentHeight)), max(44.0, height - y - 8)))
    }
}

internal class TabletSiteAction(private val current: () -> Boolean, private val action: () -> Boolean) {
    private var retired = false
    fun retire() { retired = true }
    fun enabled() = !retired && current()
    fun perform(): Boolean = enabled() && !retired && action()
}

/** Captured only by the original pressed row; a moved/detached anchor never revives. */
internal class TabletSiteChoiceAnchor(val rect: PageMenuRect, private val layoutCurrent: () -> Boolean) {
    private var retired = false
    fun current(): Boolean {
        if (retired) return false
        if (!layoutCurrent()) { retired = true; return false }
        return true
    }
    fun frame(width: Double, height: Double, rows: Int): PageMenuRect {
        val w = min(240.0, width - 16)
        val h = min(16.0 + rows * 44, height - 16)
        return PageMenuRect(rect.x.coerceIn(8.0, width - 8 - w),
            rect.bottom.coerceIn(8.0, height - 8 - h), w, h)
    }
}

private class TabletSiteRowAnchor(private val state: BrowserTabletSitePopoverState, private val density: Float) {
    private data class Measurement(val coordinates: LayoutCoordinates, val bounds: androidx.compose.ui.geometry.Rect)
    private var measured by mutableStateOf<Measurement?>(null)
    fun positioned(coordinates: LayoutCoordinates) {
        val next = Measurement(coordinates, coordinates.boundsInRoot())
        if (measured != next) measured = next
    }
    fun capture(): TabletSiteChoiceAnchor? {
        val measurement = measured ?: return null
        val original = measurement.coordinates.takeIf { it.isAttached } ?: return null
        val bounds = measurement.bounds
        if (original.boundsInRoot() != bounds) return null
        val root = state.session.root
        val rect = PageMenuRect(bounds.left / density - root.x, bounds.top / density - root.y,
            bounds.width / density.toDouble(), bounds.height / density.toDouble())
        if (!rect.valid() || rect.x < 0 || rect.y < 0 || rect.right > root.width || rect.bottom > root.height) return null
        return TabletSiteChoiceAnchor(rect) { original.isAttached && measured === measurement && original.boundsInRoot() == bounds }
    }
}

internal sealed class TabletSiteChoice(val anchor: TabletSiteChoiceAnchor) {
    class Permission(val kind: SitePermission, anchor: TabletSiteChoiceAnchor) : TabletSiteChoice(anchor)
    class More(anchor: TabletSiteChoiceAnchor) : TabletSiteChoice(anchor)
}

/** An adapter for the existing captured Entry/Scope, never a new PAGE/native lease. */
internal class BrowserTabletSitePopoverState(val session: BrowserPageMenuSession) {
    private val entry get() = session.entry
    private var retired = false
    var bodyRevision by mutableLongStateOf(0); private set
    var choice by mutableStateOf<TabletSiteChoice?>(null); private set
    val frame get() = entry.presentation.frame.value
    val geometry = TabletSitePopoverGeometry(session.geometry.width, session.geometry.height,
        session.geometry.plate, session.geometry.safeTop)
    init { entry.layoutLease.accept(session.geometry) }
    fun sourceCurrent(): Boolean {
        if (retired) return false
        if (!entry.owned()) { retired = true; return false }
        return true
    }
    fun retire() { retired = true; choice = null }
    private fun scope(reduced: Boolean, animations: Boolean, body: PageMenuPage? = null) = BrowserPageMenuScope(
        session.geometry.pose(frame, reduced), sourceCurrent() && frame.interactive,
        frame.targetPage, entry, reduced, animations, body)
    fun action(page: PageMenuPage, reduced: Boolean, animations: Boolean, available: () -> Boolean = { true },
        afterLanding: Boolean = false, run: (PageMenuLease) -> Unit): TabletSiteAction {
        val originalScope = scope(reduced, animations, page)
        val originalRevision = bodyRevision
        val originalChoice = choice
        return TabletSiteAction({ sourceCurrent() && choice === originalChoice && bodyRevision == originalRevision && frame.targetPage == page && frame.interactive && available() }) {
            originalScope.perform(afterLanding, run)
        }
    }
    fun closeControl(reduced: Boolean, animations: Boolean): TabletSiteAction = TabletSiteAction(
        { sourceCurrent() && frame.shown && frame.phase != PageMenuPhase.REVOKED }) {
        entry.close(System.nanoTime(), reduced, animations)
    }
    fun certificate(reduced: Boolean, animations: Boolean): TabletSiteAction {
        val originalScope = scope(reduced, animations, PageMenuPage.SITE)
        val originalRevision = bodyRevision
        return TabletSiteAction({ sourceCurrent() && choice == null && bodyRevision == originalRevision && frame.interactive && frame.targetPage == PageMenuPage.SITE &&
            session.snapshot.connection?.secure == true }) {
            if (originalScope.navigate(PageMenuPage.CERTIFICATE)) { bodyRevision++; choice = null; true } else false
        }
    }
    fun certificateBack(reduced: Boolean, animations: Boolean): TabletSiteAction {
        val originalHeader = scope(reduced, animations)
        val originalRevision = bodyRevision
        return TabletSiteAction({ sourceCurrent() && bodyRevision == originalRevision && frame.interactive && frame.targetPage == PageMenuPage.CERTIFICATE }) {
            if (originalHeader.back()) { bodyRevision++; choice = null; true } else false
        }
    }
    fun choose(next: TabletSiteChoice) { if (sourceCurrent() && frame.interactive && next.anchor.current()) choice = next }
    fun choiceCurrent(original: TabletSiteChoice) = sourceCurrent() && choice === original && original.anchor.current() && frame.targetPage == PageMenuPage.SITE
    fun dismissChoice(original: TabletSiteChoice) { if (choice === original) choice = null }
    fun complete() {
        entry.presentation.claimCompletion { it == session.lease && entry.drawingOwned() }?.let { completion ->
            entry.released(session.lease, completion.reason)
            if (completion.reason == PageMenuRelease.LANDED && entry.owned()) completion.action?.invoke()
        }
    }
}

/** In the original Main window so its retained focus/token/account/native admission stays exact. */
@Composable
internal fun BrowserTabletSitePopover(session: BrowserPageMenuSession, shown: Boolean,
    controller: BrowserController, context: Context, onTranslate: (() -> Unit)?) {
    val state = remember(session) { BrowserTabletSitePopoverState(session) }
    val entry = session.entry
    val frame by entry.presentation.frame.collectAsState()
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val animations = LocalPageMenuAnimationsEnabled.current ?: ValueAnimator.areAnimatorsEnabled()
    val translate = remember(session) { onTranslate }
    val close = remember(state, reduced, animations) { state.closeControl(reduced, animations) }
    DisposableEffect(state) { onDispose { close.retire(); state.retire() } }
    if (state.sourceCurrent() && frame.phase !in setOf(PageMenuPhase.REVOKED, PageMenuPhase.CLOSED, PageMenuPhase.HANDED_OFF)) {
        LaunchedEffect(state, shown, reduced, animations) {
            if (!shown) close.perform()
            state.complete()
        }
        LaunchedEffect(state, frame.running) {
            while (entry.presentation.frame.value.running) withFrameNanos {
                if (state.sourceCurrent()) entry.presentation.advance(System.nanoTime()) else entry.presentation.revoke()
                state.complete()
            }
        }
        BackHandler { if (state.choice != null) state.choice?.let(state::dismissChoice) else close.perform() }
        val density = LocalDensity.current.density
        var contentHeight by remember(state) { mutableDoubleStateOf(280.0) }
        val panel = state.geometry.frame(contentHeight)
        val shapeView = LocalView.current
        val shapeRoot = shapeView.rootView
        val shapeToken = shapeView.windowToken
        val shapeConfiguration = Configuration(shapeView.resources.configuration)
        val shapeSource = remember(state, panel, density, shapeView, shapeRoot, shapeToken, shapeConfiguration) { Any() }
        var shapeContainer by remember(shapeSource) { mutableStateOf<dev.yab.browser.model.TabletWorkspaceRect?>(null) }
        val containerSource = remember(shapeSource, shapeContainer) { Any() }
        val container = shapeContainer?.let { TabletConcentricContainer(containerSource, it) }
        val ink = MaterialTheme.colorScheme.surface
        Box(Modifier.fillMaxSize().testTag("browser.tablet.site.host").semantics {
            isTraversalGroup = true; paneTitle = "Site Controls"
        }.drawWithContent { if (state.sourceCurrent()) drawContent() }) {
            key(close) {
                Box(Modifier.fillMaxSize().clickable(enabled = close.enabled()) { close.perform() }
                    .semantics { contentDescription = "Close Site Controls" }.testTag("browser.tablet.site.outside"))
            }
            // This app-owned arrow keeps the source-defined top edge/anchor. Its
            // footprint, corner/material raster and platform transition remain unqualified.
            Canvas(Modifier.offset((session.geometry.plate.x + session.geometry.plate.width / 2 - 8).dp,
                (panel.y - 8).dp).size(16.dp, 8.dp)) {
                drawPath(Path().apply { moveTo(0f, size.height); lineTo(size.width / 2, 0f); lineTo(size.width, size.height); close() }, ink)
            }
            Surface(Modifier.offset(panel.x.dp, panel.y.dp).size(panel.width.dp, panel.height.dp)
                .onGloballyPositioned {
                    if (shapeView.rootView === shapeRoot && shapeView.windowToken === shapeToken && shapeToken != null &&
                        shapeView.isAttachedToWindow && shapeView.resources.configuration == shapeConfiguration)
                        shapeContainer = tabletShapeBounds(it, density)
                }
                .testTag("browser.tablet.site.panel"), shape = RoundedCornerShape(TabletConcentricGeometry.siteRadius.dp), color = ink, shadowElevation = 8.dp) {
              CompositionLocalProvider(LocalTabletConcentricContainer provides container) {
                val scroll = rememberScrollState()
                Box(Modifier.fillMaxSize().verticalScroll(scroll)) {
                    Column(Modifier.fillMaxWidth().onSizeChanged {
                        if (state.sourceCurrent()) contentHeight = it.height / density.toDouble()
                    }.padding(8.dp)) {
                        key(state, state.bodyRevision, frame.targetPage) {
                            if (frame.targetPage == PageMenuPage.CERTIFICATE) TabletSiteCertificate(state, reduced, animations)
                            else TabletSiteContents(state, controller, context, translate, reduced, animations)
                        }
                    }
                }
              }
            }
            // Only close survives own coverage. Ordinary toolbar commands stay retired.
            key(close) {
                IconButton(enabled = close.enabled(), onClick = { close.perform() },
                    modifier = Modifier.offset(session.geometry.plate.x.dp, session.geometry.plate.y.dp)
                        .size(session.geometry.plate.width.dp, session.geometry.plate.height.dp)
                        .testTag("browser.tablet.site.close").semantics { contentDescription = "Site Controls" }) {
                    Icon(painterResource(R.drawable.tablet_toolbar_site_controls), null, Modifier.size(20.dp))
                }
            }
            state.choice?.let { original ->
                if (!state.choiceCurrent(original)) SideEffect { state.dismissChoice(original) }
                else key(original) { TabletSiteChoices(state, original, controller, reduced, animations) }
            }
        }
    } else SideEffect {
        if (!state.sourceCurrent() || frame.phase == PageMenuPhase.REVOKED) entry.presentation.revoke()
        state.complete()
    }
}

@Composable
private fun rememberSiteAction(state: BrowserTabletSitePopoverState, vararg keys: Any?,
    make: () -> TabletSiteAction): TabletSiteAction {
    val action = remember(state, *keys) { make() }
    DisposableEffect(action) { onDispose { action.retire() } }
    return action
}

@Composable
private fun TabletSiteContents(state: BrowserTabletSitePopoverState, controller: BrowserController,
    context: Context, translate: (() -> Unit)?, reduced: Boolean, animations: Boolean) {
    val session = state.session
    val snapshot = session.snapshot
    val preferences = snapshot.preferences
    val page = PageMenuPage.SITE
    val share = rememberSiteAction(state, "share", reduced, animations) {
        state.action(page, reduced, animations, afterLanding = true) { shareLink(context, session.url) }
    }
    val find = rememberSiteAction(state, "find", snapshot.page.loading, reduced, animations) {
        state.action(page, reduced, animations, { !session.snapshot.page.loading }, true) { controller.beginFind() }
    }
    val reader = rememberSiteAction(state, "reader", snapshot.page.readerAvailable, snapshot.page.readerEnabled, reduced, animations) {
        state.action(page, reduced, animations, { session.snapshot.page.readerAvailable || session.snapshot.page.readerEnabled }, true) { controller.reader() }
    }
    val translation = rememberSiteAction(state, "translate", translate, snapshot.page.readerEnabled, reduced, animations) {
        state.action(page, reduced, animations, { translate != null && !session.snapshot.page.readerEnabled &&
            (session.url.startsWith("https://") || session.url.startsWith("http://")) }, true) { translate?.invoke() }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        SiteFace(share, "Share", "share", R.drawable.tablet_site_share, Modifier.weight(1f))
        SiteFace(find, "Find on Page", "find", R.drawable.tablet_site_find, Modifier.weight(1f))
        SiteFace(reader, "Reader", "reader", R.drawable.tablet_site_reader, Modifier.weight(1f))
        SiteFace(translation, "Translate", "translate", R.drawable.tablet_site_translate, Modifier.weight(1f))
    }
    Text("This site", Modifier.padding(start = 6.dp, end = 6.dp, top = 12.dp, bottom = 4.dp),
        fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    val density = LocalDensity.current.density
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
    if (snapshot.siteBlocking != null && snapshot.onBlocking != null) {
        val enabled = snapshot.siteBlocking
        val callback = snapshot.onBlocking
        val blocking = rememberSiteAction(state, "blocking", enabled, callback, reduced, animations) {
            state.action(page, reduced, animations, { session.snapshot.siteBlocking == enabled && session.snapshot.onBlocking != null }) {
                callback(!enabled)
            }
        }
        SiteRow(blocking, "Block ads and trackers", if (enabled) "On" else "Off", "blocking",
            if (enabled) R.drawable.tablet_site_shield else R.drawable.tablet_site_shield_off, on = enabled)
    }
    val desktopValue = preferences?.desktop ?: false
    val desktop = rememberSiteAction(state, "desktop", preferences?.desktop, reduced, animations) {
        state.action(page, reduced, animations, { preferences != null && session.snapshot.preferences?.desktop == desktopValue }) {
            controller.desktop(!desktopValue)
        }
    }
    SiteRow(desktop, "Desktop site", if (desktopValue) "On" else "Off", "desktop", R.drawable.tablet_site_desktop, on = desktopValue)
    val zoom = preferences?.zoom ?: 1.0
    val reset = rememberSiteAction(state, "zoom-reset", preferences?.zoom, reduced, animations) {
        state.action(page, reduced, animations, { preferences != null && session.snapshot.preferences?.zoom == zoom }) { controller.zoom(1.0) }
    }
    val out = rememberSiteAction(state, "zoom-out", preferences?.zoom, reduced, animations) {
        state.action(page, reduced, animations, { preferences != null && session.snapshot.preferences?.zoom == zoom && SiteSettingsStore.step(zoom, -1) != null }) {
            SiteSettingsStore.step(zoom, -1)?.let(controller::zoom)
        }
    }
    val into = rememberSiteAction(state, "zoom-in", preferences?.zoom, reduced, animations) {
        state.action(page, reduced, animations, { preferences != null && session.snapshot.preferences?.zoom == zoom && SiteSettingsStore.step(zoom, 1) != null }) {
            SiteSettingsStore.step(zoom, 1)?.let(controller::zoom)
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        SiteRow(reset, "Zoom", "${SiteSettingsStore.percent(zoom)}%", "zoom-reset", R.drawable.tablet_site_zoom,
            modifier = Modifier.weight(1f), description = "Reset Zoom")
        SiteFace(out, "Zoom Out", "zoom-out", R.drawable.tablet_site_zoom_out, Modifier.width(44.dp), small = true)
        SiteFace(into, "Zoom In", "zoom-in", R.drawable.tablet_site_zoom, Modifier.width(44.dp), small = true)
    }
    preferences?.permissions?.forEach { (kind, decision) ->
        val anchor = remember(state, kind, decision, density) { TabletSiteRowAnchor(state, density) }
        val permission = rememberSiteAction(state, "permission", kind, decision, reduced, animations) {
            state.action(page, reduced, animations, { session.snapshot.preferences?.permissions?.get(kind) == decision &&
                session.snapshot.onPermission != null }) { anchor.capture()?.let { state.choose(TabletSiteChoice.Permission(kind, it)) } }
        }
        SiteRow(permission, if (kind == SitePermission.CAMERA) "Camera" else "Microphone", decision.siteWord(),
            "permission-${kind.name.lowercase()}", if (kind == SitePermission.CAMERA) R.drawable.tablet_site_camera else R.drawable.tablet_site_mic,
            on = decision == SiteDecision.ALLOWED, positioned = anchor::positioned)
    }
    }
    HorizontalDivider(Modifier.padding(vertical = 6.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
        val secure = snapshot.connection?.secure == true
        val certificate = rememberSiteAction(state, "certificate", secure, reduced, animations) { state.certificate(reduced, animations) }
        key(certificate) {
            val enabled = certificate.enabled()
            Box(Modifier.height(44.dp).clickable(enabled = enabled) { certificate.perform() }
                .testTag("browser.tablet.site.connection"), contentAlignment = Alignment.Center) {
              Row(Modifier.height(28.dp).then(tabletConcentricPlate(8.0, MaterialTheme.colorScheme.onSurface.copy(alpha = .055f)))
                  .padding(horizontal = 10.dp),
                  verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(painterResource(if (secure) R.drawable.tablet_site_lock else R.drawable.tablet_site_unlock), null, Modifier.size(14.dp),
                    tint = if (secure) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.error)
                Text(if (secure) "Secure" else "Not secure", fontSize = 12.sp, fontWeight = FontWeight.Medium,
                    color = if (secure) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.error)
              }
            }
        }
        Spacer(Modifier.weight(1f))
        val anchor = remember(state, density) { TabletSiteRowAnchor(state, density) }
        val more = rememberSiteAction(state, "more", reduced, animations) {
            state.action(page, reduced, animations) { anchor.capture()?.let { state.choose(TabletSiteChoice.More(it)) } }
        }
        SiteFace(more, "More Site Settings", "more", R.drawable.tablet_site_more, Modifier.width(44.dp), small = true, positioned = anchor::positioned)
    }
}

/** Same Main root: a Menu never takes window focus or reacquires PAGE authority. */
@Composable
private fun TabletSiteChoices(state: BrowserTabletSitePopoverState, originalChoice: TabletSiteChoice,
    controller: BrowserController, reduced: Boolean, animations: Boolean) {
    val snapshot = state.session.snapshot
    val page = PageMenuPage.SITE
    val panel = originalChoice.anchor.frame(state.geometry.width, state.geometry.height,
        if (originalChoice is TabletSiteChoice.Permission) 4 else 1)
    Box(Modifier.fillMaxSize().clickable { state.dismissChoice(originalChoice) }
        .semantics { contentDescription = "Dismiss Site Choices" }.testTag("browser.tablet.site.choices.outside"))
    Surface(Modifier.offset(panel.x.dp, panel.y.dp).size(panel.width.dp, panel.height.dp)
        .testTag("browser.tablet.site.choices"), shape = RoundedCornerShape(12.dp), shadowElevation = 8.dp) {
        Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        if (originalChoice is TabletSiteChoice.Permission) {
            val kind = originalChoice.kind
            val callback = snapshot.onPermission
            SiteDecision.entries.forEach { choice ->
                val option = rememberSiteAction(state, originalChoice, choice, callback, reduced, animations) {
                    state.action(page, reduced, animations, { state.choiceCurrent(originalChoice) && callback != null }) {
                        state.dismissChoice(originalChoice); callback?.invoke(kind, choice)
                    }
                }
                SiteChoiceRow(option, choice.siteWord(), "decision-${kind.name.lowercase()}-${choice.name.lowercase()}")
            }
            val forget = rememberSiteAction(state, originalChoice, "forget", callback, reduced, animations) {
                state.action(page, reduced, animations, { state.choiceCurrent(originalChoice) && callback != null }) {
                    state.dismissChoice(originalChoice); callback?.invoke(kind, null)
                }
            }
            SiteChoiceRow(forget, "Forget Permission", "permission-forget")
        } else {
            val settings = rememberSiteAction(state, originalChoice, "settings", reduced, animations) {
                state.action(page, reduced, animations, { state.choiceCurrent(originalChoice) }, true) { controller.show(BrowserSurface.SETTINGS) }
            }
            SiteChoiceRow(settings, "Yab Settings…", "settings")
        }
        }
    }
}

@Composable
private fun TabletSiteCertificate(state: BrowserTabletSitePopoverState, reduced: Boolean, animations: Boolean) {
    val connection = state.session.snapshot.connection
    val back = rememberSiteAction(state, "certificate-back", reduced, animations) { state.certificateBack(reduced, animations) }
    Column(Modifier.padding(horizontal = 6.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SiteChoiceRow(back, "Site Controls", "certificate-back", R.drawable.tablet_site_back)
        if (connection != null && connection.secure) {
            Text(if (!connection.exception) "The connection to ${connection.host} is encrypted, and its certificate is valid."
                else "Certificate details for ${connection.host}.", fontSize = 12.5.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Column {
                SiteFact("Issued to", connection.subject ?: connection.host)
                connection.issuer?.let { HorizontalDivider(); SiteFact("Issued by", it) }
                connection.validUntil?.let { HorizontalDivider(); SiteFact("Valid until", DateFormat.getDateInstance().format(Date(it))) }
            }
        }
    }
}

@Composable
private fun SiteFace(action: TabletSiteAction, words: String, tag: String,
    icon: Int, modifier: Modifier, small: Boolean = false, positioned: ((LayoutCoordinates) -> Unit)? = null) {
    key(action) {
        val enabled = action.enabled()
        Box(modifier.onGloballyPositioned { positioned?.invoke(it) }.height(44.dp)
            .then(if (small) Modifier else tabletConcentricPlate(12.0,
                MaterialTheme.colorScheme.onSurface.copy(alpha = .055f), clip = true))
            .clickable(enabled = enabled) { action.perform() }.testTag("browser.tablet.site.$tag")
            .semantics { contentDescription = words }.graphicsLayer { alpha = if (enabled) 1f else .38f },
            contentAlignment = Alignment.Center) {
            if (small) Box(Modifier.size(28.dp).then(tabletConcentricPlate(8.0,
                MaterialTheme.colorScheme.onSurface.copy(alpha = .055f))), contentAlignment = Alignment.Center) {
                Icon(painterResource(icon), null, Modifier.size(14.dp))
            } else Icon(painterResource(icon), null, Modifier.size(16.dp))
        }
    }
}

@Composable
private fun SiteRow(action: TabletSiteAction, title: String, subtitle: String, tag: String,
    icon: Int, modifier: Modifier = Modifier, on: Boolean = false,
    description: String = title, positioned: ((LayoutCoordinates) -> Unit)? = null) {
    key(action) {
        val enabled = action.enabled()
        Row(modifier.onGloballyPositioned { positioned?.invoke(it) }.fillMaxWidth().heightIn(min = 44.dp).clickable(enabled = enabled) { action.perform() }
            .padding(horizontal = 6.dp).testTag("browser.tablet.site.$tag")
            .semantics { contentDescription = description; stateDescription = subtitle }
            .graphicsLayer { alpha = if (enabled) 1f else .38f },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.size(28.dp).background(if (on) MaterialTheme.colorScheme.onSurface else
                MaterialTheme.colorScheme.onSurface.copy(alpha = .055f), CircleShape), contentAlignment = Alignment.Center) {
                Icon(painterResource(icon), null, Modifier.size(15.dp), tint = if (on) MaterialTheme.colorScheme.surface else MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(title, fontSize = 12.5.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(subtitle, fontSize = 11.5.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
            }
        }
    }
}

@Composable
private fun SiteChoiceRow(action: TabletSiteAction, words: String, tag: String,
    icon: Int? = null) {
    key(action) {
        val enabled = action.enabled()
        Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable(enabled = enabled) { action.perform() }
            .testTag("browser.tablet.site.$tag").padding(horizontal = 6.dp)
            .graphicsLayer { alpha = if (enabled) 1f else .38f }, verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            icon?.let { Icon(painterResource(it), null, Modifier.size(14.dp)) }
            Text(words, fontSize = 12.5.sp, fontWeight = FontWeight.Medium)
        }
    }
}

@Composable
private fun SiteFact(name: String, value: String) {
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(name, fontSize = 12.5.sp)
        Text(value, Modifier.weight(1f), fontSize = 12.5.sp, maxLines = 1, overflow = TextOverflow.MiddleEllipsis,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun SiteDecision.siteWord() = name.lowercase().replaceFirstChar(Char::titlecase)
