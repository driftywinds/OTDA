package com.dw.otda.widget

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import com.dw.otda.R
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import org.json.JSONArray

/*
 * Everything the widget knows lives in one SharedPreferences file that the Dart side writes through
 * home_widget. The widget reads the stored snapshot and lays the person's not-yet-applied taps over it
 * (see WidgetSnapshot.kt); it never edits a snapshot and never waits for the app, the database or the
 * network. The app applies the queued taps and syncs afterwards.
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

private fun readLong(prefs: SharedPreferences, key: String): Long =
    runCatching { prefs.getString(key, null)?.toLongOrNull() }.getOrNull()
        ?: runCatching { prefs.getLong(key, 0L) }.getOrDefault(0L)

/** How far the app says it has applied the widget's queue (`pending_ack`, written by Dart). */
internal fun pendingAck(prefs: SharedPreferences): Long = readLong(prefs, "pending_ack")

/** The taps the app may not have applied yet, oldest first. */
internal fun readPendingOps(prefs: SharedPreferences): List<PendingOp> =
    PendingOp.parseAll(runCatching { prefs.getString("pending_ops", null) }.getOrNull())

/**
 * The snapshot to draw: what the app last stored, with every tap it has not applied yet laid on top.
 * This is the ONLY way the widget reads rows, so the header, the list and the "+N more" line can never
 * disagree about whether a tap has happened.
 */
internal fun loadSnapshot(prefs: SharedPreferences, projectId: String?): Snapshot? =
    Snapshot.parse(prefs.getString(snapshotKey(projectId), null), readPendingOps(prefs), pendingAck(prefs))

/** Ops this old are dropped once acknowledged; a newer acknowledged op is kept so a slow snapshot still sees it. */
private const val ACKED_OP_KEEP_MS = 10 * 60 * 1000L

/**
 * Durable queue of changes made on the widget that the app has not applied yet (`pending_ops`).
 * The Dart side applies them in order and records how far it got in `pending_ack`.
 *
 * An op says what the person did to a row (tick or un-tick it), not what state the task should end up
 * in, and carries the series and occurrence date for a repeating task. The Dart side re-reads the
 * database for each op, so applying one twice (two isolates, a lost ack) does nothing the second time.
 */
internal fun enqueuePendingOp(
    context: Context,
    taskId: String,
    day: String?,
    sid: String?,
    occ: String?,
    done: Boolean,
) {
    synchronized(pendingLock) {
        val prefs = widgetPrefs(context)
        val ack = pendingAck(prefs)
        val now = System.currentTimeMillis()
        val kept = ArrayList<PendingOp>()
        for (op in readPendingOps(prefs)) {
            if (op.at > ack || op.at > now - ACKED_OP_KEEP_MS) kept.add(op)
        }
        val last = kept.maxOfOrNull { it.at } ?: 0L
        kept.add(PendingOp(taskId, day, sid, occ, done, maxOf(now, last + 1)))
        val json = JSONArray()
        kept.forEach { json.put(it.toJson()) }
        prefs.edit().putString("pending_ops", json.toString()).commit()
    }
}

/**
 * The whole tap, start to finish and entirely local: queue the change (the widget draws it at once,
 * because drawing overlays the queue), redraw the lists, and wake the app so it can save and sync it.
 * Nothing here edits a stored snapshot, so nothing the app writes can race with it.
 */
internal fun toggleTask(context: Context, taskId: String, day: String?, sid: String?, occ: String?, done: Boolean) {
    enqueuePendingOp(context, taskId, day, sid, occ, done)
    refreshWidgetLists(context)
    val uri = Uri.parse("otda://complete").buildUpon().appendQueryParameter("id", taskId).apply {
        if (!day.isNullOrBlank()) appendQueryParameter("day", day)
        if (!done) appendQueryParameter("done", "0")
    }.build()
    sendToDart(context, uri)
}
