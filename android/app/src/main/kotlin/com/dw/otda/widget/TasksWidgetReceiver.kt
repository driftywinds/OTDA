package com.dw.otda.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import com.dw.otda.MainActivity
import com.dw.otda.QuickAddActivity
import com.dw.otda.R

/** Extras and actions shared by the receiver, the list factory and the tap activity. */
internal object WidgetIntents {
    const val ACTION_REFRESH = "com.dw.otda.widget.REFRESH"
    const val EXTRA_OP = "op"
    const val EXTRA_ID = "id"
    const val EXTRA_DAY = "day"
    const val EXTRA_DONE = "done"
    const val OP_TOGGLE = "toggle"
    const val OP_OPEN = "open"

    fun flags(mutable: Boolean): Int {
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        flags = flags or if (mutable && Build.VERSION.SDK_INT >= 31) 33554432 /* FLAG_MUTABLE */ else 67108864 /* FLAG_IMMUTABLE */
        return flags
    }

    fun deepLink(context: Context, uri: Uri): Intent =
        Intent(Intent.ACTION_VIEW, uri).setClass(context, MainActivity::class.java)
}

/** Every widget instance, redrawn in full: header, list binding and list contents. */
internal fun updateWidgets(context: Context) {
    val manager = AppWidgetManager.getInstance(context)
    for (id in widgetIds(context, manager)) WidgetRenderer.render(context, manager, id)
}

/** Asks every instance to redraw after the prefs changed outside the system flow. */
internal fun requestWidgetUpdate(context: Context) = updateWidgets(context)

/** Re-reads the rows of every list, leaving the header and the scroll position alone. */
internal fun refreshWidgetLists(context: Context) {
    val manager = AppWidgetManager.getInstance(context)
    val ids = widgetIds(context, manager)
    if (ids.isNotEmpty()) manager.notifyAppWidgetViewDataChanged(ids, R.id.list)
}

private fun widgetIds(context: Context, manager: AppWidgetManager): IntArray =
    manager.getAppWidgetIds(ComponentName(context, TasksWidgetReceiver::class.java))

/**
 * Plain AppWidgetProvider on purpose: the widget is RemoteViews with a scrolling list, drawn from the
 * stored snapshot. Nothing here waits for Flutter, the database or the network.
 */
class TasksWidgetReceiver : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        for (id in appWidgetIds) WidgetRenderer.render(context, manager, id)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, appWidgetId: Int, newOptions: Bundle) {
        // The width decides whether section headings fit.
        WidgetRenderer.render(context, manager, appWidgetId)
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        val prefs = widgetPrefs(context)
        val editor = prefs.edit()
        appWidgetIds.forEach { editor.remove(widgetProjectKey(it)) }
        editor.apply()
        updateActiveProjects(prefs)
        super.onDeleted(context, appWidgetIds)
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            WidgetIntents.ACTION_REFRESH -> refresh(context)
            Intent.ACTION_DATE_CHANGED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_BOOT_COMPLETED -> {
                updateWidgets(context)
                // A new day changes what "Today" means; the app rebuilds the snapshots.
                sendToDart(context, Uri.parse("otda://refresh"))
            }
            else -> super.onReceive(context, intent)
        }
    }

    /** Shows the refreshing state at once, then asks the app to sync and rebuild the snapshots. */
    private fun refresh(context: Context) {
        markRefreshing(context)
        updateWidgets(context)
        sendToDart(context, Uri.parse("otda://refresh"))
        // The app redraws when it is done. If it never answers, do not leave the state up.
        val pending = goAsync()
        Handler(Looper.getMainLooper()).postDelayed({
            try {
                updateWidgets(context)
            } finally {
                pending.finish()
            }
        }, REFRESH_TIMEOUT_MS + 300L)
    }
}

internal object WidgetRenderer {

