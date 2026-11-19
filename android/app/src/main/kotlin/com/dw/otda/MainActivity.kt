package com.dw.otda

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Besides hosting Flutter, this carries two things Dart cannot do alone:
 *  - `otda://` links (widget rows, the widget's "+", notification taps) are handed to Dart over
 *    [CHANNEL], both for a cold start (`getInitialLink`) and while the app is running (`link`).
 *  - the system screens a reliable reminder depends on: notification, exact-alarm and battery
 *    settings, and the phone-maker "Autostart" page.
 */
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var initialLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        initialLink = linkFrom(intent)
        val methods = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methods.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialLink" -> {
                    result.success(initialLink)
                    initialLink = null
                }
                "manufacturer" -> result.success(Build.MANUFACTURER.lowercase())
                "isIgnoringBatteryOptimizations" -> {
                    val power = getSystemService(POWER_SERVICE) as PowerManager
                    result.success(power.isIgnoringBatteryOptimizations(packageName))
                }
                "openNotificationSettings" -> result.success(start(notificationSettings()))
                "openChannelSettings" -> {
                    val id = call.argument<String>("id") ?: "reminders"
                    result.success(start(channelSettings(id)))
                }
                "openExactAlarmSettings" -> result.success(start(exactAlarmSettings()))
                "openBatterySettings" -> result.success(
                    start(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) ||
                        start(appDetails()),
                )
                "openAutostart" -> result.success(start(autostart()) || start(appDetails()))
                "openAppSettings" -> result.success(start(appDetails()))
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

    // launchMode is singleTop: a tap on the widget while the app is open lands here, not in onCreate.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        linkFrom(intent)?.let { channel?.invokeMethod("link", it) }
    }

    private fun linkFrom(intent: Intent?): String? {
        val data = intent?.data ?: return null
        return if (intent.action == Intent.ACTION_VIEW && data.scheme == "otda") data.toString() else null
    }

    private fun start(intent: Intent): Boolean =
        try {
            startActivity(intent)
            true
        } catch (t: Throwable) {
            false
        }

    private fun notificationSettings() =
        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)

    private fun channelSettings(channelId: String) =
        Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            .putExtra(Settings.EXTRA_CHANNEL_ID, channelId)

    private fun exactAlarmSettings() =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName"))
        } else {
            appDetails()
        }

    private fun appDetails() =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))

    /** Xiaomi / Redmi / POCO keep the switch that lets an app start itself here. */
    private fun autostart() =
        Intent().setComponent(
            ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity",
            ),
        )

    companion object {
        const val CHANNEL = "com.dw.otda/system"
    }
}
