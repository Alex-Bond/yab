package dev.yab.browser.ui

import android.content.Intent
import android.app.role.RoleManager
import android.provider.Settings
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import dev.yab.notifications.PushNotifications

/** Read actual OS permission on return. Opening Settings never requests/grants permission itself. */
@Composable internal fun SettingsNotificationRow(current: () -> Boolean, unavailable: () -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var allowed by remember(context) { mutableStateOf(PushNotifications.allowed(context)) }
    DisposableEffect(owner, context) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) allowed = PushNotifications.allowed(context)
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    SettingsActionRow("Notifications", YabGlyphs.BellCheck, trailing = when {
        !PushNotifications.configured -> "Not configured"
        allowed -> "On"
        else -> "Off"
    }, action = {
        if (current()) runCatching {
            context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName))
        }.onFailure { if (current()) unavailable() }
    })
}

/** Android's actual default-browser role, refreshed after returning from its system picker. */
@Composable internal fun SettingsDefaultBrowserRow(action: (() -> Unit)?) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    fun value(): String = runCatching {
        val roles = context.getSystemService(RoleManager::class.java)
        if (roles == null || !roles.isRoleAvailable(RoleManager.ROLE_BROWSER)) "Unavailable"
        else if (roles.isRoleHeld(RoleManager.ROLE_BROWSER)) "Yab" else "Not Yet"
    }.getOrDefault("Unavailable")
    var title by remember(context) { mutableStateOf(value()) }
    DisposableEffect(owner, context) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) title = value() }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    SettingsActionRow("Default Browser", YabGlyphs.Globe, trailing = title, action = action)
}
