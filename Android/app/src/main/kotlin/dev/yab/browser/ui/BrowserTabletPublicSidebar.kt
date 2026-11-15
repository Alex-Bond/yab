package dev.yab.browser.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.browser.model.BrowserFolder
import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.TabPlace

/** Accepted-command redraw only. This is not an authority, frame counter or clock.
 * A fresh composition may capture new actions only from this same current control. */
internal class BrowserTabletSidebarRenderState(private val control: BrowserTabletSidebarControl) {
    var revision by mutableLongStateOf(0L)
        private set
    fun tab(tab: BrowserTab): BrowserTabletSidebarRenderedAction? = bind(control.tab(tab))
    fun folder(folder: BrowserFolder): BrowserTabletSidebarRenderedAction? = bind(control.folder(folder))
    fun clearToday(): BrowserTabletSidebarRenderedAction? = bind(control.clearToday())
    fun newTab(): BrowserTabletSidebarRenderedAction? = bind(control.newTab())
    fun settings(): BrowserTabletSidebarRenderedAction? = bind(control.settings())
    fun space(target: BrowserSpace): BrowserTabletSidebarRenderedAction? = bind(control.space(target))
    private fun bind(action: BrowserTabletSidebarAction?): BrowserTabletSidebarRenderedAction? = action?.let {
        BrowserTabletSidebarRenderedAction(it) { revision++ }
    }
}

internal class BrowserTabletSidebarRenderedAction(private val original: BrowserTabletSidebarAction,
    private val accepted: () -> Unit) {
    fun current(): Boolean = original.current()
    fun retire() = original.retire()
    fun perform(): Boolean {
        if (!original.perform()) return false
        accepted()
        return true
    }
}

internal data class BrowserTabletSidebarRow(val folder: BrowserFolder? = null,
    val tab: BrowserTab? = null, val depth: Int = 0)

internal enum class BrowserTabletSidebarSection {
    PINS, KEPT_CAPTION, KEPT_FOLDER, KEPT_TAB, TODAY_CAPTION, TODAY_TAB, TODAY_EMPTY, PAIR, NEW_TAB
}

/** Bundle-saveable keys with separate section, optional ID and duplicate-index fields.
 * Length-delimited IDs cannot impersonate another field or a static row. */
internal fun browserTabletSidebarKey(section: BrowserTabletSidebarSection, id: String? = null,
    duplicateIndex: Int? = null): String =
    "${section.name}|${if (id == null) "N" else "I${id.length}:$id"}|${duplicateIndex?.let { "D$it" } ?: "N"}"

internal fun browserTabletSidebarKeys(targets: List<Pair<BrowserTabletSidebarSection, String>>): List<String> {
    val counts = targets.groupingBy { it }.eachCount()
    return targets.mapIndexed { index, target ->
        browserTabletSidebarKey(target.first, target.second, index.takeIf { counts[target] != 1 })
    }
}

/** The existing public kept-tree projection, with cycles/orphans bounded by visited IDs.
 * It supplies display rows only; every action still needs the original unique78 target. */
internal fun browserTabletSidebarRows(space: BrowserSpace): List<BrowserTabletSidebarRow> {
    val rows = mutableListOf<BrowserTabletSidebarRow>()
    val visited = mutableSetOf<String>()
    val represented = mutableSetOf<String>()
    fun walk(parent: String?, depth: Int) {
        space.folders.filter { it.parentId == parent }.forEach { folder ->
            if (visited.add(folder.id)) {
                rows += BrowserTabletSidebarRow(folder = folder, depth = depth)
                if (folder.open && depth < 20) walk(folder.id, depth + 1) else {
                    fun mark(id: String) {
                        space.tabs.filter { !it.isPrivate && it.place == TabPlace.KEPT && it.folderId == id }.forEach { represented += it.id }
                        space.folders.filter { it.parentId == id && it.id !in visited }.forEach { visited += it.id; mark(it.id) }
                    }
                    mark(folder.id)
                }
            }
        }
        space.tabs.filter { !it.isPrivate && it.place == TabPlace.KEPT && it.folderId == parent }.forEach {
            rows += BrowserTabletSidebarRow(tab = it, depth = depth); represented += it.id
        }
    }
    walk(null, 0)
    space.tabs.filter { !it.isPrivate && it.place == TabPlace.KEPT && it.id !in represented }.forEach {
        rows += BrowserTabletSidebarRow(tab = it)
    }
    return rows
}

