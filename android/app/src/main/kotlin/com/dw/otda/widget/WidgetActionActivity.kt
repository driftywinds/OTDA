package com.dw.otda.widget

import android.app.Activity
import android.net.Uri
import android.os.Bundle

/**
 * Receives a tap on a widget row and disappears: a plain, transparent Activity with no Flutter, so it
 * starts in a moment and is always allowed to start (a collection widget's row tap is an activity
 * PendingIntent). A tick or untick is done here, locally, before anything else; opening a row hands
 * the task link to the app.
 */
class WidgetActionActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val id = intent?.getStringExtra(WidgetIntents.EXTRA_ID)
        val day = intent?.getStringExtra(WidgetIntents.EXTRA_DAY)?.takeIf { it.isNotBlank() }
        if (id != null) {
            when (intent?.getStringExtra(WidgetIntents.EXTRA_OP)) {
                WidgetIntents.OP_TOGGLE ->
                    toggleTask(this, id, day, intent.getBooleanExtra(WidgetIntents.EXTRA_DONE, true))
                WidgetIntents.OP_OPEN -> {
                    val link = Uri.parse("otda://task/${Uri.encode(id)}").let {
                        if (day == null) it else it.buildUpon().appendQueryParameter("day", day).build()
                    }
                    runCatching { startActivity(WidgetIntents.deepLink(this, link)) }
                }
            }
        }
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
