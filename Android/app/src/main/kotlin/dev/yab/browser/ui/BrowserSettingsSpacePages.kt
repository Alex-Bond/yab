package dev.yab.browser.ui

import android.icu.text.BreakIterator
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.browser.model.*
import kotlinx.coroutines.delay

@Composable
internal fun BrowserSettingsSpacePage(id: String, state: BrowserState, controller: BrowserController,
    host: BrowserSettingsHostState, lease: SettingsPresentationLease, current: () -> Boolean) {
    val space = state.spaces.firstOrNull { it.id == id && !it.isPrivate }
    // The retained host installs its new foreground lease in SideEffect. An
    // earlier null capture must be retried when that handoff becomes current.
    val edit = remember(lease, host.lease, id, current) { controller.captureSettingsSpaceEdit(lease, id, current) }
    fun owned() = edit != null && controller.settingsSpaceEditCurrent(edit)
    var signIns by remember(id) { mutableStateOf<Boolean?>(null) }
    var deleting by remember(id) { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 40.dp)
        .testTag("settings.space.page"), verticalArrangement = Arrangement.spacedBy(22.dp)) {
        if (space == null) Text("This space is no longer available.", Modifier.testTag("settings.space.unavailable"))
        else {
            Column(Modifier.fillMaxWidth().padding(bottom = 18.dp), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                SettingsSpaceTile(space)
                Text(space.name, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold,
                    modifier = Modifier.semantics { heading() }.testTag("settings.page.title"))
                Text("${space.tabs.size} tabs" + if (state.selectedSpaceId == id) " · on screen" else "", style = MaterialTheme.typography.bodySmall)
            }
            SettingsSpaceGroup {
                SettingsSpaceRow("Name", space.name, "settings.space.name") { if (owned()) host.push(SettingsDestination.Editor(id, SettingsSpaceStep.NAME)) }
                SettingsSpaceRow("Emoji", SpaceSymbols.emoji(space.emoji), "settings.space.emoji") { if (owned()) host.push(SettingsDestination.Editor(id, SettingsSpaceStep.EMOJI)) }
                SettingsSpaceRow("Color", "Color and grain, each with a deeper shade for dark.", "settings.space.color") {
                    if (owned()) host.push(SettingsDestination.Editor(id, SettingsSpaceStep.COLOR))
                }
            }
            Text("Sign-ins", style = MaterialTheme.typography.labelMedium)
            SettingsSpaceGroup {
                SettingsSpaceRow("Shared", if (!space.ownSignIns) "Selected" else "", "settings.space.shared") { if (owned() && space.ownSignIns) signIns = false }
                SettingsSpaceRow("Its own", if (space.ownSignIns) "Selected" else "", "settings.space.own") { if (owned() && !space.ownSignIns) signIns = true }
            }
            Text(if (space.ownSignIns) "Sign-ins stay in this space." else "Signed in wherever your other public spaces are.", style = MaterialTheme.typography.bodySmall)
            val public = state.spaces.filterNot { it.isPrivate }
            if (public.size > 1 && public.first().id != id) SettingsSpaceGroup {
                SettingsSpaceRow("Delete Space", "", "settings.space.delete") { if (owned()) deleting = true }
            }
        }
    }
    if (signIns != null && owned()) AlertDialog(onDismissRequest = { if (owned()) signIns = null }, title = { Text("Change this space's sign-ins?") },
        text = { Text("Its pages reload using ${if (signIns == true) "separate" else "shared"} website data. Existing website data is kept.") },
        confirmButton = { TextButton(onClick = { if (owned()) { controller.changeSignIns(id, signIns == true); signIns = null } }) { Text("Change Sign-ins") } },
        dismissButton = { TextButton(onClick = { if (owned()) signIns = null }) { Text("Cancel") } })
    if (deleting && owned()) AlertDialog(onDismissRequest = { if (owned()) deleting = false }, title = { Text("Delete Space?") },
        text = { Text("Its tabs close on this device and your other devices.") }, confirmButton = { TextButton(onClick = {
            if (owned()) { controller.deleteSpace(id); deleting = false; host.back() }
        }) { Text("Delete Space") } }, dismissButton = { TextButton(onClick = { if (owned()) deleting = false }) { Text("Cancel") } })
}

