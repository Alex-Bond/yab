package dev.yab.browser.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.browser.model.*
import kotlin.math.roundToInt

private fun ReaderColors.backgroundColor() = Color(android.graphics.Color.parseColor(background))
private fun ReaderColors.textColor() = Color(android.graphics.Color.parseColor(text))
private fun ReaderFont.family() = if (this == ReaderFont.SYSTEM || this == ReaderFont.SITE) FontFamily.SansSerif else FontFamily.Serif
private fun Context.readerActivity(): Activity? {
    var value: Context = this
    repeat(16) {
        if (value is Activity) return value as Activity
        val wrapper = value as? ContextWrapper ?: return null
        if (wrapper.baseContext === value) return null
        value = wrapper.baseContext
    }
    return null
}

/** Captured once alongside the original menu, never reacquired by a saved row press. */
internal fun captureBrowserReaderPresentation(store: dev.yab.browser.engine.ReaderPreferencesStore,
    controller: BrowserController, lease: PageMenuLease, root: android.view.View,
    originalCurrent: () -> Boolean): BrowserReaderPresentation? {
    val activity = root.context.readerActivity() ?: return null
    val window = activity.window
    val intent = activity.intent
    val decor = window.decorView
    val token = root.windowToken ?: return null
    val configuration = android.content.res.Configuration(activity.resources.configuration)
    val lifetime = controller.settingsPresentationLifetime.value
    fun bounds(): android.graphics.Rect = if (android.os.Build.VERSION.SDK_INT >= 30)
        android.graphics.Rect(activity.windowManager.currentWindowMetrics.bounds)
    else android.graphics.Rect().also(decor::getWindowVisibleDisplayFrame)
    val frame = bounds()
    if (frame.isEmpty || !lifetime.active || !originalCurrent()) return null
    return BrowserReaderPresentation(store) {
        val state = controller.state.value
        activity.window === window && window.decorView === decor && activity.intent === intent &&
            activity.resources.configuration == configuration && bounds() == frame &&
            root.windowToken === token && root.isAttachedToWindow && root.isShown && root.hasWindowFocus() &&
            controller.settingsPresentationLifetime.value == lifetime && lifetime.active &&
            lease.url?.let { lease.ownsSource(state, it) } == true && state.page.readerEnabled && !state.page.loading && originalCurrent()
    }.takeIf { it.current() }
}

