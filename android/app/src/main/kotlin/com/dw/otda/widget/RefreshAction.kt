package com.dw.otda.widget

import android.content.Context
import android.net.Uri
import androidx.glance.GlanceId
import androidx.glance.action.ActionParameters
import androidx.glance.appwidget.action.ActionCallback

/** Marks the snapshot as refreshing, redraws, then lets the app fetch fresh data. */
class RefreshAction : ActionCallback {

    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        widgetPrefs(context).edit()
            .putBoolean("refreshing", true)
            .putLong("refreshingSince", System.currentTimeMillis())
            .apply()
        TasksWidget().update(context, glanceId)
        sendToDart(context, Uri.parse("otda://refresh"))
    }
}
