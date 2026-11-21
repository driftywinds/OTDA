package com.dw.otda.widget

import org.json.JSONArray
import org.json.JSONObject

/*
 * The widget's data model, with no Android types in it (only org.json), so the logic that decides what
 * a row looks like after a tap can be exercised on a plain JVM.
 *
 * HOW A TAP WORKS (read this before changing anything):
 *
 *  - The Dart side writes a *snapshot*: the truth from the database, plus `ack`, the newest widget op it
 *    had already applied when it read the database.
 *  - A tap on the widget never edits the snapshot. It appends a [PendingOp] to `pending_ops`.
 *  - Every time the widget is drawn, the ops newer than the snapshot's `ack` are laid over the snapshot
 *    (see [overlayPending]). So a tap is visible at once, and a snapshot that Dart finishes building a
 *    few seconds later can never undo it: it either already contains the op (ack >= op.at, the overlay
 *    skips it) or it does not (the overlay applies it again, on top of the new truth).
 *
 * A repeating task is the reason ops are matched by (series, occurrence date) as well as by row id:
 * ticking series S writes a separate record R for that date and moves S to its next date, so the row
 * the person tapped (S) and the row that shows "done" afterwards (R) have different ids.
 */

internal val SNAPSHOT_ROW_KEYS = listOf("rows", "items", "tasks")

/** One tick or un-tick made on the widget that the app may not have applied yet. */
internal class PendingOp(
    /** The id of the row that was tapped. */
    val id: String,
    /** The row's day at the time of the tap; null or blank for "Anytime". */
    val day: String?,
    /** For a repeating task: the series id (for the series row and for its records alike). */
    val sid: String?,
    /** For a repeating task: the occurrence date the tapped row stood for. */
    val occ: String?,
    /** True to complete, false to reopen. */
    val done: Boolean,
    /** Monotonic enqueue stamp; also the op's position in the queue. */
    val at: Long,
) {
    fun toJson(): JSONObject {
        val json = JSONObject().put("id", id).put("day", day ?: "").put("done", done).put("at", at)
        if (!sid.isNullOrBlank()) json.put("sid", sid)
        if (!occ.isNullOrBlank()) json.put("occ", occ)
        return json
    }

    companion object {
        fun fromJson(json: JSONObject): PendingOp? {
            val id = json.optString("id")
            if (id.isBlank()) return null
            return PendingOp(
                id = id,
                day = json.optString("day").takeIf { it.isNotBlank() && it != "null" },
                sid = json.optString("sid").takeIf { it.isNotBlank() && it != "null" },
                occ = json.optString("occ").takeIf { it.isNotBlank() && it != "null" },
                done = json.optBoolean("done", true),
                at = json.optLong("at", 0L),
            )
        }

        fun parseAll(raw: String?): List<PendingOp> {
            val text = raw?.trim().orEmpty()
            if (text.isEmpty()) return emptyList()
            return try {
                val array = JSONArray(text)
                val out = ArrayList<PendingOp>(array.length())
                for (i in 0 until array.length()) {
                    array.optJSONObject(i)?.let { fromJson(it) }?.let { out.add(it) }
                }
                out.sortedBy { it.at }
            } catch (t: Throwable) {
                emptyList()
            }
        }
    }
}

