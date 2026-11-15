package dev.yab.agent

import android.app.ActivityManager
import android.content.Context
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontWeight
import dev.yab.browser.ui.SettingsActionRow
import dev.yab.browser.ui.SettingsChoiceRow
import dev.yab.browser.ui.SettingsSection
import dev.yab.browser.ui.SettingsGroup
import dev.yab.browser.ui.SettingsNote
import dev.yab.browser.ui.YabGlyphs
import kotlinx.coroutines.launch

internal class AiSettingsNavigation(val route: String, val open: (String) -> Unit)
internal val LocalAiSettingsNavigation = staticCompositionLocalOf<AiSettingsNavigation?> { null }

/** Settings › AI, as on iPhone: who answers about a page, the agent on the Mac, the on-device model. */
@Composable
fun AiSettings(repository: AgentRepository, models: LocalModelManager?, onImport: () -> Unit, actionCurrent: () -> Boolean = { true }) {
    val state by repository.state.collectAsState()
    val scope = rememberCoroutineScope()
    fun change(preferences: AgentPreferences) { if (actionCurrent()) scope.launch { if (actionCurrent()) repository.preferences(preferences) } }
    val navigation = LocalAiSettingsNavigation.current
    fun open(title: String) { if (actionCurrent()) navigation?.open?.invoke(title) }
    fun section(title: String): @Composable () -> Unit = { Text(title.uppercase(), Modifier.padding(start = 8.dp), fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    val page: @Composable () -> Unit = {
        SettingsSection("On this device, a question about a page is answered at once, and the page stays here. On your Mac, ${state.preferences.provider.displayName} answers with your sign-ins.") {
            SettingsChoiceRow("This device", state.preferences.pageAnswers == PageAnswerMode.DEVICE) { change(state.preferences.copy(pageAnswers = PageAnswerMode.DEVICE)) }
            SettingsChoiceRow("Your Mac", state.preferences.pageAnswers == PageAnswerMode.MAC) { change(state.preferences.copy(pageAnswers = PageAnswerMode.MAC)) }
        }
    }
    val agent: @Composable () -> Unit = {
        SettingsSection("Tasks, and everything you ask without a page, go to this agent on your Mac, with your plan and your sign-ins.") {
            // Match the iPhone's choices, retaining an already configured
            // additional provider rather than hiding the person's selection.
            for (provider in AgentProvider.entries.filter { it == AgentProvider.CLAUDE || it == AgentProvider.CODEX || it == state.preferences.provider })
                SettingsChoiceRow(provider.displayName, state.preferences.provider == provider) { change(state.preferences.copy(provider = provider)) }
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(22.dp)) {
        when (navigation?.route) {
            "AI" -> {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    section("Answers")()
                    SettingsGroup {
                        SettingsActionRow("About a page", YabGlyphs.Sparkle, trailing = if (state.preferences.pageAnswers == PageAnswerMode.DEVICE) "This device" else "Your Mac", action = { open("About a page") })
                        SettingsActionRow("Everything else", YabGlyphs.MacAgentFace, trailing = state.preferences.provider.displayName, action = { open("Everything else") })
                        SettingsActionRow("Agent", YabGlyphs.MacAgentFace, trailing = "${state.preferences.provider.displayName} · on your Mac", action = { open("Agent") })
                    }
                }
                if (models != null) SettingsGroup { SettingsActionRow("On-device AI", YabGlyphs.Sparkle, action = { open("On-device AI") }) }
            }
            "About a page" -> page()
            "Agent" -> agent()
            "Everything else" -> {
                SettingsSection("Follow-ups, questions without a page and tasks use the agent on your Mac. Private conversations stay on this device.") { SettingsActionRow(state.preferences.provider.displayName, YabGlyphs.MacAgentFace, trailing = "On your Mac") }
            }
            "On-device AI" -> if (models != null) LocalAiSettings(models, onImport, actionCurrent)
            else -> { page(); agent(); if (models != null) LocalAiSettings(models, onImport, actionCurrent) }
        }
    }
}

@Composable
fun LocalAiSettings(models: LocalModelManager, onImport: () -> Unit, actionCurrent: () -> Boolean = { true }) {
    val state by models.state.collectAsState()
    val scope = rememberCoroutineScope()
    val links = LocalUriHandler.current
    val context = LocalContext.current
    val memory = remember(context) { ActivityManager.MemoryInfo().also { (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(it) }.totalMem }
    var choosing by remember { mutableStateOf<LocalModelCatalog.Model?>(null) }
    var removing by remember { mutableStateOf(false) }
    val busy = state.importing || state.running
    fun act(block: () -> Unit): () -> Unit = { if (actionCurrent()) block() }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SettingsNote("On-device AI")
        SettingsGroup {
            SettingsActionRow(if (state.ready) state.name ?: "Imported model" else "No model yet", YabGlyphs.Sparkle,
                subtitle = if (state.ready) "${state.bytes / 1_000_000} MB stored on this device" else "Download a model to answer without your Mac.")
            if (state.importing) Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                if (state.total > 0) {
                    LinearProgressIndicator(progress = { (state.received.toDouble() / state.total).toFloat().coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
                    Text("${state.received / 1_000_000} of ${state.total / 1_000_000} MB", style = MaterialTheme.typography.bodySmall)
                } else { LinearProgressIndicator(Modifier.fillMaxWidth()); Text("Preparing model…", style = MaterialTheme.typography.bodySmall) }
                TextButton(onClick = act(models::cancelDownload)) { Text("Cancel") }
            }
        }
        SettingsSection("Questions, page text and answers stay on this device. Downloading a model sends none of them.") {
            for (model in LocalModelCatalog.available) {
                val enoughMemory = model != LocalModelCatalog.full || memory >= 5L * 1024 * 1024 * 1024
                Box(Modifier.testTag("ai.model.${model.name}")) {
                    SettingsActionRow(model.name, null,
                        subtitle = if (enoughMemory) null else "Needs a device with at least 6 GB of memory",
                        trailing = "${model.bytes / 1_000_000} MB",
                        action = if (!busy && enoughMemory) act { choosing = model } else null)
                }
            }
            SettingsActionRow("Import a Compatible Model", YabGlyphs.FolderOpen, action = if (!busy) act(onImport) else null)
            if (state.ready) SettingsActionRow("Remove Downloaded Model", YabGlyphs.TrashCan, danger = true, action = if (!busy) act { removing = true } else null)
        }
        state.error?.let { Text(it, Modifier.padding(horizontal = 12.dp), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
    }
    choosing?.let { model ->
        AlertDialog(onDismissRequest = { choosing = null }, title = { Text("Download ${model.name}?") },
            text = { Column {
                Text("The download uses ${model.bytes / 1_000_000} MB. Use Wi-Fi if your data plan is limited. Your existing model stays until the new one is ready.")
                TextButton(onClick = { links.openUri(model.source) }) { Text("Model source and ${model.license} license") }
            } }, confirmButton = { TextButton(onClick = { choosing = null; models.startDownload(model, scope) }) { Text("Download") } },
            dismissButton = { TextButton(onClick = { choosing = null }) { Text("Cancel") } })
    }
    if (removing) AlertDialog(onDismissRequest = { removing = false }, title = { Text("Remove the on-device model?") },
        text = { Text("On-device answers will need another download. Your conversations stay.") },
        confirmButton = { TextButton(onClick = { removing = false; scope.launch { models.remove() } }) { Text("Remove") } },
        dismissButton = { TextButton(onClick = { removing = false }) { Text("Cancel") } })
}
