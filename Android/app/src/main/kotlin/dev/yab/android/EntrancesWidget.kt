package dev.yab.android

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.widget.RemoteViews

/** The launcher only carries a route, never page content, a prompt, or account data. */
class EntrancesWidget : AppWidgetProvider() {
    companion object {
        fun installShortcuts(context: Context) {
            val manager = context.getSystemService(ShortcutManager::class.java)
            if (manager.isRateLimitingActive) return
            manager.dynamicShortcuts = listOf("new" to R.string.entrance_search, "ask" to R.string.entrance_ask, "private" to R.string.entrance_private, "scan" to R.string.entrance_scan).map { (route, label) ->
                ShortcutInfo.Builder(context, route).setShortLabel(context.getString(label))
                    .setIcon(Icon.createWithResource(context, R.drawable.ic_yab))
                    .setIntent(Intent(Intent.ACTION_VIEW, Uri.parse("yab://$route"), context, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)).build()
            }
        }
    }
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.entrances_widget)
            for ((view, route) in listOf(R.id.widget_search to "new", R.id.widget_ask to "ask", R.id.widget_private to "private", R.id.widget_scan to "scan")) {
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse("yab://$route"), context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                views.setOnClickPendingIntent(view, PendingIntent.getActivity(context, id * 10 + view, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            }
            manager.updateAppWidget(id, views)
        }
    }

    override fun onEnabled(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        onUpdate(context, manager, manager.getAppWidgetIds(ComponentName(context, javaClass)))
    }
}
