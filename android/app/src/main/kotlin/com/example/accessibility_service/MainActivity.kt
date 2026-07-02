package com.example.accessibility_service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.accessibility_service/monitor"
    private val ACTION_FLUTTER_EVENT = "com.example.accessibility_service.FLUTTER_EVENT"
    private val ACTION_UPDATE_SERVICE_NOTIFICATION =
        "com.example.accessibility_service.UPDATE_SERVICE_NOTIFICATION"
    private val ACTION_SHOW_INTERVENTION =
        "com.example.accessibility_service.SHOW_INTERVENTION"

    companion object {
        const val PREFS_NAME = "focusguard_prefs"
        const val PREF_REELS_BLOCK = "reels_block_enabled"
    }

    private fun prefs(): SharedPreferences =
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private var methodChannel: MethodChannel? = null
    private var eventReceiverRegistered = false

    private val eventReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            intent ?: return
            val method = intent.getStringExtra("method") ?: return
            val data = intent.getBundleExtra("data")?.toMap() ?: emptyMap<String, Any?>()
            methodChannel?.invokeMethod(method, data)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "open_notification_settings" -> {
                    val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                    startActivity(intent)
                    result.success(null)
                }
                "is_notification_listener_enabled" -> {
                    val enabledPackages = NotificationManagerCompat.getEnabledListenerPackages(this)
                    result.success(enabledPackages.contains(packageName))
                }
                "update_service_notification" -> {
                    val args = call.arguments as? Map<*, *>
                    val notificationTitle = args?.get("title")?.toString()
                        ?: "Monitoring Active"
                    val notificationText = args?.get("text")?.toString()
                        ?: "Watching your productivity..."
                    val intent = Intent(ACTION_UPDATE_SERVICE_NOTIFICATION).apply {
                        setPackage(packageName)
                        putExtra("notification_title", notificationTitle)
                        putExtra("notification_text", notificationText)
                    }
                    sendBroadcast(intent)
                    result.success(null)
                }
                "show_intervention_alert" -> {
                    val args = call.arguments as? Map<*, *>
                    val tier = (args?.get("tier") as? Int) ?: 2
                    val message = args?.get("message")?.toString()
                        ?: "You've been distracted. Time to refocus."
                    val intent = Intent(ACTION_SHOW_INTERVENTION).apply {
                        setPackage(packageName)
                        putExtra("tier", tier)
                        putExtra("message", message)
                    }
                    sendBroadcast(intent)
                    result.success(null)
                }
                "set_reels_block_enabled" -> {
                    val enabled = call.arguments as? Boolean ?: true
                    prefs().edit().putBoolean(PREF_REELS_BLOCK, enabled).apply()
                    result.success(null)
                }
                "get_reels_block_enabled" -> {
                    result.success(prefs().getBoolean(PREF_REELS_BLOCK, true))
                }
                "set_focus_goal_cache" -> {
                    val goal = call.arguments as? String ?: ""
                    prefs().edit().putString(MorningNudgeReceiver.PREF_FOCUS_GOAL, goal).apply()
                    MorningNudgeReceiver.scheduleDailyNudge(this)
                    result.success(null)
                }
                "cancel_morning_nudge" -> {
                    MorningNudgeReceiver.cancelDailyNudge(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        registerEventReceiver()
    }

    private fun registerEventReceiver() {
        if (eventReceiverRegistered) return

        val filter = IntentFilter(ACTION_FLUTTER_EVENT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(eventReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(eventReceiver, filter)
        }
        eventReceiverRegistered = true
    }

    override fun onDestroy() {
        if (eventReceiverRegistered) {
            unregisterReceiver(eventReceiver)
            eventReceiverRegistered = false
        }
        super.onDestroy()
    }

    private fun Bundle.toMap(): Map<String, Any?> {
        val map = HashMap<String, Any?>()
        for (key in keySet()) {
            map[key] = get(key)
        }
        return map
    }
}