/** Only the actual selected public PAGE's content. No Controller, fake Field/SPACES,
 * pager, capsule, Private/Chats/Mac rows, hold menu or hidden capability capture. */
@Composable
@OptIn(ExperimentalFoundationApi::class)
internal fun BrowserTabletPublicSidebar(control: BrowserTabletSidebarControl, modifier: Modifier = Modifier, drawingOnly: Boolean = false) {
    val space = control.space
    DisposableEffect(control) { onDispose { control.retire() } }
    key(space.id) {
        // Scroll survives fresh action/control bindings for this same public space.
        val scroll = rememberLazyListState()
        val pinsScroll = rememberScrollState()
        val render = remember(control, drawingOnly) { if (drawingOnly) null else BrowserTabletSidebarRenderState(control) }
        val redraw = render?.revision ?: 0L
        if (drawingOnly || control.current()) {
        val pins = space.tabs.filter { !it.isPrivate && it.place == TabPlace.PINNED }
        val pair = control.pair
        val today = space.tabs.filter { !it.isPrivate && it.place == TabPlace.TODAY && !it.isBlank }
        val unpairedToday = today.filter { tab -> pair.none { it.id == tab.id } }
        val kept = browserTabletSidebarRows(space)
        val keptKeys = browserTabletSidebarKeys(kept.map { row ->
            row.folder?.let { BrowserTabletSidebarSection.KEPT_FOLDER to it.id }
                ?: (BrowserTabletSidebarSection.KEPT_TAB to checkNotNull(row.tab).id)
        })
        val todayKeys = browserTabletSidebarKeys(unpairedToday.map { BrowserTabletSidebarSection.TODAY_TAB to it.id })
        val reduced = LocalBrowserAccessibility.current.reduceMotion
        val folderMove = browserFolderMove(space.id, space.folders.filter { it.open }.map { it.id }.toSet())
        Column(modifier.fillMaxSize().then(if (drawingOnly) Modifier.clearAndSetSemantics {} else Modifier)) {
        LazyColumn(Modifier.weight(1f).fillMaxWidth().clipToBounds()
            .then(if (drawingOnly) Modifier.clearAndSetSemantics {} else Modifier).testTag("browser.tablet.sidebar")
            .padding(horizontal = 10.dp), state = scroll, userScrollEnabled = !drawingOnly, contentPadding = PaddingValues(top = 8.dp, bottom = 16.dp)) {
            if (pins.isNotEmpty()) item(key = browserTabletSidebarKey(BrowserTabletSidebarSection.PINS)) {
                Column(Modifier.fillMaxWidth().padding(bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    pins.chunked(4).forEach { group -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                        group.forEach { tab -> key(tab.id) {
                            val click = remember(render, redraw, tab) { render?.tab(tab) }
                            DisposableEffect(click) { onDispose { click?.retire() } }
                            key(click) {
                                Surface(Modifier.weight(1f).height(48.dp).testTag("browser.tablet.sidebar.pin.${tab.id}")
                                    .then(if (drawingOnly) Modifier else Modifier.clickable(enabled = click?.current() == true) { click?.perform() }),
                                    shape = RoundedCornerShape(10.dp), color = MaterialTheme.colorScheme.surface.copy(alpha = if (tab.id == space.currentTabId) .95f else .5f)) {
                                    Box(contentAlignment = Alignment.Center) { BrowserFavicon(tab, 24.dp) }
                                }
                            }
                        } }
                        repeat(4 - group.size) { Spacer(Modifier.weight(1f)) }
                    } }
                }
            }

            itemsIndexed(kept, key = { index, _ -> keptKeys[index] }) { _, row ->
                val movement = Modifier.animateItem(fadeInSpec = BrowserMotion.rowIn(reduced),
                    placementSpec = folderMove?.let { BrowserMotion.folderRows(it, reduced) } ?: BrowserMotion.rowPlacement(reduced), fadeOutSpec = BrowserMotion.rowOut(reduced))
                val folder = row.folder
                if (folder != null) {
                    val click = remember(render, redraw, folder) { render?.folder(folder) }
                    DisposableEffect(click) { onDispose { click?.retire() } }
                    Box(movement) { key(click) {
                        Row(Modifier.fillMaxWidth().testTag("browser.tablet.sidebar.folder.${folder.id}")
                            .then(if (drawingOnly) Modifier else Modifier.clickable(enabled = click?.current() == true) { click?.perform() })
                            .heightIn(min = 44.dp).padding(start = (10 + row.depth * 16).dp, end = 10.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            BrowserSpaceFolderMark(folder, space, MaterialTheme.colorScheme.background.luminance() < .2f, 17.dp)
                            Text(folder.name, Modifier.weight(1f).padding(start = 10.dp), fontSize = 13.5.sp)
                            Icon(if (folder.open) YabGlyphs.ChevronDownSmall else YabGlyphs.ChevronRight, null, Modifier.size(18.dp))
                        }
                    } }
                } else row.tab?.let { tab ->
                    TabletSidebarTab(tab, tab.id == space.currentTabId, render, redraw,
                        movement.padding(start = (row.depth * 16).dp))
                }
            }
            item(key = browserTabletSidebarKey(BrowserTabletSidebarSection.TODAY_CAPTION)) {
                Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (today.isNotEmpty()) HorizontalDivider(Modifier.weight(1f).padding(end = 10.dp), thickness = .5.dp) else Spacer(Modifier.weight(1f))
                    if (today.isNotEmpty()) {
                        val click = remember(render, redraw) { render?.clearToday() }
                        DisposableEffect(click) { onDispose { click?.retire() } }
                        key(click) { TabletSidebarCommand(drawingOnly, click,
                            Modifier.testTag("browser.tablet.sidebar.clear")) { Text("Clear", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) } }
                    }
                }
            }
            if (pair.size == 2) item(key = browserTabletSidebarKey(BrowserTabletSidebarSection.PAIR)) {
                Row(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface.copy(alpha = .85f), RoundedCornerShape(8.dp))
                    .padding(horizontal = 4.dp).testTag("browser.tablet.sidebar.pair"), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    pair.forEach { tab -> key(tab.id) {
                        val click = remember(render, redraw, tab) { render?.tab(tab) }
                        DisposableEffect(click) { onDispose { click?.retire() } }
                        key(click) { Row(Modifier.weight(1f).height(44.dp).padding(vertical = 4.dp)
                            .clip(RoundedCornerShape(5.dp)).background(MaterialTheme.colorScheme.onSurface.copy(alpha = .07f))
                            .testTag("browser.tablet.sidebar.pair.${tab.id}")
                            .then(if (drawingOnly) Modifier else Modifier.clickable(enabled = click?.current() == true, role = Role.Button) { click?.perform() }
                                .semantics { selected = tab.id == space.currentTabId })
                            .padding(horizontal = 6.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                            BrowserFavicon(tab, 15.dp)
                            Text(tab.shortTitle, Modifier.weight(1f), fontSize = 12.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        } }
                    } }
                }
            }
            itemsIndexed(unpairedToday, key = { index, _ -> todayKeys[index] }) { _, tab ->
                TabletSidebarTab(tab, tab.id == space.currentTabId, render, redraw,
                    Modifier.animateItem(fadeInSpec = BrowserMotion.rowIn(reduced),
                        placementSpec = folderMove?.let { BrowserMotion.folderRows(it, reduced) } ?: BrowserMotion.rowPlacement(reduced), fadeOutSpec = BrowserMotion.rowOut(reduced)))
            }
        }
        HorizontalDivider(thickness = .5.dp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .1f))
        TabletSidebarFooter(control, space, render, redraw, drawingOnly)

        }
        }
    }
}

