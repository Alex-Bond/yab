package dev.yab.android

import android.app.KeyguardManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import dev.yab.sync.NowShelfSnapshot
import dev.yab.sync.NowShelfStore
import dev.yab.sync.SyncIdentityStore
import java.io.File

/** Home-screen counterpart of iOS NowWidget. The separate four-shortcut widget stays unchanged. */
class NowWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val shelf = runCatching {
            val identity = SyncIdentityStore(context).load()
            NowShelfStore(File(context.noBackupFilesDir, NowShelfStore.FILE_NAME)).read()?.takeIf {
                identity != null && it.account == identity.seal.account && it.device == identity.device
            }
        }.getOrNull()
        val locked = context.getSystemService(KeyguardManager::class.java)?.isDeviceLocked != false
        for (id in ids) manager.updateAppWidget(id, render(context, shelf, id, locked))
    }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) { onUpdate(context, manager, intArrayOf(id)) }
    override fun onEnabled(context: Context) { updateAll(context) }

    companion object {
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, NowWidget::class.java))
            if (ids.isNotEmpty()) NowWidget().onUpdate(context, manager, ids)
        }
        private fun entrance(context: Context, address: String, request: Int): PendingIntent {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(address), context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            return PendingIntent.getActivity(context, request, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        internal fun render(context: Context, shelf: NowShelfSnapshot?, widget: Int, locked: Boolean): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.now_widget)
            val rows = shelf?.rows.orEmpty()
            views.removeAllViews(R.id.now_widget_rows)
            views.setViewVisibility(R.id.now_widget_rows, if (rows.isEmpty()) View.GONE else View.VISIBLE)
            views.setViewVisibility(R.id.now_widget_quiet, if (rows.isEmpty()) View.VISIBLE else View.GONE)
            views.setOnClickPendingIntent(R.id.now_widget_search, entrance(context, "yab://new", widget * 31 + 1))
            views.setOnClickPendingIntent(R.id.now_widget_ask, entrance(context, "yab://ask", widget * 31 + 2))
            for (row in rows) {
                val child = RemoteViews(context.packageName, R.layout.now_widget_row)
                val who = row.who.ifBlank { row.host }.ifBlank { "Yab" }
                child.setTextViewText(R.id.now_widget_who, who)
                child.setTextViewText(R.id.now_widget_title, if (locked) "" else row.title)
                child.setTextViewText(R.id.now_widget_detail, if (locked) "" else row.detail)
                child.setViewVisibility(R.id.now_widget_title, if (locked) View.GONE else View.VISIBLE)
                child.setViewVisibility(R.id.now_widget_detail, if (locked || row.detail.isBlank()) View.GONE else View.VISIBLE)
                child.setContentDescription(R.id.now_widget_row, if (locked) who else "$who: ${row.title}")
                child.setOnClickPendingIntent(R.id.now_widget_row, entrance(context, checkNotNull(shelf).link(row), widget * 31 + row.id.hashCode()))
                views.addView(R.id.now_widget_rows, child)
            }
            return views
        }
    }
}
