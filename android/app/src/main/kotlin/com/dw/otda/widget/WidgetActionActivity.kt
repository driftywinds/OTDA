package com.dw.otda.widget

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle

/**
 * Receives a tap on a widget row and disappears: a plain, transparent Activity with no Flutter, so it
 * starts in a moment and is always allowed to start (a collection widget's row tap is an activity
 * PendingIntent). A tick or untick is queued here, locally, and drawn at once; opening a row hands
 * the task link to the app.
 *
 * The tap is handled in both onCreate and onNewIntent: the activity is singleTask, so a second tap that
 * lands while the first instance is still finishing arrives in onNewIntent, and ignoring it would drop
 * the tap on the floor.
 */
class WidgetActionActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handle(intent)
        leave()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
        leave()
    }

    private fun handle(intent: Intent?) {
        intent ?: return
        val id = intent.getStringExtra(WidgetIntents.EXTRA_ID) ?: return
        val day = intent.getStringExtra(WidgetIntents.EXTRA_DAY)?.takeIf { it.isNotBlank() }
        when (intent.getStringExtra(WidgetIntents.EXTRA_OP)) {
            WidgetIntents.OP_TOGGLE -> {
                val sid = intent.getStringExtra(WidgetIntents.EXTRA_SID)?.takeIf { it.isNotBlank() }
                val occ = intent.getStringExtra(WidgetIntents.EXTRA_OCC)?.takeIf { it.isNotBlank() }
                toggleTask(this, id, day, sid, occ, intent.getBooleanExtra(WidgetIntents.EXTRA_DONE, true))
            }
            WidgetIntents.OP_OPEN -> {
                val link = Uri.parse("otda://task/${Uri.encode(id)}").let {
                    if (day == null) it else it.buildUpon().appendQueryParameter("day", day).build()
                }
                runCatching { startActivity(WidgetIntents.deepLink(this, link)) }
            }
        }
    }

    private fun leave() {
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