/** A stable footer owns its children across PAGE/control rebinding. Individual
 * action nodes remain keyed so a pointer cannot migrate to a replacement action. */
@Composable
private fun TabletSidebarFooter(control: BrowserTabletSidebarControl, space: BrowserSpace,
    render: BrowserTabletSidebarRenderState?, redraw: Long, drawingOnly: Boolean) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            val settings = remember(render, redraw) { render?.settings() }
            val newTab = remember(render, redraw) { render?.newTab() }
            DisposableEffect(settings, newTab) { onDispose { settings?.retire(); newTab?.retire() } }
            Box(Modifier.size(44.dp)) {
                key(settings) { TabletSidebarCommand(drawingOnly, settings, Modifier.fillMaxSize().testTag("browser.tablet.sidebar.settings")) {
                    Icon(YabGlyphs.SettingsGear1, "Settings", Modifier.size(17.dp))
                } }
            }
            Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                control.spaces.forEach { item -> key(item.id) {
                    val click = remember(render, redraw, item) { render?.space(item) }
                    DisposableEffect(click) { onDispose { click?.retire() } }
                    Box(Modifier.size(44.dp)) { key(click) { Box(Modifier.fillMaxSize().clip(RoundedCornerShape(8.dp))
                        .background(if (item.id == space.id) MaterialTheme.colorScheme.surface.copy(alpha = .8f) else Color.Transparent)
                        .testTag("browser.tablet.sidebar.space.${item.id}")
                        .then(if (drawingOnly) Modifier else Modifier.clickable(enabled = click?.current() == true, role = Role.Button) { click?.perform() }
                            .semantics { contentDescription = item.name; selected = item.id == space.id }), contentAlignment = Alignment.Center) {
                        if (item.emoji.isNotEmpty()) Text(item.emoji, fontSize = 17.sp)
                        else Box(Modifier.size(10.dp).background(MaterialTheme.colorScheme.onSurface, CircleShape))
                    } }
                } } }
            }
            Box(Modifier.size(44.dp)) {
                key(newTab) { TabletSidebarCommand(drawingOnly, newTab, Modifier.fillMaxSize().testTag("browser.tablet.sidebar.new-tab")) {
                    Icon(YabGlyphs.PlusMedium, "New Tab", Modifier.size(18.dp))
                } }
            }
        }
}

