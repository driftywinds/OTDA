package com.dw.otda

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * What a tap on a reminder notification opens: a transparent window over whatever app is in front,
 * with a bottom drawer holding the task and big Snooze / Complete buttons, like TickTick's. It runs
 * the Dart entry point `reminderSheetMain` (lib/main.dart) in its own engine, as [QuickAddActivity]
 * does, so the main app is not started or brought forward.
 *
 * How a tap gets here: flutter_local_notifications builds its tap PendingIntent from
 * `PackageManager.getLaunchIntentForPackage`, which looks for a `MAIN` + `INFO` activity before the
 * launcher one. This activity is declared with that filter (see the manifest), so every notification
 * tap lands here with the plugin's `payload` extra (`taskId|day`) while the launcher icon still opens
 * the app. The notification's own Complete / Snooze buttons are broadcasts and never come through here.
 */
class ReminderSheetActivity : FlutterActivity() {

    private var channel: MethodChannel? = null

    override fun getDartEntrypointFunctionName(): String = "reminderSheetMain"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methods = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methods.setMethodCallHandler { call, result ->
            when (call.method) {
                "payload" -> {
                    val payload = payloadFrom(intent)
                    result.success(payload)
                    // Nothing to show a drawer for: open the app, as a tap did before the drawer.
                    if (payload == null) {
                        openApp()
                        finishAndRemoveTask()
                    }
                }
                "openTask" -> {
                    val id = call.argument<String>("id")
                    val day = call.argument<String>("day")
                    result.success(id != null && openInApp(id, day))
                    finishAndRemoveTask()
                }
                "close" -> {
                    result.success(true)
                    finishAndRemoveTask()
                }
                else -> result.notImplemented()
            }
        }
        channel = methods
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // singleTask: tapping a second reminder while the drawer is open arrives here, and Dart swaps to it.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        payloadFrom(intent)?.let { channel?.invokeMethod("payload", it) }
    }

    /**
     * The reminder's `taskId|day`. A notification without one (the Settings test notifications) has
     * nothing to show a drawer for, so it opens the app instead, as a tap did before.
     */
    private fun payloadFrom(intent: Intent?): String? =
        intent?.getStringExtra(EXTRA_PAYLOAD)?.takeIf { it.contains('|') }

    private fun openApp() {
        runCatching {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .setAction(Intent.ACTION_MAIN)
                    .addCategory(Intent.CATEGORY_LAUNCHER)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            )
        }
    }

    private fun openInApp(id: String, day: String?): Boolean {
        val link = Uri.parse("otda://task/${Uri.encode(id)}").let {
            if (day.isNullOrBlank()) it else it.buildUpon().appendQueryParameter("day", day).build()
        }
        return try {
            startActivity(
                Intent(Intent.ACTION_VIEW, link, this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            )
            true
        } catch (t: Throwable) {
            false
        }
    }

    companion object {
        const val CHANNEL = "com.dw.otda/reminder"

        /** flutter_local_notifications' extra for a notification's payload. */
        const val EXTRA_PAYLOAD = "payload"
    }
}
