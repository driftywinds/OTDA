package com.dw.otda.widget

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.text.SpannableString
import android.text.Spanned
import android.text.style.StrikethroughSpan
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import com.dw.otda.R

/** Feeds the widget's scrolling list. The rows come straight from the stored snapshot. */
class TasksWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        TasksFactory(
            applicationContext,
            intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID),
        )
}

private class TasksFactory(private val context: Context, private val appWidgetId: Int) :
    RemoteViewsService.RemoteViewsFactory {

    @Volatile private var rows: List<WidgetRow> = emptyList()
    @Volatile private var style: WidgetStyle = WidgetStyle.read(widgetPrefs(context))

    override fun onCreate() = load()

    /** Called by the system after notifyAppWidgetViewDataChanged: re-read the prefs, nothing else. */
    override fun onDataSetChanged() = load()

    override fun onDestroy() {}

    private fun load() {
        val prefs = widgetPrefs(context)
        val current = WidgetStyle.read(prefs)
        val projectId = prefs.getString(widgetProjectKey(appWidgetId), null)
        val snapshot = Snapshot.parse(prefs.getString(snapshotKey(projectId), null))
        // Narrow widgets drop the headings; the width is in dp.
        val width = runCatching {
            AppWidgetManager.getInstance(context)
                .getAppWidgetOptions(appWidgetId)
                .getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 250)
        }.getOrDefault(250)
        style = current
        rows = if (snapshot == null) {
            emptyList()
        } else {
            visibleRows(snapshot.rows, current, showSections = current.showSections && width >= 250)
        }
    }

    override fun getCount(): Int = rows.size

    override fun getViewAt(position: Int): RemoteViews {
        val list = rows
        val style = style
        return when (val row = list.getOrNull(position)) {
            is WidgetRow.Section -> sectionView(row, style)
            is WidgetRow.Task -> taskView(row, style)
            null -> RemoteViews(context.packageName, style.sectionLayout)
        }
    }

    private fun sectionView(row: WidgetRow.Section, style: WidgetStyle): RemoteViews {
        val views = RemoteViews(context.packageName, style.sectionLayout)
        views.setTextViewText(R.id.section, row.label)
        views.setTextViewTextSize(R.id.section, TypedValue.COMPLEX_UNIT_SP, style.sp(12))
        return views
    }

    private fun taskView(task: WidgetRow.Task, style: WidgetStyle): RemoteViews {
        val views = RemoteViews(context.packageName, style.taskLayout)
        val density = context.resources.displayMetrics.density
        // Row height is padding around a 24dp check, so the whole row (not just the icon) is the target.
        val pad = (((style.rowHeightDp - 24f) / 2f).coerceAtLeast(2f) * density).toInt()
        val side = (8f * density).toInt()
        views.setViewPadding(R.id.check_area, side, pad, side, pad)

        views.setViewVisibility(R.id.check_open, if (task.done) View.GONE else View.VISIBLE)
        views.setViewVisibility(R.id.check_done, if (task.done) View.VISIBLE else View.GONE)
        views.setContentDescription(
            R.id.check_area,
            if (task.done) "Completed ${task.title}, tap to undo" else "Complete ${task.title}",
        )

        // Two views per state instead of recolouring one: the colours stay in the layout files, so
        // day/night follows the system without any code running.
        views.setViewVisibility(R.id.title, if (task.done) View.GONE else View.VISIBLE)
        views.setViewVisibility(R.id.title_done, if (task.done) View.VISIBLE else View.GONE)
        views.setTextViewText(R.id.title, task.title)
        views.setTextViewText(R.id.title_done, struck(task.title))
        views.setTextViewTextSize(R.id.title, TypedValue.COMPLEX_UNIT_SP, style.sp(16))
        views.setTextViewTextSize(R.id.title_done, TypedValue.COMPLEX_UNIT_SP, style.sp(16))

        val right = task.right.takeIf { style.showDue }
        views.setViewVisibility(R.id.right, if (right != null && !task.overdue) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.right_overdue, if (right != null && task.overdue) View.VISIBLE else View.GONE)
        if (right != null) {
            views.setTextViewText(R.id.right, right)
            views.setTextViewText(R.id.right_overdue, right)
            views.setTextViewTextSize(R.id.right, TypedValue.COMPLEX_UNIT_SP, style.sp(14))
            views.setTextViewTextSize(R.id.right_overdue, TypedValue.COMPLEX_UNIT_SP, style.sp(14))
        }

        val day = task.day.orEmpty()
        views.setOnClickFillInIntent(
            R.id.check_area,
            Intent()
                .putExtra(WidgetIntents.EXTRA_OP, WidgetIntents.OP_TOGGLE)
                .putExtra(WidgetIntents.EXTRA_ID, task.id)
                .putExtra(WidgetIntents.EXTRA_DAY, day)
                .putExtra(WidgetIntents.EXTRA_DONE, !task.done),
        )
        views.setOnClickFillInIntent(
            R.id.row,
            Intent()
                .putExtra(WidgetIntents.EXTRA_OP, WidgetIntents.OP_OPEN)
                .putExtra(WidgetIntents.EXTRA_ID, task.id)
                .putExtra(WidgetIntents.EXTRA_DAY, day),
        )
        return views
    }

    private fun struck(text: String): CharSequence =
        SpannableString(text).apply { setSpan(StrikethroughSpan(), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 6

    override fun getItemId(position: Int): Long = position.toLong()

    override fun hasStableIds(): Boolean = false
}