    fun render(context: Context, manager: AppWidgetManager, appWidgetId: Int) {
        val prefs = widgetPrefs(context)
        val style = WidgetStyle.read(prefs)
        val projectId = prefs.getString(widgetProjectKey(appWidgetId), null)
        val snapshot = Snapshot.parse(prefs.getString(snapshotKey(projectId), null))
        // Nothing stored yet (just placed, or the app was never opened since): ask the app's Dart
        // side to write the snapshot from the on-device data, without opening the UI.
        if (snapshot == null) requestSnapshot(context, prefs)
        val refreshing = isRefreshing(context)

        val views = RemoteViews(context.packageName, style.rootLayout)
        views.setInt(R.id.bg, "setImageAlpha", (style.backgroundAlpha * 255f).toInt().coerceIn(0, 255))

        if (snapshot == null) {
            views.setViewVisibility(R.id.content, View.GONE)
            views.setViewVisibility(R.id.setup, View.VISIBLE)
            views.setTextViewTextSize(R.id.setup_title, TypedValue.COMPLEX_UNIT_SP, style.sp(20))
            views.setTextViewTextSize(R.id.setup_hint, TypedValue.COMPLEX_UNIT_SP, style.sp(14))
            views.setOnClickPendingIntent(R.id.setup, openApp(context, appWidgetId, 1))
        } else {
            views.setViewVisibility(R.id.setup, View.GONE)
            views.setViewVisibility(R.id.content, View.VISIBLE)

            views.setTextViewText(R.id.title, if (refreshing) "Refreshing…" else snapshot.name.ifBlank { "OTDA" })
            views.setTextViewTextSize(R.id.title, TypedValue.COMPLEX_UNIT_SP, style.sp(20))
            views.setViewVisibility(R.id.refresh_icon, if (refreshing) View.GONE else View.VISIBLE)
            views.setViewVisibility(R.id.refresh_active, if (refreshing) View.VISIBLE else View.GONE)

            views.setOnClickPendingIntent(R.id.title_area, configure(context, appWidgetId))
            views.setOnClickPendingIntent(R.id.btn_refresh, refreshIntent(context, appWidgetId))
            views.setOnClickPendingIntent(R.id.btn_add, quickAdd(context, appWidgetId, projectId))
            views.setOnClickPendingIntent(R.id.btn_open, openApp(context, appWidgetId, 2))

            val adapter = Intent(context, TasksWidgetService::class.java)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                // The theme is part of the identity: a different one is a different adapter, so the
                // launcher drops the old layouts instead of mixing the two.
                .setData(Uri.parse("otda-widget://list/$appWidgetId/${style.theme}"))
            views.setRemoteAdapter(R.id.list, adapter)
            views.setEmptyView(R.id.list, R.id.empty)
            views.setTextViewTextSize(R.id.empty_text, TypedValue.COMPLEX_UNIT_SP, style.sp(16))
            views.setPendingIntentTemplate(R.id.list, rowTemplate(context, appWidgetId))

            if (snapshot.more > 0) {
                views.setViewVisibility(R.id.more, View.VISIBLE)
                views.setTextViewText(R.id.more, "+${snapshot.more} more")
                views.setTextViewTextSize(R.id.more, TypedValue.COMPLEX_UNIT_SP, style.sp(13))
                views.setOnClickPendingIntent(R.id.more, openApp(context, appWidgetId, 3))
            } else {
                views.setViewVisibility(R.id.more, View.GONE)
            }
        }
        manager.updateAppWidget(appWidgetId, views)
        manager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.list)
    }

    /** One template for every row: the tap activity reads what each row's fill-in says to do. */
    private fun rowTemplate(context: Context, appWidgetId: Int): PendingIntent {
        val intent = Intent(context, WidgetActionActivity::class.java)
            .setData(Uri.parse("otda-widget://row/$appWidgetId"))
        return PendingIntent.getActivity(context, appWidgetId * 10, intent, WidgetIntents.flags(mutable = true))
    }

    private fun refreshIntent(context: Context, appWidgetId: Int): PendingIntent {
        val intent = Intent(context, TasksWidgetReceiver::class.java)
            .setAction(WidgetIntents.ACTION_REFRESH)
            .setData(Uri.parse("otda-widget://refresh/$appWidgetId"))
        return PendingIntent.getBroadcast(context, appWidgetId * 10 + 4, intent, WidgetIntents.flags(mutable = false))
    }

    private fun configure(context: Context, appWidgetId: Int): PendingIntent {
        val intent = Intent(context, TasksWidgetConfigActivity::class.java)
            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            .setData(Uri.parse("otda-widget://config/$appWidgetId"))
        return PendingIntent.getActivity(context, appWidgetId * 10 + 5, intent, WidgetIntents.flags(mutable = false))
    }

    /** The popup composer over the current app; `project` pre-selects the widget's project. */
    private fun quickAdd(context: Context, appWidgetId: Int, projectId: String?): PendingIntent {
        val intent = Intent(context, QuickAddActivity::class.java)
            .setData(Uri.parse("otda-widget://add/$appWidgetId"))
        if (!projectId.isNullOrBlank() && projectId != "all") intent.putExtra(QuickAddActivity.EXTRA_PROJECT, projectId)
        return PendingIntent.getActivity(context, appWidgetId * 10 + 6, intent, WidgetIntents.flags(mutable = false))
    }

    /** A real otda:// link, so MainActivity hands it to Dart (which also refreshes the widget on start). */
    private fun openApp(context: Context, appWidgetId: Int, slot: Int): PendingIntent {
        val intent = WidgetIntents.deepLink(context, Uri.parse("otda://upcoming"))
        return PendingIntent.getActivity(context, appWidgetId * 10 + 6 + slot, intent, WidgetIntents.flags(mutable = false))
    }
}
