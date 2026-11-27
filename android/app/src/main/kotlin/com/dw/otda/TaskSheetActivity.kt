package com.dw.otda

import android.content.Intent
import android.net.Uri
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * What a tap on a widget row opens: the task's own sheet as a bottom drawer in a transparent window over
 * whatever app is in front, instead of starting the whole app. It runs the Dart entry point
 * `taskSheetMain` (lib/main.dart) in its own engine, like [QuickAddActivity] and [ReminderSheetActivity],
 * so the main app is neither started nor brought forward. The widget's top-right arrow still opens the
 * app itself.
 *
 * Started by `WidgetActionActivity` with the row's task id in [EXTRA_ID]. singleTask: a second row
 * tapped while the sheet is open arrives in [onNewIntent] and Dart swaps to it.
 */
class TaskSheetActivity : FlutterActivity() {

    private var channel: MethodChannel? = null

    override fun getDartEntrypointFunctionName(): String = "taskSheetMain"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    override fun onPostResume() {
        super.onPostResume()
        // The sheet has text fields. A translucent window must be focusable, and resize for the keyboard,
        // or tapping the title raises nothing (see QuickAddActivity).
        window?.apply {
            clearFlags(
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM,
            )
            setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methods = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methods.setMethodCallHandler { call, result ->
            when (call.method) {
                "id" -> result.success(intent.getStringExtra(EXTRA_ID))
                "openInApp" -> {
                    val id = call.argument<String>("id")
                    result.success(id != null && openInApp(id))
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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra(EXTRA_ID)?.takeIf { it.isNotBlank() }?.let { channel?.invokeMethod("task", it) }
    }

    private fun openInApp(id: String): Boolean = try {
        startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse("otda://task/${Uri.encode(id)}"), this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        )
        true
    } catch (t: Throwable) {
        false
    }

    companion object {
        const val CHANNEL = "com.dw.otda/tasksheet"
        const val EXTRA_ID = "id"
    }
}
