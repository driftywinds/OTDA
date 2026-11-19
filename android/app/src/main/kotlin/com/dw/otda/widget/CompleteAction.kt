package com.dw.otda.widget

import android.content.Context
import android.net.Uri
import androidx.glance.GlanceId
import androidx.glance.action.ActionParameters
import androidx.glance.appwidget.action.ActionCallback
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import org.json.JSONArray
import org.json.JSONObject

/** Payload key carrying the `otda://...` URI of the tapped element into the callbacks. */
internal val actionUriKey = ActionParameters.Key<String>("otda.widget.uri")

class CompleteAction : ActionCallback {

    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val uri = parameters[actionUriKey]?.let(Uri::parse) ?: return
        val taskId = uri.getQueryParameter("id")
        if (taskId != null) markTaskDone(context, taskId, uri.getQueryParameter("day"))
        TasksWidget().update(context, glanceId)
        sendToDart(context, uri)
    }
}

/** Pulls the row through home_widget's background broadcast so the app can push the change. */
internal fun sendToDart(context: Context, uri: Uri) {
    runCatching { HomeWidgetBackgroundIntent.getBroadcast(context, uri).send() }
}

/**
 * Optimistically flips the row in every stored snapshot before the app confirms it. A snapshot that
 * cannot be parsed is left untouched: the next app write replaces it anyway.
 */
internal fun markTaskDone(context: Context, taskId: String, day: String?) {
    val prefs = widgetPrefs(context)
    val editor = prefs.edit()
    var changed = false
    for ((key, value) in prefs.all) {
        if (!key.startsWith("snapshot_") || value !is String) continue
        val updated = runCatching { markInJson(value, taskId, day) }.getOrNull() ?: continue
        if (updated != value) {
            editor.putString(key, updated)
            changed = true
        }
    }
    if (changed) editor.apply()
}

private fun markInJson(raw: String, taskId: String, day: String?): String? {
    val text = raw.trim()
    if (text.startsWith("[")) {
        val rows = JSONArray(text)
        return if (markRows(rows, taskId, day) > 0) rows.toString() else null
    }
    val root = JSONObject(text)
    var touched = 0
    for (name in SNAPSHOT_ROW_KEYS) {
        val rows = root.optJSONArray(name) ?: continue
        touched += markRows(rows, taskId, day)
    }
    return if (touched > 0) root.toString() else null
}

private fun markRows(rows: JSONArray, taskId: String, day: String?): Int {
    var touched = 0
    for (index in 0 until rows.length()) {
        val row = rows.optJSONObject(index) ?: continue
        if (row.optString("id") != taskId) continue
        val rowDay = row.opt("day")?.toString()
        if (day != null && rowDay != null && rowDay != day) continue
        row.put("done", true)
        touched++
    }
    return touched
}

internal val SNAPSHOT_ROW_KEYS = listOf("rows", "items", "tasks")
