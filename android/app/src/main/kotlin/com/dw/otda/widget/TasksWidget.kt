package com.dw.otda.widget

import com.dw.otda.CompleteActivity

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.Action
import androidx.glance.action.actionParametersOf
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.lazy.LazyColumn
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.color.ColorProvider as dayNightColor
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextDecoration
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import com.dw.otda.MainActivity
import com.dw.otda.QuickAddActivity
import com.dw.otda.R
import org.json.JSONArray
import org.json.JSONObject

/**
 * Snapshot keys the Dart side writes through home_widget:
 * `snapshot_all` for the combined list, `snapshot_<projectId>` per project. The project a widget
 * shows lives in `widget_<appWidgetId>_project`.
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

/** Asks every instance of this widget to redraw after the prefs changed outside the system flow. */
internal fun requestWidgetUpdate(context: Context) {
    // Update the Glance instances directly. The ACTION_APPWIDGET_UPDATE broadcast
    // used to be the only signal here, and a widget whose row was just ticked could
    // keep the old snapshot until the next broadcast or the app's own push.
    CoroutineScope(Dispatchers.Default).launch { updateWidgets(context) }
}

/** Redraws every instance and returns when Glance has taken the new content. */
internal suspend fun updateWidgets(context: Context) {
    val manager = GlanceAppWidgetManager(context)
    for (id in manager.getGlanceIds(TasksWidget::class.java)) {
        TasksWidget().update(context, id)
    }
}

/**
 * Asks Dart (through home_widget's background broadcast) to rebuild the snapshots. Throttled, so a
 * device with no signed-in account does not loop: Dart answers by writing prefs and redrawing, and
 * a redraw that still finds nothing must not ask again at once.
 */
internal fun requestSnapshot(context: Context, prefs: SharedPreferences) {
    val now = System.currentTimeMillis()
    if (now - prefs.getLong("snapshotRequestedAt", 0L) < 60_000L) return
    prefs.edit().putLong("snapshotRequestedAt", now).apply()
    sendToDart(context, Uri.parse("otda://refresh"))
}

class TasksWidget : GlanceAppWidget() {

    override val sizeMode: SizeMode = SizeMode.Responsive(
        setOf(DpSize(160.dp, 160.dp), DpSize(250.dp, 180.dp), DpSize(320.dp, 280.dp)),
    )

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val prefs = widgetPrefs(context)
        val appWidgetId = GlanceAppWidgetManager(context).getAppWidgetId(id)
        val projectId = prefs.getString(widgetProjectKey(appWidgetId), null)
        val snapshot = Snapshot.parse(prefs.getString(snapshotKey(projectId), null))
        // Nothing stored yet (just placed, or the app was never opened since): ask the app's
        // Dart side to write the snapshot from the on-device data, without opening the UI.
        if (snapshot == null) requestSnapshot(context, prefs)
        val style = WidgetStyle.read(prefs)
        val refreshing = isRefreshing(context)
        provideContent {
            WidgetContent(snapshot, projectId, appWidgetId, style, refreshing)
        }
    }
}

