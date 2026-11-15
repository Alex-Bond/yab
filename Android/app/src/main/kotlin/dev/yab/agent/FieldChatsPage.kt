package dev.yab.agent

import dev.yab.browser.ui.YabGlyphs

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Caller-owned content for fieldChatsContent(Modifier, effective).
 * chats is already account/Private/search/archive filtered and ordered.
 * current must retain the original immutable source lease, not resolve today's owner.
 * The callbacks must perform their own fresh source/chat CAS before any effect.
 * This component opens no repository collector, request, image loader or coroutine.
 */
@Composable
fun FieldChatsPage(
    chats: List<AgentChat>, query: String, archived: Boolean, sourceKey: Any,
    enabled: Boolean, current: () -> Boolean,
    onSelect: (AgentChat) -> Unit, onNewChat: () -> Unit, onArchive: (Boolean) -> Unit,
    canAct: (AgentChat, FieldChatAction) -> Boolean, onAction: (FieldChatCommand) -> Unit,
    deleteQuestion: (AgentChat) -> FieldChatDeleteQuestion,
    modifier: Modifier = Modifier, macNames: Map<String, String> = emptyMap(),
    now: Long = System.currentTimeMillis(), showArchiveControl: Boolean = true,
    projects: List<dev.yab.core.sync.SyncProject> = emptyList(), projectKey: Any = Unit,
    onProject: (dev.yab.core.sync.SyncProject) -> Unit = {},
    moveProjectContent: (@Composable (AgentChat, () -> Boolean) -> Unit)? = null,
): Unit = key(sourceKey, projectKey) {
    var projectPhase by remember { mutableLongStateOf(0) }
    val originalPhase = projectPhase
    val originalCurrent = remember { current }
    val latestEnabled by rememberUpdatedState(enabled)
    val latestChats by rememberUpdatedState(chats)
    val latestCanAct by rememberUpdatedState(canAct)
    fun owns() = runCatching(originalCurrent).getOrDefault(false) && (moveProjectContent == null || projectPhase == originalPhase)
    fun available(chat: AgentChat? = null): Boolean = latestEnabled && owns() &&
        (chat == null || latestChats.any { FieldChatsPageModel.sameOwner(it, chat) })
    fun allowed(chat: AgentChat, action: FieldChatAction) = available(chat) && runCatching { latestCanAct(chat, action) }.getOrDefault(false)
    if (runCatching(originalCurrent).getOrDefault(false)) {
    MaterialTheme(colorScheme = chatColorScheme(), shapes = chatShapes()) {
    ProjectMenuRoot(moveProjectContent != null) {
    var open by remember { mutableStateOf(emptySet<FieldChatGroupId>()) }
    var pending by remember { mutableStateOf<FieldChatCommand?>(null) }
    var rename by remember { mutableStateOf("") }
    val trimmed = query.trim()
    val groupedProjects = if (trimmed.isEmpty() && !archived) projects.filterNot { it.archived } else emptyList()
    val knownProjects = groupedProjects.map { it.id }.toSet()
    val loose = chats.filter { it.project !in knownProjects }
    val groups = FieldChatGroups.read(loose, searching = trimmed.isNotEmpty(), archived = archived)
    fun perform(command: FieldChatCommand) {
        if (command.sourceKey == sourceKey && allowed(command.chat, command.action) &&
            command.older.all { row -> allowed(row, FieldChatAction.ARCHIVE) }) onAction(command)
    }
    // On the spaces' foot: New Chat stands in the foot bar, the archive in the three dots.
    val footRoom = dev.yab.browser.ui.LocalSpacesFootRoom.current
    LazyColumn(modifier.fillMaxSize().drawWithContent { if (owns()) drawContent() }.testTag("newtab.chats"),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = footRoom ?: 16.dp),
        verticalArrangement = Arrangement.spacedBy(0.dp)) {
        if (footRoom == null || archived) item("head") {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                if (archived) Text("Archived", Modifier.weight(1f).padding(horizontal = 8.dp, vertical = 8.dp).semantics { heading() },
                    style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                else if (trimmed.isEmpty()) Row(Modifier.weight(1f).heightIn(min = 56.dp).clip(RoundedCornerShape(22.dp))
                    .clickable(enabled = enabled, onClick = { if (available()) onNewChat() }).padding(8.dp)
                    .testTag("newtab.chats.new"), verticalAlignment = Alignment.CenterVertically) {
                    Icon(YabGlyphs.MacSquareAndPencil, null, Modifier.size(34.dp).background(MaterialTheme.colorScheme.onSurface.copy(alpha = .08f), CircleShape).padding(6.dp))
                    Spacer(Modifier.width(12.dp)); Text("New Chat", fontSize = 16.sp, lineHeight = 20.sp, fontWeight = FontWeight.SemiBold)
                } else Spacer(Modifier.weight(1f))
                if (showArchiveControl && footRoom == null) TextButton(onClick = { if (available()) onArchive(!archived) }, enabled = enabled) {
                    Text(if (archived) "Chats" else "Archive")
                }
            }
        }
        if (groupedProjects.any { it.pinned }) item("projects/pinned") {
            ProjectPins(groupedProjects.filter { it.pinned }, chats, enabled = enabled,
                current = { available() }, open = { if (available()) onProject(it) })
        }
        for (group in groups) {
            if (group.id != FieldChatGroupId.CHATS) item("head/${group.id}") {
                val expanded = group.id in open
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                    .clickable(enabled = enabled) { if (available()) open = if (expanded) open - group.id else open + group.id }
                    .padding(start = 8.dp, end = 8.dp, top = 18.dp, bottom = 6.dp)
                    .testTag("newtab.chats.group.${group.id.name.lowercase()}")
                    .semantics { stateDescription = if (expanded) "open" else "folded" },
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(group.id.title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("${group.chats.size}", Modifier.padding(start = 6.dp), style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.weight(1f)); Icon(if (expanded) YabGlyphs.ChevronDownSmall else YabGlyphs.ChevronRight, null, Modifier.size(14.dp))
                }
            }
            if (group.id == FieldChatGroupId.CHATS || group.id in open) {
                val cards = if (group.id == FieldChatGroupId.CHATS) FieldChatGroups.projectCards(group.chats, chats, groupedProjects)
                    else group.chats.map { FieldProjectCard.Chat(it) }
                itemsIndexed(cards.chunked(2), key = { _, it -> "${group.id}/" + when (val first = it.first()) {
                    is FieldProjectCard.Chat -> "chat/${first.chat.id}"
                    is FieldProjectCard.Project -> "project/${first.project.id}"
                } }) { rowIndex, pair ->
                    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).padding(top = if (rowIndex == 0) 12.dp else 22.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        for (card in pair) when (card) {
                        is FieldProjectCard.Project -> key(card.project.id, projectKey) {
                            ProjectPageCard(card.project, card.chats, Modifier.weight(1f).fillMaxHeight(), enabled,
                                current = { available() }, open = { if (available()) onProject(card.project) })
                        }
                        is FieldProjectCard.Chat -> key(card.chat.id, card.chat.owner, card.chat.privateOrigin) {
                            val chat = card.chat
                            FieldChatCard(chat, modifier = Modifier.weight(1f).fillMaxHeight(), enabled = enabled,
                                leaving = pending?.older?.any { FieldChatsPageModel.sameOwner(it, chat) } == true,
                                status = FieldChatsPageModel.status(chat, macNames, now), active = { available(chat) },
                                select = { if (available(chat)) onSelect(chat) },
                                allowed = { allowed(chat, it) }, command = { action ->
                                    val command = FieldChatCommand(sourceKey, chat, action,
                                        older = if (action == FieldChatAction.ARCHIVE_OLDER) FieldChatsPageModel.older(chat, group.chats) else emptyList())
                                    if (allowed(chat, action)) when (action) {
                                        FieldChatAction.RENAME -> { rename = chat.title; pending = command }
                                        FieldChatAction.DELETE, FieldChatAction.ARCHIVE_OLDER -> pending = command
                                        else -> perform(command)
                                    }
                                }, hasOlder = FieldChatsPageModel.older(chat, group.chats).isNotEmpty(),
                                moveProjectContent = moveProjectContent?.let { content -> { content(chat) { available(chat) } } },
                                projectPhase = originalPhase, onProjectPhase = { projectPhase++ })
                        }
                        }
                        if (pair.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            }
        }
        if (chats.isEmpty() && groupedProjects.isEmpty()) item("empty") {
            Text(if (archived) if (trimmed.isEmpty()) "No archived chats." else "No archived chats with “$trimmed”."
                else if (trimmed.isEmpty()) "No chats yet." else "No chats with “$trimmed”.",
                Modifier.padding(horizontal = 8.dp, vertical = 16.dp), style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    pending?.takeIf { allowed(it.chat, it.action) }?.let { captured ->
        ProjectAlertDialog(owned = moveProjectContent != null, current = ::owns, sourceKey = listOf(originalPhase, projectKey, pending),
            onDismissRequest = { if (owns()) { projectPhase++; pending = null } }, modifier = Modifier.drawWithContent { if (owns()) drawContent() }, title = { Text(when (captured.action) {
            FieldChatAction.RENAME -> "Rename Chat"
            FieldChatAction.DELETE -> deleteQuestion(captured.chat).title
            else -> if (captured.older.size == 1) "Archive 1 older chat?" else "Archive ${captured.older.size} older chats?"
        }) }, text = {
            if (captured.action == FieldChatAction.RENAME) OutlinedTextField(rename, { if (available(captured.chat)) rename = it },
                singleLine = true, label = { Text("Name") })
            else if (captured.action == FieldChatAction.DELETE) deleteQuestion(captured.chat).detail?.let { Text(it) }
        }, confirmButton = {
            TextButton(onClick = { if (owns()) {
                val command = if (captured.action == FieldChatAction.RENAME) captured.copy(title = rename.trim().take(300)) else captured
                if (command.action != FieldChatAction.RENAME || !command.title.isNullOrBlank()) perform(command)
                projectPhase++; pending = null
            } }, enabled = enabled && (captured.action != FieldChatAction.RENAME || rename.isNotBlank())) {
                Text(when (captured.action) { FieldChatAction.RENAME -> "Rename"; FieldChatAction.DELETE -> "Delete Chat"; else -> "Archive" })
            }
        }, dismissButton = { TextButton(onClick = { if (owns()) { projectPhase++; pending = null } }) { Text("Cancel") } })
    }
    }
    }
}

}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FieldChatCard(chat: AgentChat, modifier: Modifier, enabled: Boolean, leaving: Boolean, status: String,
    active: () -> Boolean, select: () -> Unit, allowed: (FieldChatAction) -> Boolean,
    command: (FieldChatAction) -> Unit, hasOlder: Boolean, moveProjectContent: (@Composable () -> Unit)? = null,
    projectPhase: Long = 0, onProjectPhase: () -> Unit = {}) {
    var menu by remember { ProjectLocalState(false) { if (moveProjectContent != null) onProjectPhase() } }
    val shape = RoundedCornerShape(22.dp)
    val sites = remember(chat.id, chat.messages) { ChatContents.read(chat, sitesInEncounterOrder = true).sites }
    Box(modifier) {
        repeat(if (sites.size >= 3) 2 else if (sites.isNotEmpty()) 1 else 0) { index ->
            Box(Modifier.fillMaxWidth().padding(horizontal = (7 + index * 6).dp).height(40.dp).offset(y = (-6 * (index + 1)).dp)
                .background(MaterialTheme.colorScheme.surfaceContainerLow.copy(alpha = if (index == 0) .75f else .5f), shape)
                .border(.5.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = .06f), shape))
        }
        Column(Modifier.fillMaxWidth().heightIn(min = 150.dp).clip(shape)
            .background(MaterialTheme.colorScheme.surfaceContainerLow.copy(alpha = if (leaving) .4f else 1f))
            .combinedClickable(enabled = enabled, onClickLabel = "Open Chat", onLongClickLabel = "Chat Actions",
                onClick = { if (active()) select() }, onLongClick = { if (active()) menu = true })
            .semantics { customActions = listOf(CustomAccessibilityAction("Chat Actions") { if (active()) { menu = true; true } else false }) }
            .padding(14.dp).testTag("newtab.chat.${chat.id}"), verticalArrangement = Arrangement.spacedBy(0.dp)) {
            if (sites.isEmpty()) ChatRowMark(chat) else Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                sites.take(3).forEach { ChatSiteMark(it.url, 20.dp, chat.privateOrigin) }
                Text(if (sites.size == 1) "1 site" else "${sites.size} sites", Modifier.padding(start = 2.dp), fontSize = 12.sp, lineHeight = 14.4.sp, color = chatGray(.72f))
            }
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(chat.title, Modifier.weight(1f), fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                if (chat.unread) Box(Modifier.size(7.dp).background(MaterialTheme.colorScheme.primary, CircleShape))
            }
            Spacer(Modifier.height(8.dp))
            Text(FieldChatsPageModel.preview(chat), Modifier.padding(bottom = 10.dp), fontSize = 13.sp, lineHeight = 18.sp, maxLines = 3, overflow = TextOverflow.Ellipsis,
                color = chatGray(.72f))
            Spacer(Modifier.weight(1f))
            Text(status, fontSize = 12.sp, lineHeight = 16.sp, color = if (FieldChatsPageModel.working(chat)) MaterialTheme.colorScheme.primary else chatGray(.5f))
        }
        ProjectDropdownMenu(expanded = menu && active(), onDismissRequest = { if (active()) menu = false },
            owned = moveProjectContent != null, current = active, sourceKey = projectPhase,
            modifier = Modifier.drawWithContent { if (active()) drawContent() }) {
            DropdownMenuItem(text = { Text("Open Chat") }, onClick = { if (active()) { select(); menu = false } }, enabled = enabled)
            if (FieldChatsPageModel.answer(chat) != null) FieldChatActionRow("Copy Answer", FieldChatAction.COPY_ANSWER, allowed) { if (active()) { command(it); menu = false } }
            HorizontalDivider()
            FieldChatActionRow(if (chat.pinned) "Unpin Chat" else "Pin Chat", if (chat.pinned) FieldChatAction.UNPIN else FieldChatAction.PIN, allowed) { if (active()) { command(it); menu = false } }
            FieldChatActionRow(if (chat.unread) "Mark as Read" else "Mark as Unread", if (chat.unread) FieldChatAction.MARK_READ else FieldChatAction.MARK_UNREAD, allowed) { if (active()) { command(it); menu = false } }
            moveProjectContent?.invoke()
            FieldChatActionRow("Rename Chat…", FieldChatAction.RENAME, allowed) { if (active()) { command(it); menu = false } }
            FieldChatActionRow(if (chat.archived) "Unarchive Chat" else "Archive Chat", if (chat.archived) FieldChatAction.UNARCHIVE else FieldChatAction.ARCHIVE, allowed) { if (active()) { command(it); menu = false } }
            if (!chat.archived && hasOlder) FieldChatActionRow("Archive Older…", FieldChatAction.ARCHIVE_OLDER, allowed) { if (active()) { command(it); menu = false } }
            if (FieldChatsPageModel.working(chat) && allowed(FieldChatAction.STOP)) FieldChatActionRow("Stop", FieldChatAction.STOP, allowed) { if (active()) { command(it); menu = false } }
        }
    }
}

@Composable
private fun FieldChatActionRow(title: String, action: FieldChatAction, allowed: (FieldChatAction) -> Boolean, perform: (FieldChatAction) -> Unit) {
    DropdownMenuItem(text = { Text(title) }, enabled = allowed(action), onClick = { if (allowed(action)) perform(action) })
}
