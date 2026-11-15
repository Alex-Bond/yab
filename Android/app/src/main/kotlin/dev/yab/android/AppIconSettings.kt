package dev.yab.android

import dev.yab.browser.ui.YabGlyphs

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.zIndex
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import dev.yab.browser.ui.BrowserMotion
import dev.yab.browser.ui.LocalBrowserAccessibility
import dev.yab.sync.AccountRecordsSnapshot
import dev.yab.sync.SyncIdentityLease
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.time.Instant
import kotlin.math.abs
import kotlin.math.roundToInt

/** An atomic account+epoch+facts key; importing a grant never invokes PackageManager. */
data class AppIconAccountFrame(val account: String?, val device: String?, val epoch: Long, val removed: Boolean,
                               val access: AppIconAccess) {
    companion object {
        fun from(snapshot: AccountRecordsSnapshot) = AppIconAccountFrame(snapshot.account, snapshot.device, snapshot.epoch, snapshot.removed,
            if (snapshot.account == null || snapshot.removed) AppIconAccess() else AppIconAccess.fromRecords(snapshot.records))
    }
}

private val LocalAppIconActionOwner = staticCompositionLocalOf<(() -> Boolean)?> { null }

@Composable
fun AppIconSettings(actionCurrent: () -> Boolean = { true }) {
    val context = LocalContext.current
    val sync = (context.applicationContext as YabApplication).sync
    val native = remember(context.applicationContext) { AppIcons(context) }
    val local = remember(context.applicationContext) { AndroidAppIconLocalStore(context) }
    CompositionLocalProvider(LocalAppIconActionOwner provides actionCurrent) {
        AppIconPicker(native, local, sync.accountRecords, sync::keepAppIcon) { actionCurrent() && sync.nativeOwnerCurrent(it) }
    }
}

@Composable
internal fun AppIconPicker(native: AppIcons, local: AppIconLocalStore, records: StateFlow<AccountRecordsSnapshot>,
                           keep: suspend (AppIcon, SyncIdentityLease) -> Unit,
                           ownerCurrent: (AccountRecordsSnapshot) -> Boolean = { true }) {
    val snapshot by records.collectAsState()
    val frame = AppIconAccountFrame.from(snapshot)
    key(frame.account, frame.device, frame.epoch, frame.removed) {
        AppIconPickerPage(native, local, frame, {
            val current = records.value
            AppIconAccountFrame.from(current) == frame && ownerCurrent(current)
        }, keep)
    }
}

