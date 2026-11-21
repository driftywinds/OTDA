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

/**
 * The widget's check mark. Runs entirely inside the widget's own process: it flips the row in the
 * stored snapshots, queues the change for the app and redraws, with no activity, no Flutter and no
 * network. The app applies the queued change and syncs in the background.
 */
class CompleteAction : ActionCallback {

    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val uri = parameters[actionUriKey]?.let(Uri::parse) ?: return
        val taskId = uri.getQueryParameter("id")
        if (taskId != null) {
            val day = uri.getQueryParameter("day")
            val done = uri.getQueryParameter("done") != "0"
            markTaskDone(context, taskId, day, done)
            enqueuePendingOp(context, taskId, day, done)
        }
        updateWidgets(context)
        sendToDart(context, uri)
    }
}

private val pendingLock = Any()

/**
 * Durable queue of changes made on the widget that the app has not applied yet (`pending_ops`).
 * The Dart side applies them in order and records how far it got in `pending_ack`; entries at or
 * below the ack are pruned here. Applying an op twice is harmless, so a lost ack only repeats work.
 */
internal fun enqueuePendingOp(context: Context, taskId: String, day: String?, done: Boolean) {
    synchronized(pendingLock) {
        val prefs = widgetPrefs(context)
        val ack = prefs.getString("pending_ack", null)?.toLongOrNull() ?: 0L
        val kept = ArrayList<JSONObject>()
        runCatching {
            val old = JSONArray(prefs.getString("pending_ops", null) ?: "[]")
            for (i in 0 until old.length()) {
                val op = old.optJSONObject(i) ?: continue
                if (op.optLong("at") > ack) kept.add(op)
            }
        }
        val last = kept.maxOfOrNull { it.optLong("at") } ?: 0L
        val at = maxOf(System.currentTimeMillis(), last + 1)
        kept.add(
            JSONObject().put("id", taskId).put("day", day ?: "").put("done", done).put("at", at),
        )
        prefs.edit().putString("pending_ops", JSONArray(kept).toString()).commit()
    }
}

/** Pulls the row through home_widget's background broadcast so the app can push the change. */
internal fun sendToDart(context: Context, uri: Uri) {
    runCatching { HomeWidgetBackgroundIntent.getBroadcast(context, uri).send() }
}

/**
 * Optimistically flips the row in every stored snapshot before the app confirms it, in either
 * direction: [done] true moves it under "Done today", false puts it back in its own section.
 * A snapshot that cannot be parsed is left untouched: the next app write replaces it anyway.
 */
internal fun markTaskDone(context: Context, taskId: String, day: String?, done: Boolean = true) {
    val prefs = widgetPrefs(context)
    val editor = prefs.edit()
    var changed = false
    for ((key, value) in prefs.all) {
        if (!key.startsWith("snapshot_") || value !is String) continue
        val updated = runCatching { markInJson(value, taskId, day, done) }.getOrNull() ?: continue
        if (updated != value) {
            editor.putString(key, updated)
            changed = true
        }
    }
    // commit(), not apply(): the redraw that follows reads these prefs at once.
    if (changed) editor.commit()
}

private fun markInJson(raw: String, taskId: String, day: String?, done: Boolean): String? {
    val text = raw.trim()
    if (text.startsWith("[")) {
        val rows = toggleRows(JSONArray(text), taskId, day, done, "") ?: return null
        return rows.toString()
    }
    val root = JSONObject(text)
    val today = root.optString("today")
    var touched = 0
    for (name in SNAPSHOT_ROW_KEYS) {
        val rows = root.optJSONArray(name) ?: continue
        val updated = toggleRows(rows, taskId, day, done, today) ?: continue
        root.put(name, updated)
        touched++
    }
    return if (touched > 0) root.toString() else null
}

private const val DONE_TODAY = "Done today"
private val SECTION_ORDER = listOf(DONE_TODAY, "Overdue", "Today", "Tomorrow", "This week", "Later", "Anytime")

/**
 * Returns the rows with the task flipped and moved, or null when it is not in them. JSONArray
 * cannot insert (put(index, x) overwrites), so the work is done on a list.
 */
private fun toggleRows(rows: JSONArray, taskId: String, day: String?, done: Boolean, today: String): JSONArray? {
    val list = ArrayList<JSONObject>(rows.length() + 1)
    for (index in 0 until rows.length()) rows.optJSONObject(index)?.let(list::add)
    val at = list.indexOfFirst {
        if (it.optString("t") == "section" || it.optString("id") != taskId) return@indexOfFirst false
        val rowDay = it.opt("day")?.toString()
        day == null || rowDay == null || rowDay == day
    }
    if (at < 0) return null
    val row = list.removeAt(at)
    row.put("done", done)
    if (done) {
        val section = sectionIndex(list, DONE_TODAY)
        if (section >= 0) list.add(section + 1, row) else {
            list.add(0, row)
            list.add(0, JSONObject().put("t", "section").put("label", DONE_TODAY))
        }
    } else {
        insertOpen(list, row, today)
    }
    return JSONArray(list)
}

private fun sectionIndex(list: List<JSONObject>, label: String): Int =
    list.indexOfFirst { it.optString("t") == "section" && it.optString("label") == label }

/** Puts an un-ticked row back in the section its day belongs to, in day order. */
private fun insertOpen(list: MutableList<JSONObject>, row: JSONObject, todayText: String) {
    val today = runCatching { java.time.LocalDate.parse(todayText) }.getOrElse { java.time.LocalDate.now() }
    val rowDay = row.opt("day")?.toString().orEmpty().takeIf { it != "null" }.orEmpty()
    val label = sectionFor(rowDay, today)
    val key = rowDay + if (rowDay == today.toString()) row.optString("right") else ""
    var section = sectionIndex(list, label)
    if (section < 0) {
        // Create the heading before the first section that sorts after it, else at the end.
        val mine = SECTION_ORDER.indexOf(label)
        val before = list.indexOfFirst {
            it.optString("t") == "section" && SECTION_ORDER.indexOf(it.optString("label")) > mine
        }
        section = if (before < 0) list.size else before
        list.add(section, JSONObject().put("t", "section").put("label", label))
    }
    var position = section + 1
    while (position < list.size && list[position].optString("t") != "section") {
        val other = list[position]
        val otherDay = other.opt("day")?.toString().orEmpty().takeIf { it != "null" }.orEmpty()
        val otherKey = otherDay + if (otherDay == today.toString()) other.optString("right") else ""
        if (otherKey > key) break
        position++
    }
    list.add(position, row)
}

/** Mirrors `_sectionFor` in lib/src/widget/snapshot.dart. */
private fun sectionFor(day: String, today: java.time.LocalDate): String {
    if (day.isEmpty()) return "Anytime"
    val date = runCatching { java.time.LocalDate.parse(day) }.getOrNull() ?: return "Later"
    return when {
        date.isBefore(today) -> "Overdue"
        date == today -> "Today"
        date == today.plusDays(1) -> "Tomorrow"
        !date.isAfter(today.plusDays(7)) -> "This week"
        else -> "Later"
    }
}

internal val SNAPSHOT_ROW_KEYS = listOf("rows", "items", "tasks")
