package com.dw.otda

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.dw.otda.widget.enqueuePendingOp
import com.dw.otda.widget.markRefreshing
import com.dw.otda.widget.requestWidgetUpdate
import com.dw.otda.widget.updateWidgets
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Runs one widget or lock-screen action and disappears: the widget's check mark starts
 * it, Dart opens the replica, completes the occurrence, pushes fresh snapshots and asks
 * this activity to finish.
 *
 * It exists because the home_widget background callback goes through WorkManager, whose
 * work can be deferred or dropped; a system-started activity is what the launcher is
 * allowed to start and is not.
 */
class CompleteActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        // Paint the change BEFORE super.onCreate: that call boots the Flutter engine on this
        // thread and takes a second or more, and the widget must not wait for it. Dart
        // confirms the change afterwards by rewriting the snapshots from the real data.
        val uri = intent?.data
        val id = uri?.getQueryParameter("id")
        if (uri?.host == "refresh") {
            markRefreshing(this)
            requestWidgetUpdate(this)
        } else if (id != null) {
            val done = uri.getQueryParameter("done") != "0"
            // Queue the tap; the widget draws it by laying the queue over the stored snapshot.
            enqueuePendingOp(this, id, uri.getQueryParameter("day"), null, null, done)
            requestWidgetUpdate(this)
        }
        super.onCreate(savedInstanceState)
    }

    override fun getDartEntrypointFunctionName(): String = "completeMain"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "uri" -> result.success(intent?.dataString)
                    "updateWidgets" -> {
                        // Redraw from the snapshots Dart just wrote.
                        runCatching { updateWidgets(this@CompleteActivity) }
                        result.success(true)
                    }
                    "close" -> {
                        result.success(true)
                        finishAndRemoveTask()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        const val CHANNEL = "com.dw.otda/complete"

        /** The intent the widget's check mark starts, for an `otda://` action URI. */
        fun intent(context: Context, uri: Uri): Intent =
            Intent(context, CompleteActivity::class.java).apply {
                data = uri
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
            }
    }
}
