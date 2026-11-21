package com.dw.otda.widget

import android.content.Context
import androidx.glance.GlanceId
import androidx.glance.action.ActionParameters
import androidx.glance.appwidget.action.ActionCallback
import kotlinx.coroutines.delay

private const val REFRESH_TIMEOUT_MS = 8_000L

/** Raises the "refreshing" flag so the next redraw shows the spinner state. */
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

/**
 * The header's refresh button. Paints the "refreshing" state at once, then asks the app to sync.
 */
class RefreshAction : ActionCallback {

    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        markRefreshing(context)
        updateWidgets(context)
        sendToDart(context, android.net.Uri.parse("otda://refresh"))
        // Do not leave the spinner up for ever if the app never answers.
        delay(REFRESH_TIMEOUT_MS + 500L)
        updateWidgets(context)
    }
}
