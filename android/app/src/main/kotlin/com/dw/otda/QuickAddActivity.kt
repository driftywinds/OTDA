package com.dw.otda

import android.content.Context
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The widget's "+" popup: a transparent window over whatever app is in front, with the new-task
 * composer and the keyboard, like TickTick's. It runs the Dart entry point `quickAddMain`
 * (lib/main.dart) in its own engine, so it opens fast and never touches the main app's UI.
 *
 * The keyboard needs help here: a translucent window starts with no input focus, and both
 * `showSoftInput` and Flutter's own `TextInput.show` fail silently while the window is not
 * focusable, so the popup arrived with a blinking caret and no keyboard.
 */
class QuickAddActivity : FlutterActivity() {

    override fun getDartEntrypointFunctionName(): String = "quickAddMain"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    override fun onPostResume() {
        super.onPostResume()
        showKeyboard()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) showKeyboard()
    }

    private fun showKeyboard() {
        val window = window ?: return
        // A window that cannot take focus, or that is marked as not needing the IME,
        // swallows every request to raise it.
        window.clearFlags(
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM,
        )
        window.setSoftInputMode(
            WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE or
                WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE,
        )
        // The Flutter view is the first child of the activity's content frame; it is
        // the view the text connection belongs to, so the IME has to be asked for it.
        val content = findViewById<ViewGroup>(android.R.id.content) ?: return
        val flutterView: View = content.getChildAt(0) ?: return
        flutterView.requestFocus()
        flutterView.postDelayed({
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
            imm?.showSoftInput(flutterView, InputMethodManager.SHOW_IMPLICIT)
        }, 300)
    }

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