internal class Snapshot(val name: String, val rows: List<WidgetRow>, val more: Int) {
    companion object {
        /**
         * Returns null when nothing usable is stored: the widget then shows the calm setup card.
         *
         * [ops] are the taps not yet applied by the app; every one newer than the snapshot's own `ack`
         * is laid over the rows. [pendingAck] stands in for a snapshot written before `ack` existed.
         */
        fun parse(raw: String?, ops: List<PendingOp> = emptyList(), pendingAck: Long = 0L): Snapshot? {
            val text = raw?.trim().orEmpty()
            if (text.isEmpty()) return null
            return try {
                val root = if (text.startsWith("[")) {
                    JSONObject().put("rows", JSONArray(text))
                } else {
                    JSONObject(text)
                }
                if (ops.isNotEmpty()) overlayPending(root, ops, if (root.has("ack")) root.optLong("ack") else pendingAck)
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
                        sid = item.optString("sid").takeIf { it.isNotBlank() && it != "null" },
                        occ = item.optString("occ").takeIf { it.isNotBlank() && it != "null" },
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
        /** Series id of a repeating task (set on the series row and on its occurrence records). */
        val sid: String? = null,
        /** The occurrence date this row stands for. */
        val occ: String? = null,
    ) : WidgetRow
}

/**
 * The rows the settings leave in: completed tasks only when asked for, headings only when shown,
 * and never a heading with nothing under it.
 */
internal fun visibleRows(rows: List<WidgetRow>, showCompleted: Boolean, showSections: Boolean): List<WidgetRow> {
    val kept = rows.filter { it !is WidgetRow.Task || showCompleted || !it.done }
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

// ---- the overlay -----------------------------------------------------------------------------

/**
 * Lays every op newer than [ack] over the snapshot's row lists, in the order the ops were made.
 * Idempotent per op: an op the snapshot already reflects changes nothing visible.
 */
internal fun overlayPending(root: JSONObject, ops: List<PendingOp>, ack: Long) {
    val fresh = ops.filter { it.at > ack }.sortedBy { it.at }
    if (fresh.isEmpty()) return
    val today = root.optString("today")
    for (name in SNAPSHOT_ROW_KEYS) {
        var rows = root.optJSONArray(name) ?: continue
        for (op in fresh) rows = applyOp(rows, op, today) ?: rows
        root.put(name, rows)
    }
}

private const val DONE_TODAY = "Done today"
private val SECTION_ORDER = listOf(DONE_TODAY, "Overdue", "Today", "Tomorrow", "This week", "Later", "Anytime")

private fun dayOf(row: JSONObject): String? =
    row.opt("day")?.toString()?.takeIf { it.isNotBlank() && it != "null" }

/**
 * Does [op] concern [row]? Either it is the very row that was tapped (same id, and the same day when
 * both know it), or it is the same occurrence of the same repeating series: the row the tap changed
 * into after the app ticked it (the record R) is not the row that was tapped (the series S).
 */
internal fun opMatches(row: JSONObject, op: PendingOp): Boolean {
    if (row.optString("t") == "section") return false
    if (row.optString("id") == op.id) {
        val rowDay = dayOf(row)
        if (op.day == null || rowDay == null || rowDay == op.day) return true
    }
    val sid = op.sid
    val occ = op.occ
    return sid != null && occ != null && row.optString("sid") == sid && row.optString("occ") == occ
}

/**
 * Returns the rows with the op applied, or null when no row matches. JSONArray cannot insert
 * (put(index, x) overwrites), so the work is done on a list.
 */
internal fun applyOp(rows: JSONArray, op: PendingOp, today: String): JSONArray? {
    val list = ArrayList<JSONObject>(rows.length() + 2)
    for (index in 0 until rows.length()) rows.optJSONObject(index)?.let { list.add(it) }
    val at = list.indexOfFirst { opMatches(it, op) }
    if (at < 0) return null
    val row = list[at]
    // Already in the state the op asks for: nothing to move, and no row jumping to the top of
    // "Done today" because a snapshot that already holds the op met the overlay again.
    if (row.optBoolean("done", false) == op.done) return rows
    list.removeAt(at)
    row.put("done", op.done)
    if (op.done) {
        row.put("overdue", false)
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

/** Puts a re-opened row back in the section its day belongs to, in day order. */
private fun insertOpen(list: MutableList<JSONObject>, row: JSONObject, todayText: String) {
    val today = runCatching { java.time.LocalDate.parse(todayText) }.getOrElse { java.time.LocalDate.now() }
    val rowDay = dayOf(row).orEmpty()
    val label = sectionFor(rowDay, today)
    row.put("overdue", label == "Overdue")
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
        val otherDay = dayOf(other).orEmpty()
        val otherKey = otherDay + if (otherDay == today.toString()) other.optString("right") else ""
        if (otherKey > key) break
        position++
    }
    list.add(position, row)
}

/** Mirrors `_sectionFor` in lib/src/widget/snapshot.dart. */
internal fun sectionFor(day: String, today: java.time.LocalDate): String {
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
