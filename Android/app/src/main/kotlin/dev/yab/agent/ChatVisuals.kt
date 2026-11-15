package dev.yab.agent

import kotlin.math.roundToInt

import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import dev.yab.browser.ui.YabGlyphs

/** Phone Metrics.Chats. Android system insets and keyboard remain native. */
internal object ChatVisuals {
    val blue = Color(0xFF0088FF)
    val edge = 16.dp
    val face = 44.dp
    val header = 104.dp
    val field = 40.dp
}

@Composable
internal fun ChatFace(size: Dp, modifier: Modifier = Modifier, onDevice: Boolean = false) {
    val dark = MaterialTheme.colorScheme.background.luminance() < .2f
    val fill = if (dark) Color(if (size >= 88.dp) 0xFF2B2B2B else 0xFF333333) else if (size >= 88.dp) Color.White else Color(0xFFF1F1F3)
    Box(modifier.size(size).background(fill, CircleShape), contentAlignment = Alignment.Center) {
        Icon(if (onDevice) YabGlyphs.Sparkle else YabGlyphs.MacAgentFace, null,
            Modifier.size(size * if (onDevice) .61f else .91f), tint = MaterialTheme.colorScheme.onSurface)
    }
}

@Composable
internal fun ChatRoundButton(description: String, icon: ImageVector, onClick: () -> Unit, modifier: Modifier = Modifier, buttonTag: String? = null, glass: Boolean = false) {
    val dark = MaterialTheme.colorScheme.background.luminance() < .2f
    Surface(modifier.size(44.dp), shape = CircleShape,
        color = if (glass) if (dark) Color(0xFF29292C).copy(alpha = .92f) else Color.White.copy(alpha = .86f) else chatFill(.12f),
        shadowElevation = if (glass) 8.dp else 0.dp,
        border = if (glass) BorderStroke(.5.dp, Color.White.copy(alpha = if (dark) .12f else .7f)) else null) {
        IconButton(onClick = onClick, modifier = if (buttonTag == null) Modifier else Modifier.testTag(buttonTag)) { Icon(icon, description, Modifier.size(20.dp)) }
    }
}

@Composable
internal fun ConversationHeader(title: String, unread: Int, onBack: () -> Unit, onInfo: () -> Unit, onDevice: Boolean = false, face: (@Composable () -> Unit)? = null, backTag: String = "chat.back", titleTag: String = "chat.title",
    menu: @Composable () -> Unit) {
    Box(Modifier.fillMaxWidth().height(ChatVisuals.header).testTag("chat.header")) {
        Row(Modifier.fillMaxWidth().padding(horizontal = ChatVisuals.edge).padding(top = 10.dp),
            horizontalArrangement = Arrangement.SpaceBetween) {
            Surface(shape = CircleShape, color = chatFill(.12f)) {
                Row(Modifier.height(44.dp).widthIn(min = 44.dp).clickable(onClick = onBack).padding(horizontal = 10.dp)
                    .testTag(backTag).semantics { contentDescription = "Back to Chats" }, verticalAlignment = Alignment.CenterVertically) {
                    Icon(YabGlyphs.ChevronLeft, null, Modifier.size(20.dp))
                    if (unread > 0) Text(if (unread > 99) "99+" else "$unread", Modifier.padding(start = 6.dp)
                        .background(MaterialTheme.colorScheme.onSurface, CircleShape).padding(horizontal = 7.dp, vertical = 2.dp),
                        color = MaterialTheme.colorScheme.surface, fontSize = 13.sp)
                }
            }
            menu()
        }
        Box(Modifier.align(Alignment.TopCenter).padding(top = 6.dp).clickable(onClick = onInfo).testTag(titleTag)) {
            Surface(Modifier.padding(top = 36.dp).height(29.dp).widthIn(max = 200.dp), shape = CircleShape,
                color = chatFill(.12f)) {
                Box(Modifier.padding(horizontal = 12.dp), contentAlignment = Alignment.Center) {
                    Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 15.sp)
                }
            }
            Box(Modifier.align(Alignment.TopCenter)) { if (face == null) ChatFace(44.dp, onDevice = onDevice) else face() }
        }
    }
}

