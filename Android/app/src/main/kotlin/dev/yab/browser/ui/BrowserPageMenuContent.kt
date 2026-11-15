package dev.yab.browser.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.browser.engine.*
import dev.yab.browser.model.*
import java.text.DateFormat
import java.util.Date

/** Only refreshed while this exact source is still owned; no replacement selected-tab callback. */
internal data class PageMenuContentSnapshot(val tab: BrowserTab, val page: EnginePageState,
    val preferences: SitePreferences?, val connection: SiteConnection?, val siteBlocking: Boolean?,
    val blockingStatus: String?, val onBlocking: ((Boolean) -> Unit)?,
    val onPermission: ((SitePermission, SiteDecision?) -> Unit)?, val readerThemeTitle: String? = null,
    val translationMenu: BrowserPageTranslationUi? = null)

internal enum class PageMenuWorkspaceAction(val title: String) {
    OPEN_BESIDE("Open Beside"), FULL_SPREAD("Full Spread"), CLOSE_PAGE("Close Page")
}

/** One menu opening's original workspace source. Front metadata keeps the same page identity;
 * neither a recomposition, a saved press nor landing can capture a replacement. */
internal class PageMenuWorkspaceActions private constructor(private val controller: BrowserController,
    val lease: WorkspaceActionLease, private val originalCurrent: () -> Boolean) {
    private val rows = if (lease.entry.workspace == null) listOf(PageMenuWorkspaceAction.OPEN_BESIDE)
        else PageMenuWorkspaceAction.entries.toList()
    private fun current(): Boolean = originalCurrent() && controller.workspaceActionsCurrent(lease)
    fun available(): List<PageMenuWorkspaceAction> = if (current()) rows else emptyList()
    fun perform(scope: BrowserPageMenuScope, action: PageMenuWorkspaceAction): Boolean {
        if (action !in rows || !current()) return false
        return scope.perform(afterLanding = true) {
            if (current()) when (action) {
                PageMenuWorkspaceAction.OPEN_BESIDE -> controller.newTabBeside(lease)
                PageMenuWorkspaceAction.FULL_SPREAD -> controller.fullSpread(lease)
                PageMenuWorkspaceAction.CLOSE_PAGE -> controller.closeWorkspacePage(lease)
            }
        }
    }
    companion object {
        fun capture(controller: BrowserController, current: () -> Boolean): PageMenuWorkspaceActions? {
            if (!current()) return null
            val entry = controller.captureWorkspaceEntry() ?: return null
            val lease = controller.captureWorkspaceActions(entry) ?: return null
            return PageMenuWorkspaceActions(controller, lease, current).takeIf { it.current() }
        }
    }
}

internal class BrowserPageMenuSession(val lease: PageMenuLease, val url: String,
    val geometry: BrowserPageMenuGeometry, val pane: SpacesRect, val root: SpacesRect, initial: PageMenuContentSnapshot,
    val workspaceActions: PageMenuWorkspaceActions? = null) {
    var snapshot by mutableStateOf(initial)
    lateinit var entry: BrowserPageMenuEntry
    var copies by mutableIntStateOf(0)
    fun update(next: PageMenuContentSnapshot, current: () -> Boolean): Boolean {
        if (next.tab.id != lease.tab || next.tab.url != url || !current()) return false
        snapshot = next; return true
    }
}

