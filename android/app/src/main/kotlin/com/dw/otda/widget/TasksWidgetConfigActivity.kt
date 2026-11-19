package com.dw.otda.widget

import es.antonborri.home_widget.HomeWidgetBackgroundIntent

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
import android.widget.ArrayAdapter
import android.widget.ListView
import org.json.JSONArray

/**
 * Project picker for the widget. Plain Views on purpose: it must open and save while the Flutter
 * engine is dead, so nothing here touches Dart or the app process state.
 */
class TasksWidgetConfigActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Cancelling by default: backing out of the picker leaves no half-configured widget behind.
        setResult(RESULT_CANCELED)
        val appWidgetId = intent?.getIntExtra(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID,
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID
        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }

        val prefs = widgetPrefs(this)
        val current = prefs.getString(widgetProjectKey(appWidgetId), null)
        val projects = readProjects(prefs)
        val values = mutableListOf("all").apply { addAll(projects.map { it.id }) }
        val labels = mutableListOf("All projects").apply {
            projects.mapTo(this) { project ->
                val name = project.name.ifBlank { project.id }
                if (project.emoji.isBlank()) name else "${project.emoji} $name"
            }
        }

        title = "OTDA widget"
        val list = ListView(this).apply {
            adapter = ArrayAdapter(
                this@TasksWidgetConfigActivity,
                android.R.layout.simple_list_item_single_choice,
                labels,
            )
            choiceMode = ListView.CHOICE_MODE_SINGLE
            setItemChecked(current?.let(values::indexOf)?.coerceAtLeast(0) ?: 0, true)
        }
        setContentView(list)
        list.setOnItemClickListener { _, _, position, _ ->
            prefs.edit().putString(widgetProjectKey(appWidgetId), values[position]).apply()
            updateActiveProjects(prefs)
            requestWidgetUpdate(this)
            // The snapshot for a project that was just chosen does not exist yet:
            // wake Dart so it rebuilds them from the replica and redraws the widget.
            runCatching {
                HomeWidgetBackgroundIntent.getBroadcast(
                    this,
                    android.net.Uri.parse("otda://refresh"),
                ).send()
            }
            setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId))
            finish()
        }
    }

    private fun readProjects(prefs: SharedPreferences): List<Project> {
        val raw = prefs.getString("projects_index", null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { index ->
                val item = array.optJSONObject(index) ?: return@mapNotNull null
                val id = item.optString("id").takeIf { it.isNotBlank() } ?: return@mapNotNull null
                Project(id, item.optString("name"), item.optString("emoji"))
            }
        } catch (t: Throwable) {
            // A malformed index just means "All projects" is the only choice.
            emptyList()
        }
    }
}

private class Project(val id: String, val name: String, val emoji: String)