@Composable
internal fun ConversationComposer(text: String, onText: (String) -> Unit, onSend: () -> Unit, enabled: Boolean,
    focus: FocusRequester, placeholder: String = "Ask a follow-up…", attachments: (@Composable () -> Unit)? = null,
    editorTag: String = "chat.composer", sendTag: String = "chat.send", glass: Boolean = false,
    horizontalInset: Dp? = null, bottomInset: Dp? = null) {
    val keyboard = WindowInsets.ime.getBottom(LocalDensity.current) > 0
    val navigation = with(LocalDensity.current) { WindowInsets.navigationBars.getBottom(this).toDp() }
    Surface(Modifier.fillMaxWidth().padding(horizontal = horizontalInset ?: if (keyboard) 16.dp else 29.dp).padding(top = 8.dp, bottom = bottomInset ?: if (keyboard) 16.dp else (27.dp - navigation).coerceAtLeast(0.dp)),
        shape = RoundedCornerShape(22.dp), color = if (glass) MaterialTheme.colorScheme.surface.copy(alpha = .86f) else chatFill(.12f),
        border = if (glass) BorderStroke(.5.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = .08f)) else null) {
        Row(Modifier.heightIn(min = 44.dp).padding(6.dp), verticalAlignment = Alignment.Bottom) {
            attachments?.invoke()
            BasicTextField(text, onText, Modifier.weight(1f).padding(horizontal = 10.dp, vertical = 5.dp)
                .focusRequester(focus).testTag(editorTag).semantics { contentDescription = "Message" },
                textStyle = TextStyle(color = MaterialTheme.colorScheme.onSurface, fontSize = 17.sp, lineHeight = 22.sp),
                maxLines = 6, cursorBrush = SolidColor(ChatVisuals.blue), decorationBox = { editor ->
                    Box { if (text.isEmpty()) Text(placeholder, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 17.sp); editor() }
                })
            if (text.isNotBlank()) Surface(Modifier.size(32.dp), shape = CircleShape, color = ChatVisuals.blue) {
                IconButton(onClick = onSend, enabled = enabled, modifier = Modifier.size(32.dp).testTag(sendTag)) {
                    Icon(YabGlyphs.ArrowUp, "Send", Modifier.size(19.dp), tint = Color.White)
                }
            }
        }
    }
}

/** The same hook as Phone MessageBubble, inside the edge and five points below. */
internal class ConversationBubble(private val mine: Boolean, private val tail: Boolean) : Shape {
    override fun createOutline(size: androidx.compose.ui.geometry.Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val radius = with(density) { 20.dp.toPx() }.coerceAtMost(size.height / 2)
        val body = Path().apply { addRoundRect(androidx.compose.ui.geometry.RoundRect(
            0f, 0f, size.width, size.height, androidx.compose.ui.geometry.CornerRadius(radius))) }
        if (tail) {
            val scale = density.density
            fun x(value: Float) = if (mine) size.width + value * scale else -value * scale
            fun y(value: Float) = size.height + value * scale
            val hook = Path().apply {
                moveTo(x(-22f), y(-2f))
                cubicTo(x(-13f), y(1.5f), x(-6f), y(5f), x(-1f), y(5f))
                cubicTo(x(-1.5f), y(-1f), x(-2.5f), y(-5f), x(-2.5f), y(-12f)); close()
            }
            return Outline.Generic(Path.combine(PathOperation.Union, body, hook))
        }
        return Outline.Generic(body)
    }
}


