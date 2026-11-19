package com.dw.otda.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
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
    val ids = AppWidgetManager.getInstance(context)
        .getAppWidgetIds(ComponentName(context, TasksWidgetReceiver::class.java))
    if (ids.isEmpty()) return
    context.sendBroadcast(
        Intent(context, TasksWidgetReceiver::class.java).apply {
            action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
        },
    )
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
        provideContent {
            WidgetContent(snapshot, projectId, appWidgetId)
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
private val Surface: ColorProvider = dayNightColor(Color(0xFFFFFFFF), Color(0xFF242424))
private val OnSurface: ColorProvider = dayNightColor(BrandNavy, Color(0xFFE8ECF2))
private val SecondaryText: ColorProvider = dayNightColor(Color(0xFF64748B), Color(0xFF94A3B8))
private val Accent = ColorProvider(Color(0xFF34D399))
private val ErrorRed = ColorProvider(Color(0xFFE5484D))

@Composable
private fun WidgetContent(snapshot: Snapshot?, projectId: String?, appWidgetId: Int) {
    Box(
        modifier = GlanceModifier.fillMaxSize()
            .appWidgetBackground()
            .background(Surface)
            .cornerRadius(28.dp),
    ) {
        if (snapshot == null) {
            SetupCard()
        } else {
            Card(snapshot, projectId, appWidgetId)
        }
    }
}

@Composable
private fun SetupCard() {
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
            style = TextStyle(color = OnSurface, fontSize = 20.sp, fontWeight = FontWeight.Bold),
            maxLines = 1,
        )
        Spacer(GlanceModifier.height(4.dp))
        Text(
            text = "Open OTDA to set up",
            style = TextStyle(color = SecondaryText, fontSize = 14.sp),
            maxLines = 2,
        )
    }
}

@Composable
private fun Card(snapshot: Snapshot, projectId: String?, appWidgetId: Int) {
    val compact = LocalSize.current.width < 250.dp
    Column(
        modifier = GlanceModifier.fillMaxSize().padding(top = 6.dp, bottom = 8.dp),
    ) {
        Header(snapshot, projectId, appWidgetId)
        if (snapshot.rows.isEmpty()) {
            EmptyState()
            return@Column
        }
        LazyColumn(modifier = GlanceModifier.fillMaxWidth().defaultWeight().padding(horizontal = 16.dp)) {
            snapshot.rows.forEach { row ->
                item {
                    when (row) {
                        is WidgetRow.Section -> if (!compact) SectionLabel(row.label)
                        is WidgetRow.Task -> TaskRow(row)
                    }
                }
            }
        }
        if (snapshot.more > 0) {
            Text(
                text = "+${snapshot.more} more",
                modifier = GlanceModifier.padding(start = 16.dp, top = 4.dp),
                style = TextStyle(color = SecondaryText, fontSize = 13.sp),
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun Header(snapshot: Snapshot, projectId: String?, appWidgetId: Int) {
    val context = LocalContext.current
    Row(
        modifier = GlanceModifier.fillMaxWidth().height(36.dp).padding(start = 16.dp, end = 4.dp),
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        Row(
            modifier = GlanceModifier.defaultWeight()
                .clickable(actionStartActivity(configIntent(context, appWidgetId))),
            verticalAlignment = Alignment.Vertical.CenterVertically,
        ) {
            Text(
                text = oneLine(snapshot.name.ifBlank { "OTDA" }),
                modifier = GlanceModifier.defaultWeight(),
                style = TextStyle(
                    color = OnSurface,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                ),
                maxLines = 1,
            )
            Image(
                provider = ImageProvider(R.drawable.ic_widget_chevron),
                contentDescription = "Choose project",
                modifier = GlanceModifier.size(16.dp),
                colorFilter = ColorFilter.tint(SecondaryText),
            )
        }
        TapTarget(R.drawable.ic_widget_add, "New task", target = 36, icon = 20) {
            actionStartActivity(quickAddIntent(context, projectId))
        }
        TapTarget(R.drawable.ic_widget_open, "Open OTDA", target = 32, icon = 18) {
            actionStartActivity(appIntent(context))
        }
    }
}

@Composable
private fun SectionLabel(label: String) {
    Text(
        text = oneLine(label, 32),
        modifier = GlanceModifier.fillMaxWidth().padding(top = 6.dp, bottom = 0.dp),
        style = TextStyle(color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.Medium),
        maxLines = 1,
    )
}

@Composable
private fun TaskRow(task: WidgetRow.Task) {
    val context = LocalContext.current
    val titleStyle = TextStyle(
        color = if (task.done) SecondaryText else OnSurface,
        fontSize = 16.sp,
        fontWeight = FontWeight.Medium,
        textDecoration = if (task.done) TextDecoration.LineThrough else TextDecoration.None,
    )
    Row(
        modifier = GlanceModifier.fillMaxWidth()
            .height(40.dp)
            .clickable(actionStartActivity(deepLink(context, taskUri(task)))),
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        Box(
            modifier = GlanceModifier.size(40.dp)
                .clickable(actionRunCallback<CompleteAction>(completeParameters(task))),
            contentAlignment = Alignment.Center,
        ) {
            if (task.done) {
                Box(
                    modifier = GlanceModifier.size(24.dp).cornerRadius(12.dp).background(Accent),
                    contentAlignment = Alignment.Center,
                ) {
                    Image(
                        provider = ImageProvider(R.drawable.ic_widget_check),
                        contentDescription = "Completed",
                        modifier = GlanceModifier.size(14.dp),
                        colorFilter = ColorFilter.tint(ColorProvider(BrandNavy)),
                    )
                }
            } else {
                Image(
                    provider = ImageProvider(R.drawable.ic_widget_circle),
                    contentDescription = "Complete ${task.title}",
                    modifier = GlanceModifier.size(24.dp),
                    colorFilter = ColorFilter.tint(SecondaryText),
                )
            }
        }
        Text(
            text = oneLine(task.title),
            modifier = GlanceModifier.defaultWeight(),
            style = titleStyle,
            maxLines = 1,
        )
        if (task.right != null) {
            Spacer(GlanceModifier.width(8.dp))
            Text(
                text = oneLine(task.right, 18),
                style = TextStyle(
                    color = if (task.overdue) ErrorRed else SecondaryText,
                    fontSize = 14.sp,
                ),
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun EmptyState() {
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
            style = TextStyle(color = OnSurface, fontSize = 16.sp, fontWeight = FontWeight.Medium),
            maxLines = 1,
        )
    }
}

@Composable
private fun TapTarget(res: Int, description: String, target: Int, icon: Int, action: () -> Action) {
    Box(
        modifier = GlanceModifier.size(target.dp).clickable(action()),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            provider = ImageProvider(res),
            contentDescription = description,
            modifier = GlanceModifier.size(icon.dp),
            colorFilter = ColorFilter.tint(OnSurface),
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
    return base.build()
}

private fun completeParameters(task: WidgetRow.Task) =
    actionParametersOf(actionUriKey to completeTaskUri(task).toString())

private fun deepLink(context: Context, uri: Uri): Intent =
    Intent(Intent.ACTION_VIEW, uri).setClass(context, MainActivity::class.java)