@Composable
internal fun BrowserSettingsSpaceEditor(destination: SettingsDestination.Editor, entry: SettingsRouteFrame,
    state: BrowserState, controller: BrowserController, host: BrowserSettingsHostState,
    lease: SettingsPresentationLease, actionCurrent: () -> Boolean) {
    val space = state.spaces.firstOrNull { it.id == destination.id && !it.isPrivate }
    val draft = remember(entry.id) { mutableStateOf(space?.let { SettingsSpaceDraft(it).let { draft ->
        if (destination.namingNew && destination.step == SettingsSpaceStep.NAME) draft.copy(name = "") else draft
    } }) }
    var paintOwner by remember(entry.id) { mutableStateOf<SettingsSpaceEditLease?>(null) }
    // Capture can be null before the retained host installs its new foreground
    // lease, or while the route is suspended. Each handoff needs fresh authority;
    // the draft remains keyed only to the retained route.
    val edit = remember(lease, host.lease, entry.id, actionCurrent, entry.interactive) {
        controller.captureSettingsSpaceEdit(lease, destination.id, actionCurrent)
    }
    fun current() = edit != null && controller.settingsSpaceEditCurrent(edit)
    fun commit(): Boolean {
        val captured = edit ?: return false
        val value = draft.value ?: return false
        if (!controller.commitSettingsSpace(captured, value)) return false
        controller.state.value.spaces.firstOrNull { it.id == destination.id && !it.isPrivate }?.let { draft.value = value.saved(it) }
        return true
    }
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val requester = remember(entry.id) { FocusRequester() }
    fun done() { if (current() && commit()) { focus.clearFocus(); keyboard?.hide(); host.back() } }
    DisposableEffect(host, entry.id, edit) {
        val leave = { if (current()) { commit(); Unit } }
        host.leaveHandlers[entry.id] = leave
        onDispose { if (host.leaveHandlers[entry.id] === leave) host.leaveHandlers.remove(entry.id) }
    }
    LaunchedEffect(edit) { if (destination.step == SettingsSpaceStep.NAME && current()) requester.requestFocus() }
    val value = draft.value
    LaunchedEffect(edit, paintOwner, value?.lookChanged, value?.look?.raw) {
        if (destination.step == SettingsSpaceStep.COLOR && value?.lookChanged == true && paintOwner === edit) {
            delay(120)
            if (paintOwner === edit && current()) commit()
        }
    }
    val dark = MaterialTheme.colorScheme.background.luminance() < .5f
    Box(Modifier.fillMaxSize()) {
    if (destination.step == SettingsSpaceStep.COLOR && value != null)
        BrowserSpaceLookWash(value.look, dark, Modifier.fillMaxSize())
    Column(Modifier.fillMaxSize().testTag("settings.space.editor")) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 40.dp),
            verticalArrangement = Arrangement.spacedBy(22.dp)) {
            Text(destination.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold,
                modifier = Modifier.semantics { heading() }.testTag("settings.page.title"))
            if (space == null || value == null) Text("This space is no longer available.")
            else when (destination.step) {
                SettingsSpaceStep.NAME -> key(edit) { OutlinedTextField(value.name, { if (current()) draft.value = draft.value?.rename(it) },
                    modifier = Modifier.fillMaxWidth().focusRequester(requester).testTag("settings.space.name.input"),
                    singleLine = true, placeholder = { Text("Space name") }, keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { done() })) }
                SettingsSpaceStep.EMOJI -> key(edit) { SettingsSpaceEmojiPicker(value.emoji, current = ::current) { if (current()) draft.value = draft.value?.pick(it) } }
                SettingsSpaceStep.COLOR -> BrowserSpaceLookEditor(edit ?: entry.id, value.look, ::current,
                    change = { if (current()) { paintOwner = edit; draft.value = draft.value?.paint(it) } }, ended = { if (current()) commit() })
            }
            Spacer(Modifier.height(16.dp))
        }
        // Retire the original native action node with its foreground edit owner.
        // A queued old click must not borrow the fresh editor's enabled callback.
        key(edit) {
            Button(onClick = ::done, enabled = current() && !(destination.step == SettingsSpaceStep.NAME && value?.name?.isBlank() != false),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).heightIn(min = 44.dp).testTag("settings.space.done")) { Text("Done") }
        }
    }
    }
}