@Composable
internal fun ChatSearchField(text: String, onText: (String) -> Unit, modifier: Modifier = Modifier) {
    Row(modifier.heightIn(min = 44.dp).background(chatFill(.12f), CircleShape)
        .padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(YabGlyphs.MagnifyingGlass, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        BasicTextField(text, onText, Modifier.weight(1f).padding(start = 8.dp).testTag("chat.search")
            .semantics { contentDescription = "Search chats" }, singleLine = true,
            textStyle = TextStyle(color = MaterialTheme.colorScheme.onSurface, fontSize = 17.sp),
            cursorBrush = SolidColor(ChatVisuals.blue), decorationBox = { editor ->
                Box { if (text.isEmpty()) Text("Search", fontSize = 17.sp, color = MaterialTheme.colorScheme.onSurfaceVariant); editor() }
            })
    }
}

/** Keep one LazyColumn item per message so restoration still refers to the original message id. */
@Composable
internal fun ConversationMessageBody(message: AgentMessage, tail: Boolean, dark: Boolean, streaming: Boolean,
    open: (String) -> Unit, retry: (String) -> Unit, selecting: Boolean = false, onHeld: (() -> Unit)? = null) {
    val user = message.role == MessageRole.USER
    val fill = if (user) ChatVisuals.blue else if (dark) Color(0xFF262628) else Color(0xFFE9E9EB)
    val blocks = if (message.role in setOf(MessageRole.ASSISTANT, MessageRole.WORK)) AgentMarkdown.blocks(message.text, streaming) else emptyList()
    if (message.files.isNotEmpty() || message.handed != null) Column(Modifier.background(fill, RoundedCornerShape(22.dp)).padding(14.dp)) {
        for (file in message.files) {
            Text("${file.name} · ${file.size / 1000} KB", color = if (user) Color.White else MaterialTheme.colorScheme.onSurface)
            if (file.mime.startsWith("image/")) ChatImage(file)
        }
        message.handed?.let { Text(it.title); Text(it.detail); Text(it.from, style = MaterialTheme.typography.labelSmall) }
    }
    if (blocks.isNotEmpty()) AgentMarkdown.parts(blocks).forEachIndexed { partIndex, indices ->
        val panel = blocks[indices.first()].kind in setOf(AgentMarkdown.Kind.CODE, AgentMarkdown.Kind.TABLE)
        val last = indices.last() == blocks.lastIndex
        val gap = if (last) 0.dp else if (panel) 4.dp else 2.dp
        MessageSelection(selecting, Modifier.padding(bottom = gap).testTag("chat.block.${message.id}.${indices.first()}")) {
            if (panel) AgentMarkdownBlockText(blocks[indices.first()], open, onHeld, selecting)
            else Column(Modifier.widthIn(max = minOf(560.dp, androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp.dp - 72.dp))
                .background(fill, ConversationBubble(false, tail && last && message.cards.isEmpty()))
                .padding(horizontal = 14.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                for (index in indices) AgentMarkdownBlockText(blocks[index], open, onHeld, selecting)
            }
        }
    } else if (message.text.isNotBlank()) MessageSelection(selecting) {
        Text(message.text, Modifier.widthIn(max = minOf(if (user) 290.dp else 560.dp, androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp.dp - 72.dp)).background(fill, ConversationBubble(user, tail)).padding(horizontal = 14.dp, vertical = 8.dp),
            fontSize = 17.sp, lineHeight = 22.sp, letterSpacing = 0.sp,
            color = if (user) Color.White else if (message.role == MessageRole.FAILURE) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
    }
    ChatResultCards(message.cards, open)
    message.work?.let { ChatWorkView(it, retry) }
}


@Composable
internal fun ChatRowMark(chat: AgentChat, size: Dp = 34.dp, modifier: Modifier = Modifier) {
    val task = chat.origin != null
    val dark = MaterialTheme.colorScheme.background.luminance() < .2f
    val device = chat.privateOrigin || chat.messages.lastOrNull { it.role == MessageRole.ASSISTANT }?.origin == AnswerOrigin.DEVICE
    val mark = when {
        device -> YabGlyphs.BrandAppleIntelligence
        chat.owner?.provider == AgentProvider.CODEX -> YabGlyphs.BrandOpenAI
        else -> YabGlyphs.BrandClaude
    }
    Box(modifier.size(size).background(Color(0xFF767680).copy(alpha = (if (task) .1f else .08f) * (if (dark) 2f else 1f)), if (task) RoundedCornerShape(10.dp) else CircleShape),
        contentAlignment = Alignment.Center) {
        if (task) dev.yab.browser.ui.BrowserFolderMark(false, 0xFFE2E9F4,
            false, ((size.value * 18f / 34f * 1.08f).roundToInt()).dp)
        else Icon(mark, null, Modifier.size(size * (20f / 34f)), tint = Color(if (dark) 0xFFEBEBF5 else 0xFF3C3C43).copy(alpha = .62f))
    }
}


@Composable
internal fun chatColorScheme(): ColorScheme {
    val dark = MaterialTheme.colorScheme.background.luminance() < .2f
    return MaterialTheme.colorScheme.copy(
        primary = ChatVisuals.blue, background = if (dark) Color.Black else Color(0xFFFAFAFC),
        surface = if (dark) Color(0xFF1C1C1E) else Color.White,
        surfaceContainerLow = if (dark) Color(0xFF1C1C1E) else Color.White,
        surfaceContainer = if (dark) Color(0xFF1C1C1E) else Color.White,
        surfaceContainerHigh = if (dark) Color(0xFF2C2C2E) else Color(0xFFF2F2F4),
        surfaceContainerHighest = if (dark) Color(0xFF2C2C2E) else Color(0xFFF2F2F4), surfaceTint = Color.Transparent,
        onSurface = if (dark) Color(0xFFF2F2F7) else Color(0xFF1C1C1E), onSurfaceVariant = (if (dark) Color(0xFFEBEBF5) else Color(0xFF3C3C43)).copy(alpha = .6f))
}


@Composable
private fun MessageSelection(enabled: Boolean, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    if (enabled) SelectionContainer(modifier, content = content) else Box(modifier) { content() }
}

@Composable
internal fun chatShapes() = MaterialTheme.shapes.copy(extraSmall = RoundedCornerShape(22.dp),
    small = RoundedCornerShape(22.dp), medium = RoundedCornerShape(22.dp), large = RoundedCornerShape(24.dp))


@Composable
internal fun chatFill(alpha: Float): Color = Color(0xFF767680).copy(alpha =
    if (MaterialTheme.colorScheme.background.luminance() < .2f) (alpha * 2).coerceAtMost(1f) else alpha)

@Composable
internal fun chatGray(alpha: Float): Color = (if (MaterialTheme.colorScheme.background.luminance() < .2f) Color(0xFFEBEBF5) else Color(0xFF3C3C43)).copy(alpha = alpha)