internal fun makePageMenuSession(lease: PageMenuLease, geometry: BrowserPageMenuGeometry,
    pane: SpacesRect, root: SpacesRect, initial: PageMenuContentSnapshot, controller: BrowserController, context: Context,
    current: () -> Boolean, closing: (PageMenuLease) -> Unit, released: (PageMenuLease, PageMenuRelease) -> Unit,
    reopened: (PageMenuLease) -> Unit,
    onAsk: ((BrowserTab) -> Unit)?, onTranslate: (() -> Unit)?, onMac: ((PageMenuLease, BrowserTab) -> Unit)?,
    onExtensions: (() -> Unit)?, editAddress: ((PageMenuRect) -> Boolean)? = null,
    onReaderSettings: (() -> Unit)? = null): BrowserPageMenuSession {
    val workspaceActions = PageMenuWorkspaceActions.capture(controller, current)
    val session = BrowserPageMenuSession(lease, initial.tab.url, geometry, pane, root, initial, workspaceActions)
    session.entry = BrowserPageMenuEntry(lease, current, closing, released,
        // Distance-only is explicit until a measured platform prediction adapter is qualified.
        // Do not turn an assumed friction constant into a claim about SwiftUI's predicted end.
        predictedEndY = { translation, _ -> translation },
        background = { modifier, pose -> Surface(modifier, shape = RoundedCornerShape(pose.radius.dp),
            color = MaterialTheme.colorScheme.surface, tonalElevation = 0.dp, shadowElevation = 8.dp) {} },
        address = { scope, modifier -> PageMenuAddress(session, controller, context, scope, modifier) },
        menu = { scope -> PageMenuRows(session, controller, context, scope, onAsk, onTranslate, onMac, onExtensions, onReaderSettings) },
        site = { scope -> PageMenuSite(session, controller, scope) },
        certificate = { scope -> PageMenuCertificate(session, scope) }, reopened = reopened, editAddress = editAddress)
    return session
}

@Composable
internal fun PageMenuAddress(session: BrowserPageMenuSession, controller: BrowserController,
    context: Context, scope: BrowserPageMenuScope, modifier: Modifier) {
    val state = session.snapshot
    val pose = scope.pose
    fun menuAction(action: () -> Unit) {
        if (session.entry.presentation.frame.value.site == 0.0) scope.perform { action() }
    }
    Surface(modifier, shape = CircleShape, color = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Box(Modifier.fillMaxSize()) {
            Icon(YabGlyphs.PlateLines, null, Modifier.offset(x = 15.dp, y = ((pose.row.height - 22) / 2).dp)
                .size(22.dp).graphicsLayer { alpha = pose.plateLines.toFloat() })
            IconButton(enabled = scope.enabled && state.page.canGoBack && pose.extras > .5,
                onClick = { menuAction { controller.back() } },
                modifier = Modifier.offset(x = 1.dp).width(44.dp).fillMaxHeight().graphicsLayer { alpha = pose.extras.toFloat() }) {
                Icon(YabGlyphs.ChevronLeft, "Back")
            }
            IconButton(enabled = scope.enabled && state.page.canGoForward && pose.extras > .5,
                onClick = { menuAction { controller.forward() } },
                modifier = Modifier.offset(x = 39.dp).width(44.dp).fillMaxHeight().graphicsLayer { alpha = pose.extras.toFloat() }) {
                Icon(YabGlyphs.ChevronRight, "Forward")
            }
            val failed = state.page.error != null
            val hint = if (!failed && (state.page.readerAvailable || state.page.readerEnabled)) pose.plateLines else 0.0
            val failure = if (failed) ((pose.progress - .3) / .5).coerceIn(0.0, 1.0) * (1 - pose.site) else 0.0
            Column(Modifier.offset(x = ((pose.row.width - pose.hostRoom) / 2).dp).width(pose.hostRoom.dp).fillMaxHeight()
                .clickable(enabled = scope.enabled) {
                    if (scope.supportsFieldHandoff) scope.editAddress()
                    else scope.perform(afterLanding = true) { controller.openField(newTab = false) }
                }
                .semantics { contentDescription = "Edit address" }, verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally) {
                Text(if (scope.page == PageMenuPage.CERTIFICATE) "Certificate" else state.tab.host,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = (16 + pose.site).sp,
                    letterSpacing = (-.3).sp, fontWeight = if (pose.site < .5) FontWeight.Normal else FontWeight.SemiBold)
                if (hint > 0 || failure > 0) Box(Modifier.height((15 * hint + 16 * failure).dp)) {
                    Text(if (failed) "Can't open this page" else if (state.page.readerEnabled) "Reader" else "Reader Available",
                        maxLines = 1, fontSize = 12.sp, modifier = Modifier.graphicsLayer { alpha = (if (failed) failure else hint).toFloat() })
                }
            }
            IconButton(enabled = scope.enabled && pose.extras > .5, onClick = {
                menuAction { copyLink(context, session.url); session.copies++; controller.message("Link copied") }
            }, modifier = Modifier.offset(x = (pose.row.width - 86.5).dp).width(44.dp).fillMaxHeight()
                .graphicsLayer { alpha = pose.extras.toFloat() }) {
                Icon(if (session.copies > 0) YabGlyphs.Checkmark1Small else YabGlyphs.ChainLink1, if (session.copies > 0) "Copied" else "Copy Link")
            }
            IconButton(enabled = scope.enabled && pose.site == 0.0,
                onClick = { menuAction { controller.reloadOrStop() } },
                modifier = Modifier.offset(x = (pose.row.width - 48 - pose.progress).dp).width(44.dp).fillMaxHeight()
                    .graphicsLayer { alpha = (1 - (pose.site * 2).coerceIn(0.0, 1.0)).toFloat() }) {
                Icon(if (state.page.loading) YabGlyphs.CrossMedium else YabGlyphs.ArrowRotateClockwise, if (state.page.loading) "Stop Loading" else "Reload Page")
            }
        }
    }
    if (pose.site > 0) IconButton(enabled = scope.enabled && pose.site > .9,
        onClick = {
            if (session.entry.presentation.frame.value.site > .9) scope.back()
        }, modifier = Modifier.offset(pose.headerBack.x.dp, pose.headerBack.y.dp).size(44.dp)
            .graphicsLayer { alpha = pose.headerBackOpacity.toFloat(); scaleX = pose.headerBackScale.toFloat(); scaleY = scaleX }) {
        Icon(YabGlyphs.ChevronLeft, "Back")
    }
}

