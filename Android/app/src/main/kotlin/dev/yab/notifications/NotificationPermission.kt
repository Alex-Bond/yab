package dev.yab.notifications

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat

/** Call only from the user-entered chat/approval screen, never from app startup or Sync pairing. */
@Composable
fun NotificationPermissionOnChatEntry() {
    val context = LocalContext.current
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { PushNotifications.refreshRegistration(context) }
    LaunchedEffect(Unit) {
        val prefs = context.getSharedPreferences("push", Context.MODE_PRIVATE)
        if (PushNotifications.configured && Build.VERSION.SDK_INT >= 33 && !prefs.getBoolean("askedPermission", false)
            && ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            prefs.edit().putBoolean("askedPermission", true).apply()
            permission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}