/** Same-root UI; no new native window or page command. Prefs never manufacture a Reader. */
@Composable
internal fun BrowserReaderCard(presentation: BrowserReaderPresentation, modifier: Modifier = Modifier,
    onCoverage: (Boolean) -> Unit = {}) {
    val frame by presentation.state.collectAsState()
    val prefs by presentation.store.state.collectAsState()
    val themeRevision by presentation.store.themeChanges.collectAsState()
    val error by presentation.store.error.collectAsState()
    val dark = prefs.dark(androidx.compose.foundation.isSystemInDarkTheme())
    val controls = remember(presentation, frame.generation, prefs.theme, themeRevision) { presentation.control() }
    DisposableEffect(controls) { onDispose { controls.retire() } }
    val themes = remember(presentation) { MutableTransitionState(false) }
    val customize = remember(presentation) { MutableTransitionState(false) }
    val themeDraw = remember(presentation) { arrayOfNulls<BrowserReaderPresentation.Control>(1) }
    val customDraw = remember(presentation) { arrayOfNulls<BrowserReaderPresentation.Control>(1) }
    val customPage = remember(presentation) { arrayOf(ReaderCardPage.CUSTOMIZE) }
    if (frame.shown && frame.page == ReaderCardPage.THEMES) themeDraw[0] = controls
    if (frame.shown && frame.page != ReaderCardPage.THEMES) { customDraw[0] = controls; customPage[0] = frame.page }
    LaunchedEffect(presentation, frame.shown, frame.page) {
        themes.targetState = frame.shown && frame.page == ReaderCardPage.THEMES
        customize.targetState = frame.shown && frame.page != ReaderCardPage.THEMES
    }
    val drawing = frame.shown || themes.currentState || !themes.isIdle || customize.currentState || !customize.isIdle
    SideEffect { onCoverage(!frame.dropped && drawing) }
    DisposableEffect(presentation) { onDispose { onCoverage(false) } }
    if (!presentation.current() && frame.shown) { SideEffect { presentation.drop() }; return }
    if (frame.dropped || !drawing) return
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val disabled = !android.animation.ValueAnimator.areAnimatorsEnabled()
    val fadeSpec: androidx.compose.animation.core.FiniteAnimationSpec<Float> = if (reduced)
        androidx.compose.animation.core.tween(200, easing = androidx.compose.animation.core.CubicBezierEasing(.42f, 0f, .58f, 1f))
        else spring(dampingRatio = .88f, stiffness = 341.5f)
    val slideSpec: androidx.compose.animation.core.FiniteAnimationSpec<androidx.compose.ui.unit.IntOffset> = if (reduced)
        androidx.compose.animation.core.tween(200, easing = androidx.compose.animation.core.CubicBezierEasing(.42f, 0f, .58f, 1f))
        else spring(dampingRatio = .88f, stiffness = 341.5f)
    val activity = LocalContext.current.readerActivity()
    val originalWindow = remember(presentation) { activity?.window }
    var brightness by remember(presentation) {
        val asked = originalWindow?.attributes?.screenBrightness ?: -1f
        mutableFloatStateOf(if (asked >= 0f) asked else runCatching {
            Settings.System.getInt(activity?.contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255f
        }.getOrDefault(.5f))
    }
    BackHandler(frame.shown) {
        when (frame.page) {
            ReaderCardPage.FONTS -> controls.back()
            ReaderCardPage.CUSTOMIZE -> controls.cancel()
            ReaderCardPage.THEMES -> controls.close()
        }
    }
    val primary = if (dark) Color.White else Color.Black
    val background = if (dark) Color.Black else Color(0xFFF2F2F7)
    val surface = if (dark) Color(0xFF1C1C1E) else Color.White
    val scheme = if (dark) darkColorScheme() else lightColorScheme()
    MaterialTheme(colorScheme = scheme.copy(primary = primary, onPrimary = if (dark) Color.Black else Color.White,
        primaryContainer = primary.copy(alpha = .1f), onPrimaryContainer = primary,
        background = background, onBackground = primary, surface = surface, onSurface = primary,
        surfaceContainer = surface, surfaceContainerHigh = surface, surfaceContainerHighest = surface)) {
        Box(modifier.fillMaxSize().testTag("reader.layer").then(if (!frame.shown) Modifier.clearAndSetSemantics {} else Modifier)) {
            Box(Modifier.matchParentSize().pointerInput(presentation) { awaitPointerEventScope {
                while (true) awaitPointerEvent(PointerEventPass.Final).changes.forEach { it.consume() }
            } })
            val originalTheme = themeDraw[0]
            if (originalTheme != null && (themes.currentState || themes.targetState || !themes.isIdle)) key(originalTheme) {
                Box(Modifier.fillMaxSize().clickable { originalTheme.close() }.clearAndSetSemantics {})
            }
            AnimatedVisibility(themes, Modifier.align(Alignment.BottomCenter),
                enter = if (disabled) androidx.compose.animation.EnterTransition.None else slideInVertically(slideSpec) { it } + fadeIn(fadeSpec),
                exit = if (disabled) androidx.compose.animation.ExitTransition.None else slideOutVertically(slideSpec) { it } + fadeOut(fadeSpec)) {
                originalTheme?.let { original -> key(original) {
                    ReaderThemesCard(prefs, dark, original, error, brightness, originalWindow != null,
                        setBrightness = { value -> if (activity?.window === originalWindow && originalWindow != null) {
                            originalWindow.attributes = originalWindow.attributes.apply { screenBrightness = value }
                            brightness = value
                        } }, modifier = Modifier.padding(8.dp).navigationBarsPadding()
                            .readerDrawingOnly(frame.shown && frame.page == ReaderCardPage.THEMES, original))
                } }
            }
            AnimatedVisibility(customize, Modifier.fillMaxSize(),
                enter = if (disabled) androidx.compose.animation.EnterTransition.None else fadeIn(fadeSpec) +
                    scaleIn(fadeSpec, initialScale = .98f, transformOrigin = TransformOrigin(.5f, 1f)),
                exit = if (disabled) androidx.compose.animation.ExitTransition.None else fadeOut(fadeSpec) +
                    scaleOut(fadeSpec, targetScale = .98f, transformOrigin = TransformOrigin(.5f, 1f))) {
                customDraw[0]?.let { original -> key(original) {
                    Box(Modifier.fillMaxSize().readerDrawingOnly(frame.shown && frame.page != ReaderCardPage.THEMES, original)) {
                        ReaderCustomize(prefs, dark, customPage[0], original, error)
                    }
                } }
            }
        }
    }
}

/** Outgoing pixels stay, but their original controls cannot receive input or accessibility. */
private fun Modifier.readerDrawingOnly(active: Boolean, original: Any): Modifier = if (active) this else
    clearAndSetSemantics {}.pointerInput(original) { awaitPointerEventScope {
        while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
    } }

@Composable private fun ReaderThemesCard(prefs: ReaderPreferences, dark: Boolean,
    controls: BrowserReaderPresentation.Control, error: String?, brightness: Float, hasBrightness: Boolean,
    setBrightness: (Float) -> Unit, modifier: Modifier = Modifier) {
    val originalView = LocalView.current
    Surface(modifier.fillMaxWidth().testTag("reader.card"), shape = RoundedCornerShape(36.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = .98f), shadowElevation = 12.dp) {
        var appearance by remember(controls) { mutableStateOf(false) }
        Box {
         Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
             Row(verticalAlignment = Alignment.CenterVertically) {
                 ReaderRound("Close", "reader.card.close", { controls.close() }) { Icon(YabGlyphs.CrossMedium, null) }
                 Text("Themes & Settings", Modifier.padding(start = 12.dp).semantics { heading() }, style = MaterialTheme.typography.titleMedium)
             }
             Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                 Surface(Modifier.weight(1f).height(48.dp), shape = CircleShape, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .1f)) {
                     Row {
                         TextButton({ controls.step(-1) }, Modifier.weight(1f).fillMaxHeight().testTag("reader.card.smaller").semantics { contentDescription = "Smaller Text" }, enabled = prefs.look.size > 0) { Text("A", fontSize = 15.sp) }
                         Box(Modifier.align(Alignment.CenterVertically).width(1.dp).height(22.dp).background(MaterialTheme.colorScheme.onSurface.copy(alpha = .2f)))
                         TextButton({ controls.step(1) }, Modifier.weight(1f).fillMaxHeight().testTag("reader.card.larger").semantics { contentDescription = "Larger Text" }, enabled = prefs.look.size < ReaderLook.sizes.lastIndex) { Text("A", fontSize = 21.sp) }
                     }
                 }
                 Surface(Modifier.weight(1f).height(48.dp), shape = CircleShape, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .1f)) {
                     Row {
                         IconButton({ controls.change { it.copy(justify = !it.justify) } }, Modifier.weight(1f).testTag("reader.card.justify").semantics { selected = prefs.look.justify }) { Icon(YabGlyphs.AlignmentJustify, "Justify Text") }
                         Box(Modifier.weight(1f)) {
                             IconButton({ appearance = !appearance }, Modifier.fillMaxWidth().testTag("reader.card.appearance").semantics { stateDescription = prefs.mode.title }) { Icon(YabGlyphs.Moon, "Appearance") }
                         }
                     }
                 }
             }
             // Android changes this original app window only, never system settings.
             if (hasBrightness) Row(verticalAlignment = Alignment.CenterVertically) {
                 Icon(YabGlyphs.SunLow, null)
                 Slider(brightness, onValueChange = { value ->
                     controls.windowSetting { setBrightness(value.coerceIn(0f, 1f)) }
                 }, modifier = Modifier.weight(1f).testTag("reader.card.brightness").semantics { contentDescription = "Brightness" })
                 Icon(YabGlyphs.Sun, null)
             }
             ReaderThemeSpec.ordered.chunked(3).forEach { row ->
                 Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                     row.forEach { spec ->
                         val colors = (prefs.edits[spec.theme]?.apply(spec.look)?.colors) ?: if (dark) spec.dark else spec.light
                         val pick: () -> Boolean = {
                             val accepted = controls.theme(spec.theme)
                             if (accepted) originalView.performHapticFeedback(android.view.HapticFeedbackConstants.CONTEXT_CLICK)
                             accepted
                         }
                         Surface(modifier = Modifier.weight(1f).height(82.dp).testTag("reader.card.theme.${spec.theme.name.lowercase()}").clearAndSetSemantics {
                             role = androidx.compose.ui.semantics.Role.Button
                             selected = prefs.theme == spec.theme
                             contentDescription = spec.theme.title + if (prefs.edited(spec.theme)) ", edited" else ""
                             stateDescription = if (prefs.edited(spec.theme)) "Edited" else "Default"
                             onClick { pick() }
                         },
                             onClick = { pick() }, shape = RoundedCornerShape(16.dp), color = colors.backgroundColor(),
                             border = androidx.compose.foundation.BorderStroke(if (prefs.theme == spec.theme) 2.5.dp else 1.dp,
                                 if (prefs.theme == spec.theme) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = .08f))) {
                            Box(Modifier.fillMaxSize()) {
                             Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                                 Text("Aa", color = colors.textColor(), fontSize = 28.sp, fontFamily = spec.look.font.family(), fontWeight = FontWeight(spec.weight))
                                 Text(spec.theme.title, color = colors.textColor(), fontSize = 14.sp, fontFamily = spec.look.font.family(), fontWeight = FontWeight(spec.weight))
                             }
                             if (prefs.edited(spec.theme)) Box(Modifier.align(Alignment.TopEnd).padding(9.dp).size(6.dp).background(colors.textColor().copy(alpha = .8f), CircleShape))
                            }
                         }
                     }
                 }
             }
             Button({ controls.customize() }, Modifier.fillMaxWidth().height(52.dp).testTag("reader.card.customize"), shape = CircleShape,
                 colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.onSurface.copy(alpha = .1f), contentColor = MaterialTheme.colorScheme.onSurface)) { Text("Customize") }
             error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
         }
         if (appearance) Surface(Modifier.align(Alignment.TopEnd).padding(end = 16.dp).offset(y = 124.dp).width(200.dp),
             shape = RoundedCornerShape(16.dp), shadowElevation = 8.dp) {
             Column { ReaderMode.entries.forEach { mode ->
                 TextButton({ appearance = false; controls.mode(mode) }, Modifier.fillMaxWidth()
                     .testTag("reader.card.mode.${mode.name.lowercase()}").semantics { selected = prefs.mode == mode }) { Text(mode.title) }
             } }
         }
        }
    }
}