@Composable
internal fun PageMenuRows(session: BrowserPageMenuSession, controller: BrowserController, context: Context,
    scope: BrowserPageMenuScope, onAsk: ((BrowserTab) -> Unit)?, onTranslate: (() -> Unit)?,
    onMac: ((PageMenuLease, BrowserTab) -> Unit)?, onExtensions: (() -> Unit)?, onReaderSettings: (() -> Unit)? = null) {
    val snapshot = session.snapshot
    val tab = snapshot.tab
    Column(Modifier.padding(horizontal = 14.dp).padding(bottom = 16.dp)) {
        Row(Modifier.menuBlock(scope, 0).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (!session.lease.profile.isPrivate && onAsk != null) PageMenuTile("Ask", YabGlyphs.MacYabChatSpark,
                scope.enabled, modifier = Modifier.weight(1f)) { scope.perform(afterLanding = true) { onAsk(tab) } }
            PageMenuTile("Find on Page", YabGlyphs.MacYabPageSearch, scope.enabled && !snapshot.page.loading,
                modifier = Modifier.weight(1f)) { scope.perform(afterLanding = true) { controller.beginFind() } }
            if (!session.lease.profile.isPrivate) PageMenuTile(if (tab.place == TabPlace.KEPT) "Kept" else "Keep",
                YabGlyphs.MacYabAnchor, scope.enabled && tab.place != TabPlace.PINNED,
                selected = tab.place == TabPlace.KEPT, modifier = Modifier.weight(1f)) {
                scope.perform { if (tab.place == TabPlace.KEPT) controller.unkeepTab(tab.id) else controller.keepTab(tab.id) }
            }
            PageMenuTile("Share", YabGlyphs.ShareOs, scope.enabled, modifier = Modifier.weight(1f)) {
                scope.perform(afterLanding = true) { shareLink(context, session.url) }
            }
        }
        Spacer(Modifier.height(24.dp))
        PageMenuCard(Modifier.menuBlock(scope, 1)) {
            session.workspaceActions?.let { actions ->
                key(actions.lease) { actions.available().forEach { action ->
                    key(action) {
                        val icon = when (action) {
                            PageMenuWorkspaceAction.OPEN_BESIDE -> YabGlyphs.TabletSplitView
                            PageMenuWorkspaceAction.FULL_SPREAD -> YabGlyphs.Expand45
                            PageMenuWorkspaceAction.CLOSE_PAGE -> YabGlyphs.CrossMedium
                        }
                        PageMenuLine(action.title, icon, action = if (scope.enabled) ({ actions.perform(scope, action); Unit }) else null)
                        PageMenuDivider()
                    }
                } }
            }
            val noReader = !snapshot.page.loading && !snapshot.page.readerAvailable && !snapshot.page.readerEnabled
            PageMenuLine(if (snapshot.page.readerEnabled) "Exit Reader" else "Reader", YabGlyphs.MacYabBookopen,
                subtitle = if (snapshot.page.loading) "Loading…" else if (noReader) "No article here" else null,
                grayed = snapshot.page.loading || noReader,
                action = if (scope.enabled && !snapshot.page.loading && !noReader) ({ scope.perform(true) { controller.reader() }; Unit }) else null)
            if (snapshot.page.readerEnabled && onReaderSettings != null) {
                PageMenuDivider()
                PageMenuLine("Themes & Settings", YabGlyphs.MacYabText, subtitle = snapshot.readerThemeTitle,
                    action = if (scope.enabled) ({ scope.perform(true) { onReaderSettings() }; Unit }) else null)
            }
            val translation = snapshot.translationMenu
            if (translation != null) {
                val reader = snapshot.page.readerEnabled
                PageMenuDivider()
                PageMenuLine(translation.title, YabGlyphs.MacYabTranslate,
                    subtitle = if (reader) "Exit Reader to translate" else translation.subtitle, grayed = reader,
                    action = if (scope.enabled && !reader) ({ scope.perform(true) { translation.onToggle() }; Unit }) else null)
                if (translation.showAlways) {
                    PageMenuDivider()
                    PageMenuLine(translation.alwaysTitle, YabGlyphs.MacYabTranslate,
                        action = if (scope.enabled) ({ scope.perform { translation.onAlways() }; Unit }) else null) {
                        if (translation.checked) Icon(YabGlyphs.Checkmark1Small, "Selected", Modifier.size(18.dp))
                    }
                }
            } else if (onTranslate != null && !snapshot.page.readerEnabled) {
                PageMenuDivider(); menuAction("Translate Page", YabGlyphs.MacYabTranslate, scope, true, action = onTranslate)
            }
            PageMenuDivider()
            PageMenuZoom(snapshot.preferences?.zoom ?: 1.0, scope, controller)
            PageMenuDivider()
            menuAction(if (snapshot.preferences?.desktop == true) "Request Mobile Site" else "Request Desktop Site",
                if (snapshot.preferences?.desktop == true) YabGlyphs.MacYabIphone else YabGlyphs.Imac, scope, true) {
                controller.desktop(snapshot.preferences?.desktop != true)
            }
            if (!session.lease.profile.isPrivate && onMac != null && session.lease.account != null && session.lease.device != null) {
                PageMenuDivider(); menuAction("Open on Mac", YabGlyphs.MacYabLaptopRight, scope, true) { onMac(session.lease, tab) }
            }
        }
        if (!session.lease.profile.isPrivate && onExtensions != null) {
            Spacer(Modifier.height(12.dp))
            PageMenuCard { menuAction("Extensions", YabGlyphs.MacPuzzlepieceExtension, scope, true, action = onExtensions) }
        }
        if (snapshot.preferences != null) {
            Spacer(Modifier.height(12.dp))
            PageMenuCard(Modifier.menuBlock(scope, 2)) {
                PageMenuLine("Site Settings", YabGlyphs.MacSliderHorizontal2Square,
                    action = if (scope.enabled) ({ scope.navigate(PageMenuPage.SITE) }) else null)
            }
        }
    }
}