@Composable
internal fun SettingsSpaceTile(space: BrowserSpace, modifier: Modifier = Modifier) {
    val look = BrowserSpaceLook.from(space.look, space.color)
    val dark = MaterialTheme.colorScheme.background.luminance() < .5f
    val colors = look.displayColors(dark).map { Color(it) }
    Box(modifier.size(56.dp).background(Brush.linearGradient(if (colors.size == 1) colors + colors else colors), RoundedCornerShape(15.dp)), contentAlignment = Alignment.Center) {
        Text(SpaceSymbols.emoji(space.emoji), fontSize = 30.8.sp)
    }
}

@Composable
private fun SettingsSpaceGroup(content: @Composable ColumnScope.() -> Unit) {
    Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainer) { Column(content = content) }
}

@Composable
private fun SettingsSpaceRow(title: String, value: String, tag: String, action: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = action).heightIn(min = 50.dp).padding(12.dp).testTag(tag), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) { Text(title); if (value.isNotEmpty()) Text(value, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        Text("›")
    }
}

private val settingsEmojiChoices = listOf("🌐" to "globe world web", "🏠" to "home personal", "💼" to "work briefcase", "📚" to "books reading",
    "🎨" to "art color design", "🌱" to "plant green garden", "☕️" to "coffee", "🎵" to "music", "🧪" to "science test", "🔭" to "explore telescope",
    "🧳" to "travel luggage", "🏖️" to "beach holiday", "🍳" to "cooking food", "🚲" to "bike sport", "🐈" to "cat animal", "🌙" to "moon night",
    "⭐️" to "star symbol", "❤️" to "heart love symbol", "⚙️" to "gear settings symbol", "🔖" to "bookmark symbol")

@Composable
private fun SettingsSpaceEmojiPicker(selected: String, current: () -> Boolean, pick: (String) -> Unit) {
    var search by remember { mutableStateOf("") }
    OutlinedTextField(search, { if (current()) search = it }, modifier = Modifier.fillMaxWidth().testTag("column.tray.emoji.search"), placeholder = { Text("Search emoji and symbols") }, singleLine = true)
    Text(if (search.isEmpty()) "Suggested" else "Results", style = MaterialTheme.typography.titleSmall)
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val columns = (maxWidth.value / 44).toInt().coerceAtLeast(1)
        Column {
            settingsEmojiChoices.filter { search.isEmpty() || it.second.contains(search, ignoreCase = true) || it.first == search }.chunked(columns).forEach { row ->
                Row { row.forEach { (emoji, words) ->
                    TextButton(onClick = { if (current()) pick(emoji) }, modifier = Modifier.size(44.dp).testTag("column.tray.emoji.pick.$emoji").semantics { this.selected = selected == emoji; contentDescription = words }) { Text(emoji) }
                } }
            }
        }
    }
    Text("You can also enter an emoji with the keyboard.", style = MaterialTheme.typography.bodySmall)
    OutlinedTextField(selected, { value ->
        if (current() && value.isNotEmpty()) {
            val iterator = BreakIterator.getCharacterInstance().apply { setText(value) }
            iterator.first(); val end = iterator.next()
            if (end > 0) pick(value.substring(0, end))
        }
    }, modifier = Modifier.fillMaxWidth().testTag("column.tray.emoji.custom"), placeholder = { Text("Your emoji") }, singleLine = true)
}