internal class Snapshot(
    val name: String,
    val glyph: String,
    val tileColor: Color,
    val rows: List<WidgetRow>,
    val more: Int,
) {
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
                val name = (project?.optString("name") ?: root.optString("name"))
                val rows = parseRows(root)
                // An empty list is a valid snapshot ("Nothing coming up"), not a missing one. Only
                // JSON that carries no row list at all is treated as not written yet.
                val hasRows = SNAPSHOT_ROW_KEYS.any { root.has(it) }
                if (name.isBlank() && rows.isEmpty() && !hasRows) return null
                Snapshot(
                    name = name,
                    glyph = glyphFor(project, root, name),
                    tileColor = tileColor(project, root),
                    rows = rows,
                    more = root.optInt("more", 0).coerceAtLeast(0),
                )
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
                        title = item.optString("title")
                            .ifBlank { item.optString("name") }
                            .ifBlank { "Untitled" },
                        right = item.optString("right")
                            .ifBlank { item.optString("meta") }
                            .takeIf { it.isNotBlank() },
                        day = item.opt("day")
                            ?.toString()
                            ?.takeIf { it.isNotBlank() && it != "null" },
                        done = item.optBoolean("done", false),
                        overdue = item.optBoolean("overdue", false),
                    ),
                )
            }
            return rows
        }

        private fun glyphFor(project: JSONObject?, root: JSONObject, name: String): String =
            (project?.optString("emoji") ?: root.optString("emoji"))
                .takeIf { it.isNotBlank() }
                ?: name.firstOrNull()?.uppercase()
                ?: "•"

        private fun tileColor(project: JSONObject?, root: JSONObject): Color =
            when (val value = project?.opt("color") ?: root.opt("color")) {
                is Number -> Color(0xFF000000L or value.toLong())
                is String -> runCatching { Color(android.graphics.Color.parseColor(value)) }
                    .getOrDefault(BrandNavy)
                else -> BrandNavy
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

private val BrandNavy = Color(0xFF0F172A)
private val LightSurface = Color(0xFFFFFFFF)
private val DarkSurface = Color(0xFF242424)
private val LightOnSurface = BrandNavy
private val DarkOnSurface = Color(0xFFE8ECF2)
private val LightSecondary = Color(0xFF64748B)
private val DarkSecondary = Color(0xFF94A3B8)
private val Accent = ColorProvider(Color(0xFF34D399))
private val ErrorRed = ColorProvider(Color(0xFFE5484D))


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
    val surface: ColorProvider = when (theme) {
        "light" -> ColorProvider(LightSurface.copy(alpha = backgroundAlpha))
        "dark" -> ColorProvider(DarkSurface.copy(alpha = backgroundAlpha))
        else -> dayNightColor(LightSurface.copy(alpha = backgroundAlpha), DarkSurface.copy(alpha = backgroundAlpha))
    }
    val onSurface: ColorProvider = when (theme) {
        "light" -> ColorProvider(LightOnSurface)
        "dark" -> ColorProvider(DarkOnSurface)
        else -> dayNightColor(LightOnSurface, DarkOnSurface)
    }
    val secondary: ColorProvider = when (theme) {
        "light" -> ColorProvider(LightSecondary)
        "dark" -> ColorProvider(DarkSecondary)
        else -> dayNightColor(LightSecondary, DarkSecondary)
    }

    /** A font size at the chosen text size. */
    fun sp(base: Int) = (base * scale).sp

    /** A length that grows with the text but never shrinks below its base (touch targets). */
    fun grow(base: Int) = (base * maxOf(1f, scale)).dp

    /** The height of a task row: text size and the spacing choice together. */
    val rowHeight get() = (40 * density * maxOf(1f, scale)).dp

    /** Titles are cut by characters (Glance has no ellipsis), so a bigger font keeps fewer. */
    fun limit(base: Int) = maxOf(8, (base / scale).toInt())

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

@Composable
private fun WidgetContent(snapshot: Snapshot?, projectId: String?, appWidgetId: Int, style: WidgetStyle, refreshing: Boolean) {
    Box(
        modifier = GlanceModifier.fillMaxSize()
            .appWidgetBackground()
            .background(style.surface)
            .cornerRadius(28.dp),
    ) {
        if (snapshot == null) {
            SetupCard(style)
        } else {
            Card(snapshot, projectId, appWidgetId, style, refreshing)
        }
    }
}

@Composable
private fun SetupCard(style: WidgetStyle) {
    val context = LocalContext.current
    Column(
        modifier = GlanceModifier.fillMaxSize()
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .clickable(actionStartActivity(appIntent(context))),
        verticalAlignment = Alignment.Vertical.CenterVertically,
        horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
    ) {
        Text(
            text = "OTDA",
            style = TextStyle(color = style.onSurface, fontSize = style.sp(20), fontWeight = FontWeight.Bold),
            maxLines = 1,
        )
        Spacer(GlanceModifier.height(4.dp))
        Text(
            text = "Open OTDA to set up",
            style = TextStyle(color = style.secondary, fontSize = style.sp(14)),
            maxLines = 2,
        )
    }
}

@Composable
private fun Card(snapshot: Snapshot, projectId: String?, appWidgetId: Int, style: WidgetStyle, refreshing: Boolean) {
    val compact = LocalSize.current.width < 250.dp
    val rows = visibleRows(snapshot.rows, style, showSections = style.showSections && !compact)
    Column(
        modifier = GlanceModifier.fillMaxSize().padding(top = 6.dp, bottom = 8.dp),
    ) {
        Header(snapshot, projectId, appWidgetId, style, refreshing)
        if (rows.isEmpty()) {
            EmptyState(style)
            return@Column
        }
        LazyColumn(modifier = GlanceModifier.fillMaxWidth().defaultWeight().padding(horizontal = 16.dp)) {
            rows.forEach { row ->
                item {
                    when (row) {
                        is WidgetRow.Section -> SectionLabel(row.label, style)
                        is WidgetRow.Task -> TaskRow(row, style)
                    }
                }
            }
        }
        if (snapshot.more > 0) {
            Text(
                text = "+${snapshot.more} more",
                modifier = GlanceModifier.padding(start = 16.dp, top = 4.dp),
                style = TextStyle(color = style.secondary, fontSize = style.sp(13)),
                maxLines = 1,
            )
        }
    }
}

/**
 * The rows the settings leave in: completed tasks only when asked for, headings only when
 * shown, and never a heading with nothing under it.
 */
private fun visibleRows(rows: List<WidgetRow>, style: WidgetStyle, showSections: Boolean): List<WidgetRow> {
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

@Composable
private fun Header(snapshot: Snapshot, projectId: String?, appWidgetId: Int, style: WidgetStyle, refreshing: Boolean) {
    val context = LocalContext.current
    Row(
        modifier = GlanceModifier.fillMaxWidth().height(style.grow(36)).padding(start = 16.dp, end = 4.dp),
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        Row(
            modifier = GlanceModifier.defaultWeight()
                .clickable(actionStartActivity(configIntent(context, appWidgetId))),
            verticalAlignment = Alignment.Vertical.CenterVertically,
        ) {
            Text(
                text = if (refreshing) "Refreshing…" else oneLine(snapshot.name.ifBlank { "OTDA" }, style.limit(40)),
                modifier = GlanceModifier.defaultWeight(),
                style = TextStyle(
                    color = style.onSurface,
                    fontSize = style.sp(20),
                    fontWeight = FontWeight.Bold,
                ),
                maxLines = 1,
            )
            Image(
                provider = ImageProvider(R.drawable.ic_widget_chevron),
                contentDescription = "Choose project",
                modifier = GlanceModifier.size(style.grow(16)),
                colorFilter = ColorFilter.tint(style.secondary),
            )
        }
        TapTarget(
            R.drawable.ic_widget_refresh,
            if (refreshing) "Refreshing" else "Refresh",
            target = 36,
            icon = 20,
            style = style,
            tint = if (refreshing) Accent else null,
        ) {
            actionStartActivity(CompleteActivity.intent(context, Uri.parse("otda://refresh")))
        }
        TapTarget(R.drawable.ic_widget_add, "New task", target = 36, icon = 20, style = style) {
            actionStartActivity(quickAddIntent(context, projectId))
        }
        TapTarget(R.drawable.ic_widget_open, "Open OTDA", target = 32, icon = 18, style = style) {
            actionStartActivity(appIntent(context))
        }
    }
}

@Composable
private fun SectionLabel(label: String, style: WidgetStyle) {
    Text(
        text = oneLine(label, style.limit(32)),
        modifier = GlanceModifier.fillMaxWidth().padding(top = 6.dp, bottom = 0.dp),
        style = TextStyle(color = style.secondary, fontSize = style.sp(12), fontWeight = FontWeight.Medium),
        maxLines = 1,
    )
}

@Composable
private fun TaskRow(task: WidgetRow.Task, style: WidgetStyle) {
    val context = LocalContext.current
    val titleStyle = TextStyle(
        color = if (task.done) style.secondary else style.onSurface,
        fontSize = style.sp(16),
        fontWeight = FontWeight.Medium,
        textDecoration = if (task.done) TextDecoration.LineThrough else TextDecoration.None,
    )
    Row(
        modifier = GlanceModifier.fillMaxWidth()
            .height(style.rowHeight)
            .clickable(actionStartActivity(deepLink(context, taskUri(task)))),
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        Box(
            modifier = GlanceModifier.size(style.grow(40))
                .clickable(actionStartActivity(CompleteActivity.intent(context, completeTaskUri(task)))),
            contentAlignment = Alignment.Center,
        ) {
            if (task.done) {
                Box(
                    modifier = GlanceModifier.size(style.grow(24)).cornerRadius(12.dp * maxOf(1f, style.scale)).background(Accent),
                    contentAlignment = Alignment.Center,
                ) {
                    Image(
                        provider = ImageProvider(R.drawable.ic_widget_check),
                        contentDescription = "Completed, tap to undo",
                        modifier = GlanceModifier.size(14.dp),
                        colorFilter = ColorFilter.tint(ColorProvider(BrandNavy)),
                    )
                }
            } else {
                Image(
                    provider = ImageProvider(R.drawable.ic_widget_circle),
                    contentDescription = "Complete ${task.title}",
                    modifier = GlanceModifier.size(style.grow(24)),
                    colorFilter = ColorFilter.tint(style.secondary),
                )
            }
        }
        Text(
            text = oneLine(task.title, style.limit(if (style.showDue) 40 else 52)),
            modifier = GlanceModifier.defaultWeight(),
            style = titleStyle,
            maxLines = 1,
        )
        if (style.showDue && task.right != null) {
            Spacer(GlanceModifier.width(8.dp))
            Text(
                text = oneLine(task.right, style.limit(18)),
                style = TextStyle(
                    color = if (task.overdue) ErrorRed else style.secondary,
                    fontSize = style.sp(14),
                ),
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun EmptyState(style: WidgetStyle) {
    Column(
        modifier = GlanceModifier.fillMaxSize().padding(vertical = 16.dp),
        verticalAlignment = Alignment.Vertical.CenterVertically,
        horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
    ) {
        Image(
            provider = ImageProvider(R.drawable.ic_widget_check),
            contentDescription = "Nothing due",
            modifier = GlanceModifier.size(28.dp),
            colorFilter = ColorFilter.tint(Accent),
        )
        Spacer(GlanceModifier.height(8.dp))
        Text(
            text = "Nothing coming up",
            style = TextStyle(color = style.onSurface, fontSize = style.sp(16), fontWeight = FontWeight.Medium),
            maxLines = 1,
        )
    }
}

@Composable
private fun TapTarget(res: Int, description: String, target: Int, icon: Int, style: WidgetStyle, tint: ColorProvider? = null, action: () -> Action) {
    Box(
        modifier = GlanceModifier.size(style.grow(target)).clickable(action()),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            provider = ImageProvider(res),
            contentDescription = description,
            modifier = GlanceModifier.size(style.grow(icon)),
            colorFilter = ColorFilter.tint(tint ?: style.onSurface),
        )
    }
}

// Glance 1.2 has no text-overflow API, so titles are cut here instead of being ellipsized.
private fun oneLine(value: String, limit: Int = 40): String =
    if (value.length <= limit) value else value.take(limit - 1).trimEnd() + "…"

// A real otda:// link, so MainActivity hands it to Dart (which also refreshes the widget on start).
private fun appIntent(context: Context): Intent = deepLink(context, Uri.parse("otda://upcoming"))

private fun configIntent(context: Context, appWidgetId: Int): Intent =
    Intent(context, TasksWidgetConfigActivity::class.java)
        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)

/** The popup composer over the current app; `project` pre-selects the widget's project. */
private fun quickAddIntent(context: Context, projectId: String?): Intent =
    Intent(context, QuickAddActivity::class.java).apply {
        if (!projectId.isNullOrBlank() && projectId != "all") putExtra(QuickAddActivity.EXTRA_PROJECT, projectId)
    }

@Suppress("unused")
private fun newTaskIntent(context: Context, projectId: String?): Intent {
    val uri = Uri.parse("otda://new").buildUpon().apply {
        if (!projectId.isNullOrBlank() && projectId != "all") appendQueryParameter("project", projectId)
    }.build()
    return deepLink(context, uri)
}

private fun taskUri(task: WidgetRow.Task): Uri {
    val base = Uri.parse("otda://task/${Uri.encode(task.id)}")
    return if (task.day.isNullOrBlank()) base else {
        base.buildUpon().appendQueryParameter("day", task.day).build()
    }
}

internal fun completeTaskUri(task: WidgetRow.Task): Uri {
    val base = Uri.parse("otda://complete").buildUpon().appendQueryParameter("id", task.id)
    if (!task.day.isNullOrBlank()) base.appendQueryParameter("day", task.day)
    // A done row's check undoes it.
    if (task.done) base.appendQueryParameter("done", "0")
    return base.build()
}

private fun completeParameters(task: WidgetRow.Task) =
    actionParametersOf(actionUriKey to completeTaskUri(task).toString())

private fun deepLink(context: Context, uri: Uri): Intent =
    Intent(Intent.ACTION_VIEW, uri).setClass(context, MainActivity::class.java)
