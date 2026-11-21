package com.dw.otda.widget

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import com.dw.otda.R
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import org.json.JSONArray
import org.json.JSONObject

/*
 * Everything the widget knows lives in one SharedPreferences file that the Dart side writes through
 * home_widget. The widget only ever reads that file and flips rows in it: it never waits for the
 * app, the database or the network. The app applies the queued changes and syncs afterwards.
 */

/**
 * Snapshot keys the Dart side writes: `snapshot_all` for the combined list, `snapshot_<projectId>`
 * per project. The project a widget shows lives in `widget_<appWidgetId>_project`.
 */
internal fun widgetPrefs(context: Context): SharedPreferences =
    context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)

internal fun widgetProjectKey(appWidgetId: Int): String = "widget_${appWidgetId}_project"

private val widgetProjectKeyPattern = Regex("""widget_\d+_project""")

internal fun snapshotKey(projectId: String?): String =
    if (projectId.isNullOrBlank() || projectId == "all") "snapshot_all" else "snapshot_$projectId"

/** Recomputes `active_projects` from the widget project bindings, so the app knows what to snapshot. */
internal fun updateActiveProjects(prefs: SharedPreferences) {
    val projects = prefs.all.entries
        .filter { (key, _) -> widgetProjectKeyPattern.matches(key) }
        .mapNotNull { (_, value) -> (value as? String)?.takeIf { it.isNotBlank() } }
        .distinct()
        .sorted()
    prefs.edit().putString("active_projects", projects.joinToString(",")).apply()
}

/** Pulls a request through home_widget's background broadcast so the app can act on it. */
internal fun sendToDart(context: Context, uri: Uri) {
    runCatching { HomeWidgetBackgroundIntent.getBroadcast(context, uri).send() }
}

/**
 * Asks Dart to rebuild the snapshots. Throttled, so a device with no signed-in account does not
 * loop: Dart answers by writing prefs and redrawing, and a redraw that still finds nothing must
 * not ask again at once.
 */
internal fun requestSnapshot(context: Context, prefs: SharedPreferences) {
    val now = System.currentTimeMillis()
    if (now - prefs.getLong("snapshotRequestedAt", 0L) < 60_000L) return
    prefs.edit().putLong("snapshotRequestedAt", now).apply()
    sendToDart(context, Uri.parse("otda://refresh"))
}

internal val SNAPSHOT_ROW_KEYS = listOf("rows", "items", "tasks")

// ---- the snapshot ----------------------------------------------------------------------------

internal class Snapshot(val name: String, val rows: List<WidgetRow>, val more: Int) {
    companion object {
        /** Returns null when nothing usable is stored: the widget then shows the calm setup card. */
        fun parse(raw: String?): Snapshot? {
            val text = raw?.trim().orEmpty()
            if (text.isEmpty()) return null
            return try {
                val root = if (text.startsWith("[")) {
                    JSONObject().put("rows", JSONArray(text))
                } else {
                    JSONObject(text)
                }
                val project = root.optJSONObject("project")
                val name = project?.optString("name") ?: root.optString("name")
                val rows = parseRows(root)
                // An empty list is a valid snapshot ("Nothing coming up"), not a missing one. Only
                // JSON that carries no row list at all is treated as not written yet.
                val hasRows = SNAPSHOT_ROW_KEYS.any { root.has(it) }
                if (name.isBlank() && rows.isEmpty() && !hasRows) return null
                Snapshot(name, rows, root.optInt("more", 0).coerceAtLeast(0))
            } catch (t: Throwable) {
                null
            }
        }

        private fun parseRows(root: JSONObject): List<WidgetRow> {
            val array = root.optJSONArray("rows")
                ?: root.optJSONArray("items")
                ?: root.optJSONArray("tasks")
                ?: return emptyList()
            val rows = ArrayList<WidgetRow>(array.length())
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val type = item.optString("t")
                val isTask = type == "task" || (type.isEmpty() && item.has("id") && !item.has("label"))
                if (!isTask) {
                    val label = item.optString("label")
                    if (label.isNotBlank()) rows.add(WidgetRow.Section(label))
                    continue
                }
                rows.add(
                    WidgetRow.Task(
                        id = item.optString("id").ifBlank { "row${rows.size}" },
                        title = item.optString("title").ifBlank { item.optString("name") }.ifBlank { "Untitled" },
                        right = item.optString("right").ifBlank { item.optString("meta") }.takeIf { it.isNotBlank() },
                        day = item.opt("day")?.toString()?.takeIf { it.isNotBlank() && it != "null" },
                        done = item.optBoolean("done", false),
                        overdue = item.optBoolean("overdue", false),
                    ),
                )
            }
            return rows
        }
    }
}

internal sealed interface WidgetRow {
    class Section(val label: String) : WidgetRow
    class Task(
        val id: String,
        val title: String,
        val right: String?,
        val day: String?,
        val done: Boolean,
        val overdue: Boolean,
    ) : WidgetRow
}

/**
 * The rows the settings leave in: completed tasks only when asked for, headings only when shown,
 * and never a heading with nothing under it.
 */
