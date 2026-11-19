package com.dw.otda

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The widget's "+" popup: a transparent window over whatever app is in front, with the new-task
 * composer and the keyboard, like TickTick's. It runs the Dart entry point `quickAddMain`
 * (lib/main.dart) in its own engine, so it opens fast and never touches the main app's UI.
 */
class QuickAddActivity : FlutterActivity() {

    override fun getDartEntrypointFunctionName(): String = "quickAddMain"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "project" -> result.success(intent.getStringExtra(EXTRA_PROJECT))
                    "close" -> {
                        result.success(true)
                        finish()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        const val CHANNEL = "com.dw.otda/quickadd"
        const val EXTRA_PROJECT = "project"
    }
}
