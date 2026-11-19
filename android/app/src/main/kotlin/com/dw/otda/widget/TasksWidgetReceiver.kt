package com.dw.otda.widget

import android.content.Context
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver

class TasksWidgetReceiver : GlanceAppWidgetReceiver() {

    override val glanceAppWidget: GlanceAppWidget = TasksWidget()

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        val prefs = widgetPrefs(context)
        val editor = prefs.edit()
        appWidgetIds.forEach { editor.remove(widgetProjectKey(it)) }
        editor.apply()
        updateActiveProjects(prefs)
        super.onDeleted(context, appWidgetIds)
    }
}