internal fun visibleRows(rows: List<WidgetRow>, style: WidgetStyle, showSections: Boolean): List<WidgetRow> {
    val kept = rows.filter { it !is WidgetRow.Task || style.showCompleted || !it.done }
    val out = ArrayList<WidgetRow>(kept.size)
    for ((index, row) in kept.withIndex()) {
        if (row is WidgetRow.Section) {
            val next = kept.getOrNull(index + 1)
            if (!showSections || next == null || next is WidgetRow.Section) continue
        }
        out.add(row)
    }
    return out
}

// ---- the look --------------------------------------------------------------------------------

private fun readInt(prefs: SharedPreferences, key: String, fallback: Int): Int =
    when (val v = prefs.all[key]) {
        is Number -> v.toInt()
        is String -> v.toIntOrNull() ?: fallback
        else -> fallback
    }

private fun readBool(prefs: SharedPreferences, key: String, fallback: Boolean): Boolean =
    (prefs.all[key] as? Boolean) ?: fallback

private fun readChoice(prefs: SharedPreferences, key: String, allowed: Set<String>, fallback: String): String =
    (prefs.all[key] as? String)?.takeIf { it in allowed } ?: fallback

/**
 * How the widget looks, from the Settings screen's "Home screen widget" section. The keys and
 * defaults mirror `lib/src/widget/widget_settings.dart`; a missing or odd value is the default.
 * The theme picks a layout file (system layouts follow day/night through colour resources, light
 * and dark carry fixed colours), so a theme change swaps layouts instead of recolouring views.
 */
internal class WidgetStyle(
    val scale: Float,
    val density: Float,
    val theme: String,
    val backgroundAlpha: Float,
    val showSections: Boolean,
    val showDue: Boolean,
    val showCompleted: Boolean,
) {
    val rootLayout: Int
        get() = when (theme) {
            "light" -> R.layout.widget_root_light
            "dark" -> R.layout.widget_root_dark
            else -> R.layout.widget_root_system
        }
    val taskLayout: Int
        get() = when (theme) {
            "light" -> R.layout.widget_task_light
            "dark" -> R.layout.widget_task_dark
            else -> R.layout.widget_task_system
        }
    val sectionLayout: Int
        get() = when (theme) {
            "light" -> R.layout.widget_section_light
            "dark" -> R.layout.widget_section_dark
            else -> R.layout.widget_section_system
        }

    /** A font size, in sp, at the chosen text size. */
    fun sp(base: Int): Float = base * scale

    /** The height of a task row in dp: text size and the spacing choice together. */
    val rowHeightDp: Float get() = 40f * density * maxOf(1f, scale)

    companion object {
        fun read(prefs: SharedPreferences): WidgetStyle = WidgetStyle(
            scale = readInt(prefs, "widget_text_scale", 100).coerceIn(70, 160) / 100f,
            density = when (readChoice(prefs, "widget_density", setOf("compact", "standard", "roomy"), "standard")) {
                "compact" -> 0.85f
                "roomy" -> 1.2f
                else -> 1f
            },
            theme = readChoice(prefs, "widget_theme", setOf("system", "light", "dark"), "system"),
            backgroundAlpha = readInt(prefs, "widget_background", 100).coerceIn(20, 100) / 100f,
            showSections = readBool(prefs, "widget_show_sections", true),
            showDue = readBool(prefs, "widget_show_due", true),
            showCompleted = readBool(prefs, "widget_show_completed", true),
        )
    }
}

// ---- refreshing state ------------------------------------------------------------------------

internal const val REFRESH_TIMEOUT_MS = 8_000L

/** Raises the "refreshing" flag so the next redraw shows the refreshing state. */
internal fun markRefreshing(context: Context) {
    widgetPrefs(context).edit()
        .putBoolean("refreshing", true)
        .putLong("refreshingSince", System.currentTimeMillis())
        .commit()
}

/** True while a refresh is in flight; a flag older than the timeout is treated as stuck and ignored. */
internal fun isRefreshing(context: Context): Boolean {
    val prefs = widgetPrefs(context)
    if (prefs.all["refreshing"] != true) return false
    val since = (prefs.all["refreshingSince"] as? Number)?.toLong() ?: 0L
    return System.currentTimeMillis() - since < REFRESH_TIMEOUT_MS
}

// ---- ticking and un-ticking ------------------------------------------------------------------

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
        kept.add(JSONObject().put("id", taskId).put("day", day ?: "").put("done", done).put("at", at))
        prefs.edit().putString("pending_ops", JSONArray(kept).toString()).commit()
    }
}

/**
 * The whole tap, start to finish and entirely local: flip the row in every stored snapshot, redraw
 * the lists, queue the change for the app, and wake the app so it can save and sync it.
 */
internal fun toggleTask(context: Context, taskId: String, day: String?, done: Boolean) {
    markTaskDone(context, taskId, day, done)
    refreshWidgetLists(context)
    enqueuePendingOp(context, taskId, day, done)
    val uri = Uri.parse("otda://complete").buildUpon().appendQueryParameter("id", taskId).apply {
        if (!day.isNullOrBlank()) appendQueryParameter("day", day)
        if (!done) appendQueryParameter("done", "0")
    }.build()
    sendToDart(context, uri)
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
    for (index in 0 until rows.length()) rows.optJSONObject(index)?.let { list.add(it) }
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
        if (section >= 0) {
            list.add(section + 1, row)
        } else {
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