@Composable private fun ReaderRound(label: String, tag: String, click: () -> Unit, filled: Boolean = false,
    content: @Composable () -> Unit) {
    IconButton(click, Modifier.size(44.dp).background(if (filled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = .12f), CircleShape)
        .testTag(tag).semantics { contentDescription = label },
        colors = IconButtonDefaults.iconButtonColors(contentColor = if (filled) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface), content = content)
}

@Composable private fun ReaderCustomize(prefs: ReaderPreferences, dark: Boolean, page: ReaderCardPage,
    controls: BrowserReaderPresentation.Control, error: String?) {
    val colors = prefs.colors(dark); val look = prefs.look
    val sampleFace = if (look.font == ReaderFont.SITE) ReaderFont.NEW_YORK else look.font
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).testTag("reader.customize")) {
        Column(Modifier.fillMaxWidth().background(colors.backgroundColor()).statusBarsPadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                ReaderRound("Cancel", "reader.customize.cancel", { controls.cancel() }) { Icon(YabGlyphs.CrossMedium, null, tint = colors.textColor()) }
                Text("Customize Theme", Modifier.semantics { heading() }, color = colors.textColor(), style = MaterialTheme.typography.titleMedium)
                ReaderRound("Done", "reader.customize.done", { controls.done() }, filled = true) { Icon(YabGlyphs.Checkmark1Small, null) }
            }
            Column(Modifier.testTag("reader.customize.sample").clearAndSetSemantics { contentDescription = "Sample text in ${prefs.theme.title}" }, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Aa", color = colors.textColor(), fontSize = 34.sp, fontFamily = sampleFace.family(), fontWeight = FontWeight(if (look.bold) 700 else prefs.spec.weight))
            Text("The tide came in slowly that evening, and nobody on the pier was in any hurry to leave.",
                Modifier.padding(horizontal = maxOf(0f, look.margins * .6f).dp),
                color = colors.textColor(), fontFamily = sampleFace.family(), fontSize = look.points.sp,
                fontWeight = FontWeight(if (look.bold) 700 else prefs.spec.weight), letterSpacing = (look.points * look.letter / 100f).sp,
                lineHeight = (look.points * look.line).sp)
            }
        }
        Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).navigationBarsPadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (page == ReaderCardPage.FONTS) {
                TextButton({ controls.back() }, Modifier.testTag("reader.fonts.back").semantics { contentDescription = "Back" }) { Text("Font") }
                ReaderGroup {
                    ReaderFont.entries.forEachIndexed { index, font ->
                        if (index > 0) ReaderSeparator()
                        TextButton({ controls.change { it.copy(font = font) } }, Modifier.fillMaxWidth().heightIn(min = 52.dp)
                            .testTag("reader.fonts.${font.name.lowercase()}").semantics { selected = font == look.font }) {
                            Text(font.title, Modifier.weight(1f), fontFamily = font.family(), fontSize = 18.sp)
                            if (font == look.font) Icon(YabGlyphs.Checkmark1Small, null, Modifier.size(22.dp))
                        }
                    }
                }
            } else {
                Text("Text", style = MaterialTheme.typography.titleLarge)
                ReaderGroup {
                    TextButton({ controls.fonts() }, Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag("reader.customize.font")) { Text("Font · ${look.font.title}") }
                    ReaderSeparator()
                    ReaderToggle("Bold Text", "bold", look.bold) { controls.change { look -> look.copy(bold = it) } }
                }
                Text("Layout", style = MaterialTheme.typography.titleLarge)
                ReaderGroup {
                    ReaderKnob("Line Spacing", "line", look.line.toFloat(), 1.3f..2.1f, 15) { value -> controls.change { it.copy(line = (value * 20).roundToInt() / 20.0) } }
                    ReaderSeparator()
                    ReaderKnob("Character Spacing", "letter", look.letter.toFloat(), -3f..10f, 12) { value -> controls.change { it.copy(letter = value.roundToInt()) } }
                    ReaderSeparator()
                    ReaderKnob("Word Spacing", "word", look.word.toFloat(), 0f..40f, 19) { value -> controls.change { it.copy(word = (value / 2).roundToInt() * 2) } }
                    ReaderSeparator()
                    ReaderKnob("Margins", "margins", look.margins.toFloat(), -30f..30f, 29) { value -> controls.change { it.copy(margins = (value / 2).roundToInt() * 2) } }
                }
                ReaderGroup { ReaderToggle("Justify Text", "justify", look.justify) { controls.change { look -> look.copy(justify = it) } } }
                if (prefs.edited(prefs.theme)) ReaderGroup {
                    TextButton({ controls.reset() }, Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag("reader.customize.reset")) { Text("Reset ${prefs.theme.title}", color = MaterialTheme.colorScheme.error) }
                }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }
}
@Composable private fun ReaderToggle(label: String, id: String, value: Boolean, set: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag("reader.customize.$id")
        .toggleable(value = value, role = androidx.compose.ui.semantics.Role.Switch, onValueChange = set)
        .padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f)); Switch(value, null, colors = SwitchDefaults.colors(
            checkedTrackColor = if (MaterialTheme.colorScheme.onSurface == Color.White) Color(0xFF30D158) else Color(0xFF34C759), checkedThumbColor = Color.White,
            uncheckedTrackColor = MaterialTheme.colorScheme.onSurface.copy(alpha = .16f), uncheckedThumbColor = Color.White,
            uncheckedBorderColor = Color.Transparent))
    }
}
@Composable private fun ReaderKnob(label: String, id: String, value: Float, range: ClosedFloatingPointRange<Float>, steps: Int, set: (Float) -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
        Text(label)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Slider(value.coerceIn(range), set, Modifier.weight(1f).testTag("reader.customize.$id").semantics { contentDescription = label }, valueRange = range, steps = steps)
            Text(if (id == "line") "%.2f".format(value) else "${value.roundToInt()}%", Modifier.widthIn(min = 48.dp))
        }
    }
}
@Composable private fun ReaderGroup(content: @Composable ColumnScope.() -> Unit) {
    Surface(shape = RoundedCornerShape(26.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Column(Modifier.fillMaxWidth(), content = content)
    }
}
@Composable private fun ReaderSeparator() {
    HorizontalDivider(Modifier.padding(start = 16.dp), thickness = .5.dp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .2f))
}