@Composable
private fun AppIconPickerPage(native: AppIcons, local: AppIconLocalStore, frame: AppIconAccountFrame,
                              sourceCurrent: () -> Boolean, keep: suspend (AppIcon, SyncIdentityLease) -> Unit) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val selection = remember(native, local) { AppIconSelection(local, native) }
    var shown by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var kept by remember { mutableStateOf(runCatching { selection.migrateLegacy().kept }.getOrElse { error = "The saved app icon access could not be read."; emptySet() }) }
    var installed by remember { mutableStateOf(runCatching { native.selected().singleOrNull() }.getOrNull()) }
    var at by remember { mutableStateOf(Instant.now()) }
    var changing by remember { mutableStateOf(false) }
    val choices = AppIcon.entries.filter { frame.access.visible(it, kept, at) }
    var preview by remember { mutableStateOf(installed?.icon?.takeIf { it in choices } ?: AppIcon.Flat) }
    var previewDark by remember { mutableStateOf<Boolean?>(null) }
    var dragFrom by remember { mutableStateOf<Int?>(null) }
    var dragPosition by remember { mutableStateOf<Float?>(null) }
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val density = LocalDensity.current
    val dark = previewDark ?: (MaterialTheme.colorScheme.background.luminance() < .5f)
    val scope = rememberCoroutineScope()
    val currentSource by rememberUpdatedState(sourceCurrent)
    val sourceAdmitted = sourceCurrent()
    val actionOwner = LocalAppIconActionOwner.current
    // An exact new action admission also resets retired local work when a short background
    // interval was conflated before this composition could observe sourceAdmitted=false.
    LaunchedEffect(actionOwner, sourceAdmitted) { changing = false }
    fun current() = shown && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && currentSource()
    fun refresh() {
        installed = runCatching { native.selected().singleOrNull() }.getOrNull()
        kept = runCatching { local.read().kept }.getOrElse { error = "The saved app icon access could not be read."; emptySet() }
        at = Instant.now()
    }
    DisposableEffect(lifecycle) {
        shown = true
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) refresh() }
        lifecycle.addObserver(observer)
        onDispose { shown = false; lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(Unit) { while (true) { delay(60_000); at = Instant.now() } }
    LaunchedEffect(choices) { if (preview !in choices) preview = AppIcon.Flat; dragFrom = null; dragPosition = null }
    val index = choices.indexOf(preview).coerceAtLeast(0)
    val currentIndex by rememberUpdatedState(index)
    val animated by animateFloatAsState(index.toFloat(), if (reduced) androidx.compose.animation.core.snap() else BrowserMotion.spring(.42f, .86f), label = "App icon preview")
    val position = dragPosition ?: animated
    fun browse(next: Int) {
        if (!current() || changing || next !in choices.indices) return
        error = null; preview = choices[next]
    }
    val unlocked = frame.access.unlocked(preview, kept, at)
    Column(Modifier.fillMaxSize().testTag("settings.page.appIcon"), horizontalAlignment = Alignment.CenterHorizontally) {
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text("How Yab looks on your Home Screen. Icons you unlock on your Mac are available here too.",
            Modifier.padding(horizontal = 40.dp).padding(top = 10.dp), textAlign = TextAlign.Center, fontSize = 15.sp, lineHeight = 20.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Box(Modifier.padding(top = 16.dp).fillMaxWidth().height(250.dp)
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
            .drawWithContent {
                drawContent()
                drawRect(Brush.horizontalGradient(0f to Color.Transparent, .14f to Color.Black,
                    .86f to Color.Black, 1f to Color.Transparent, endX = size.width), blendMode = BlendMode.DstIn)
            }.testTag("settings.appIcon.gallery")
            .semantics { contentDescription = "App icon preview"; stateDescription = preview.title }
            .pointerInput(choices, changing, reduced) {
                var pixels = 0f
                detectHorizontalDragGestures(onDragStart = { if (current() && !changing) { dragFrom = currentIndex; pixels = 0f } },
                    onHorizontalDrag = { change, amount ->
                        val start = dragFrom
                        if (start != null && current() && !changing) {
                            pixels += amount
                            val wanted = (start - pixels / (72 * density.density)).coerceIn(0f, choices.lastIndex.toFloat())
                            dragPosition = if (reduced) null else wanted
                            browse(wanted.roundToInt()); change.consume()
                        }
                    }, onDragEnd = { dragFrom = null; dragPosition = null }, onDragCancel = { dragFrom = null; dragPosition = null })
            }) {
            choices.forEachIndexed { number, icon ->
                val away = number - position
                val distance = abs(away)
                if (distance <= 3 && (!reduced || icon == preview)) {
                    val variant = icon.variant(frame.access.charm)
                    val picture = remember(variant, dark, native) { native.picture(variant, dark) }
                    Image(painterResource(picture), null, Modifier.align(Alignment.TopCenter).padding(top = 20.dp).size(180.dp)
                        .zIndex(-distance).graphicsLayer {
                            val near = distance.coerceAtMost(1f)
                            rotationY = if (reduced) 0f else -(if (away < 0) -50f * near else 50f * near)
                            scaleX = if (reduced) 1f else 1 - .34f * near; scaleY = scaleX
                            translationX = if (reduced) 0f else (if (away < 0) -1 else 1) * (180 * .62f * near + (distance - 1).coerceAtLeast(0f) * 180 * .24f) * density.density
                            cameraDistance = 400 * density.density
                        }.dropShadow(RoundedCornerShape(40.5.dp), Shadow(radius = 9.dp,
                            color = Color.Black.copy(alpha = .22f), offset = DpOffset(0.dp, 14.dp)))
                        .clip(RoundedCornerShape(40.5.dp)))
                }
            }
            BoxWithConstraints(Modifier.fillMaxWidth().padding(top = 20.dp).height(180.dp)) {
                val zone = ((maxWidth - 180.dp) / 2).coerceAtLeast(44.dp)
                if (index > 0) Box(Modifier.align(Alignment.CenterStart).width(zone).fillMaxHeight()
                    .clickable(enabled = !changing) { browse(index - 1) }
                    .semantics { contentDescription = "Previous app icon"; role = Role.Button }
                    .testTag("settings.appIcon.previous"))
                if (index < choices.lastIndex) Box(Modifier.align(Alignment.CenterEnd).width(zone).fillMaxHeight()
                    .clickable(enabled = !changing) { browse(index + 1) }
                    .semantics { contentDescription = "Next app icon"; role = Role.Button }
                    .testTag("settings.appIcon.next"))
            }
        }
        Text(preview.title, fontSize = 20.sp, lineHeight = 24.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 6.dp).testTag("settings.appIcon.preview.title"))
        Text("Original artwork. Your launcher controls its system appearance.", style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.padding(top = 5.dp), textAlign = TextAlign.Center)
        if (!unlocked && (preview.friendCount != null || preview == AppIcon.Charm)) Text(
            if (preview == AppIcon.Charm) "Comes with a best friend. Unlock it on your Mac."
            else "Comes with ${preview.friendCount} ${if (preview.friendCount == 1) "friend" else "friends"}. Unlock it on your Mac.",
            Modifier.padding(top = 5.dp).testTag("settings.appIcon.locked"), textAlign = TextAlign.Center, style = MaterialTheme.typography.bodySmall)
        Row(Modifier.padding(top = 18.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            choices.forEach { icon -> Box(Modifier.size(7.dp).clip(CircleShape).background(MaterialTheme.colorScheme.onSurface.copy(alpha = if (icon == preview) 1f else .35f))) }
        }
        Box(Modifier.padding(top = 23.dp).height(44.dp), contentAlignment = Alignment.Center) {
            val darkUi = MaterialTheme.colorScheme.background.luminance() < .2f
            Row(Modifier.width(170.dp).height(36.dp).clip(CircleShape)
                .background(Color(0xFF767680).copy(alpha = if (darkUi) .24f else .12f)).padding(2.dp)) {
                for (theme in listOf(false, true)) Box(Modifier.weight(1f).fillMaxHeight()
                    .then(if (dark == theme) Modifier.shadow(1.5.dp, CircleShape)
                        .background(if (darkUi) Color(0xFF636366) else Color.White, CircleShape) else Modifier)
                    .clickable { if (current() && !changing) previewDark = theme }
                    .semantics { selected = dark == theme; role = Role.Tab }
                    .testTag("settings.appIcon.theme.${if (theme) "dark" else "light"}"), contentAlignment = Alignment.Center) {
                    Text(if (theme) "Dark" else "Light", fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
        }
        error?.let { Text(it, Modifier.padding(top = 10.dp).testTag("settings.appIcon.error"), color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center) }
        val inUse = installed == preview.variant(frame.access.charm)
        Button(onClick = {
            if (!current() || changing) return@Button
            val chosen = preview
            val originalAction = currentSource
            val actionCurrent = { current() && originalAction() }
            changing = true; error = null
            scope.launch {
                try {
                    val worn = selection.choose(chosen, frame.access, actionCurrent)
                    if (actionCurrent()) refresh()
                    if (worn != null && frame.account != null && frame.device != null && !frame.removed && actionCurrent())
                        keep(worn, SyncIdentityLease(frame.account, frame.device, frame.epoch))
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { if (actionCurrent()) { refresh(); error = "Couldn't change or save the icon. Try again." } }
                finally { if (actionCurrent()) changing = false }
            }
        }, enabled = !changing && unlocked && !inUse, shape = CircleShape, colors = ButtonDefaults.buttonColors(
            disabledContainerColor = MaterialTheme.colorScheme.onSurface.copy(alpha = .08f), disabledContentColor = MaterialTheme.colorScheme.onSurface), modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 50.dp, top = 10.dp).height(54.dp).testTag("settings.appIcon.use")) {
            if (inUse) { Icon(YabGlyphs.Checkmark1Small, null, Modifier.size(20.dp)); Spacer(Modifier.width(8.dp)) }
            Text(if (changing) "Changing…" else if (!unlocked) "Locked" else if (inUse) "In Use" else "Use This Icon", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}