@Composable
private fun TabletSidebarTab(tab: BrowserTab, selected: Boolean, render: BrowserTabletSidebarRenderState?,
    redraw: Long, modifier: Modifier = Modifier) {
    val click = remember(render, redraw, tab) { render?.tab(tab) }
    DisposableEffect(click) { onDispose { click?.retire() } }
    Box(modifier) { key(click) {
        Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).clip(RoundedCornerShape(8.dp))
            .background(if (selected) MaterialTheme.colorScheme.surface.copy(alpha = .85f) else Color.Transparent)
            .testTag("browser.tablet.sidebar.tab.${tab.id}")
            .then(if (render == null) Modifier else Modifier.clickable(enabled = click?.current() == true) { click?.perform() })
            .padding(horizontal = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            BrowserFavicon(tab, 17.dp)
            Text(tab.shortTitle, Modifier.weight(1f).padding(start = 10.dp), fontSize = 13.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    } }
}

/** Covered/hidden pixels have no button/pointer node, not merely enabled=false. */
@Composable
private fun TabletSidebarCommand(drawingOnly: Boolean, click: BrowserTabletSidebarRenderedAction?,
    modifier: Modifier, content: @Composable RowScope.() -> Unit) {
    if (drawingOnly) Row(modifier.minimumInteractiveComponentSize().defaultMinSize(ButtonDefaults.MinWidth, ButtonDefaults.MinHeight)
        .padding(ButtonDefaults.TextButtonContentPadding), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center) {
        CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurface) {
            ProvideTextStyle(MaterialTheme.typography.labelLarge) { content() }
        }
    } else TextButton(enabled = click?.current() == true, onClick = { click?.perform() }, modifier = modifier,
        contentPadding = PaddingValues(0.dp), colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurface), content = content)
}

@Composable
private fun TabletSidebarCaption(title: String, modifier: Modifier = Modifier) {
    Text(title, modifier.padding(horizontal = 8.dp, vertical = 4.dp), fontSize = 12.sp,
        fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurfaceVariant)
}