@Composable
internal fun PageMenuSite(session: BrowserPageMenuSession, controller: BrowserController, scope: BrowserPageMenuScope) {
    val snapshot = session.snapshot
    val preferences = snapshot.preferences ?: return
    Column(Modifier.padding(horizontal = 14.dp).padding(bottom = 16.dp)) {
        PageMenuCard(site = true) {
            PageMenuZoom(preferences.zoom, scope, controller, compact = true)
            PageMenuDivider(site = true)
            PageMenuLine("Request Desktop Site", YabGlyphs.Imac, tile = Color(0xFF30B0C7)) {
                SettingsSwitch(preferences.desktop, change = { value -> scope.perform { controller.desktop(value) } }, enabled = scope.enabled)
            }
            if (snapshot.siteBlocking != null) {
                PageMenuDivider(site = true)
                PageMenuLine("Block Ads and Trackers", YabGlyphs.ShieldCheck, tile = Color(0xFF34C759)) {
                    SettingsSwitch(snapshot.siteBlocking, change = { checked -> scope.perform { snapshot.onBlocking?.invoke(checked) } },
                        enabled = scope.enabled && snapshot.onBlocking != null)
                }
            }
        }
        if (preferences.permissions.isNotEmpty()) {
            Text("ALLOWED HERE", Modifier.padding(start = 10.dp, top = 14.dp, bottom = 6.dp), fontSize = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            PageMenuCard(site = true) {
                preferences.permissions.entries.sortedBy { it.key.ordinal }.forEachIndexed { index, (kind, decision) ->
                    if (index > 0) PageMenuDivider(site = true)
                    var choices by remember(session.entry, kind) { mutableStateOf(false) }
                    val title = if (kind == SitePermission.CAMERA) "Camera" else "Microphone"
                    PageMenuLine(title, if (kind == SitePermission.CAMERA) YabGlyphs.Camera1 else YabGlyphs.Microphone,
                        tile = if (kind == SitePermission.CAMERA) Color(0xFF34C759) else Color(0xFFFF9500)) {
                        Box {
                            TextButton(enabled = scope.enabled && snapshot.onPermission != null,
                                onClick = { scope.perform { choices = true } }) { Text(when (decision) {
                                    SiteDecision.ASK -> "Ask"; SiteDecision.ALLOWED -> "Allowed"; SiteDecision.OFF -> "Off"
                                }, fontSize = 17.sp, fontWeight = FontWeight.Normal, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                            DropdownMenu(choices && scope.enabled, onDismissRequest = { choices = false }) {
                                SiteDecision.entries.forEach { choice -> DropdownMenuItem(text = { Text(when (choice) {
                                    SiteDecision.ASK -> "Ask"; SiteDecision.ALLOWED -> "Allowed"; SiteDecision.OFF -> "Off"
                                }) }, onClick = { choices = false; scope.perform { snapshot.onPermission?.invoke(kind, choice) } }) }
                            }
                        }
                        IconButton(enabled = scope.enabled && snapshot.onPermission != null,
                            onClick = { choices = false; scope.perform { snapshot.onPermission?.invoke(kind, null) } },
                            modifier = Modifier.width(32.dp)) { Icon(YabGlyphs.CrossMedium, "Forget $title", Modifier.size(14.dp)) }
                    }
                }
            }
        }
        Spacer(Modifier.height(if (preferences.permissions.isEmpty()) 14.dp else 12.dp))
        PageMenuCard(site = true) {
            val secure = snapshot.connection?.secure == true
            PageMenuLine(if (secure) "Connection is secure" else "Not secure", YabGlyphs.Lock,
                tile = if (secure) Color(0xFF34C759) else Color(0xFFFF3B30), chevron = secure, destructive = !secure,
                action = if (secure && scope.enabled) ({ scope.navigate(PageMenuPage.CERTIFICATE) }) else null)
        }
        Spacer(Modifier.height(12.dp))
        PageMenuCard(site = true) {
            PageMenuLine("Yab Settings", YabGlyphs.SettingsGear1, tile = Color(0xFF8E8E93), chevron = true,
                action = if (scope.enabled) ({ scope.perform(afterLanding = true) { controller.show(BrowserSurface.SETTINGS) }; Unit }) else null)
        }
    }
}

@Composable
internal fun PageMenuCertificate(session: BrowserPageMenuSession, scope: BrowserPageMenuScope) {
    val connection = session.snapshot.connection?.takeIf { it.secure } ?: return
    Column(Modifier.padding(horizontal = 14.dp).padding(bottom = 16.dp)) {
        Text(if (connection.exception) "This page uses a security exception." else "The connection to ${connection.host} is encrypted.",
            Modifier.padding(horizontal = 10.dp).padding(bottom = 14.dp), fontSize = 15.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        PageMenuCard(site = true) {
            @Composable fun fact(title: String, value: String) {
                Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(title, fontSize = 17.sp)
                    Spacer(Modifier.width(12.dp))
                    Text(value, Modifier.weight(1f), fontSize = 17.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = androidx.compose.ui.text.style.TextAlign.End, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
            fact("Issued to", connection.subject ?: connection.host)
            connection.issuer?.let { PageMenuDivider(); fact("Issued by", it) }
            connection.validUntil?.let { PageMenuDivider(); fact("Valid until", DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(it))) }
        }
    }
}

@Composable
private fun PageMenuZoom(zoom: Double, scope: BrowserPageMenuScope, controller: BrowserController, compact: Boolean = false) {
    val ink = MaterialTheme.colorScheme.onSurface
    val dark = ink.luminance() > .5f
    PageMenuLine("Page Zoom", if (compact) YabGlyphs.TextSize else YabGlyphs.MacYabZoomin,
        tile = if (compact) Color(0xFF007AFF) else null, modifier = Modifier.testTag("browser.page.zoom")) {
        Row(Modifier.clip(RoundedCornerShape(12.dp))
            .background(if (compact) Color.Transparent else if (dark) Color.White.copy(alpha = .12f) else Color.Black.copy(alpha = .07f))
            .testTag("browser.page.zoom.stepper"), verticalAlignment = Alignment.CenterVertically) {
            PageZoomButton("−", "Zoom Out", scope.enabled && SiteSettingsStore.step(zoom, -1) != null, compact = compact) {
                scope.perform { SiteSettingsStore.step(zoom, -1)?.let(controller::zoom) }
            }
            PageZoomButton("${SiteSettingsStore.percent(zoom)} %", "Page Zoom ${SiteSettingsStore.percent(zoom)} percent",
                scope.enabled, percent = true, secondary = zoom == 1.0, compact = compact) { scope.perform { controller.zoom(1.0) } }
            PageZoomButton("+", "Zoom In", scope.enabled && SiteSettingsStore.step(zoom, 1) != null, compact = compact) {
                scope.perform { SiteSettingsStore.step(zoom, 1)?.let(controller::zoom) }
            }
        }
    }
}

@Composable
private fun PageZoomButton(title: String, label: String, enabled: Boolean, percent: Boolean = false,
    secondary: Boolean = false, compact: Boolean = false, action: () -> Unit) {
    val ink = if (secondary) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface
    Box(Modifier.size(if (compact) { if (percent) 52.dp else 32.dp } else 40.dp, if (compact) 32.dp else 38.dp).clickable(enabled = enabled, role = Role.Button, onClick = action)
        .semantics { contentDescription = label }, contentAlignment = Alignment.Center) {
        Text(title, fontSize = (if (compact) { if (percent) 15 else 17 } else if (percent) 13 else 20).sp,
            fontWeight = if (percent && !compact) FontWeight.SemiBold else FontWeight.Medium,
            fontFamily = if (percent) FontFamily.Monospace else FontFamily.Default,
            color = ink.copy(alpha = if (enabled) 1f else .38f), maxLines = 1)
    }
}

@Composable
private fun menuAction(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector,
    scope: BrowserPageMenuScope, afterLanding: Boolean = false, enabled: Boolean = true, action: () -> Unit) {
    PageMenuLine(title, icon, action = if (scope.enabled && enabled) ({ scope.perform(afterLanding) { action() }; Unit }) else null)
}

private fun Modifier.menuBlock(scope: BrowserPageMenuScope, index: Int) = graphicsLayer {
    val fraction = scope.pose.block(index)
    alpha = fraction.toFloat(); translationY = (10 * (1 - fraction) * density).toFloat()
}
