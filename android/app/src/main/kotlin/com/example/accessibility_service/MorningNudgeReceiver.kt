package com.example.accessibility_service

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import java.util.Calendar

class MorningNudgeReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED -> {
                scheduleDailyNudge(context)
            }
            ACTION_MORNING_NUDGE -> postNudgeNotification(context)
        }
    }

    companion object {
        const val ACTION_MORNING_NUDGE  = "com.example.accessibility_service.MORNING_NUDGE"
        const val NUDGE_CHANNEL_ID      = "morning_nudge"
        const val NUDGE_NOTIFICATION_ID = 301
        const val PREF_FOCUS_GOAL       = "focus_goal_cache"
        const val PREF_NUDGE_ENABLED    = "nudge_enabled"
        const val PREF_NUDGE_HOUR       = "nudge_hour"
        const val PREF_NUDGE_MINUTE     = "nudge_minute"
        const val PREF_NUDGE_MESSAGE    = "nudge_message"
        const val DEFAULT_NUDGE_TITLE   = "Good morning! Stay focused today."

        fun postNudgeNotification(context: Context) {
            val prefs = context.getSharedPreferences(MainActivity.PREFS_NAME, Context.MODE_PRIVATE)
            val goal    = prefs.getString(PREF_FOCUS_GOAL, null)?.takeIf { it.isNotBlank() }
            val custom  = prefs.getString(PREF_NUDGE_MESSAGE, null)?.takeIf { it.isNotBlank() }

            createChannel(context)

            val tapIntent = PendingIntent.getActivity(
                context,
                0,
                context.packageManager.getLaunchIntentForPackage(context.packageName),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val title = custom ?: DEFAULT_NUDGE_TITLE
            val body  = if (goal != null) "Your goal: $goal" else "Tap to set your focus goal"

            val notification = NotificationCompat.Builder(context, NUDGE_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(tapIntent)
                .build()

            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NUDGE_NOTIFICATION_ID, notification)

            // Reschedule for the next day
            scheduleDailyNudge(context)
        }

        fun createChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                // Only create if it doesn't exist yet — importance can't be changed after creation
                if (nm.getNotificationChannel(NUDGE_CHANNEL_ID) == null) {
                    val channel = NotificationChannel(
                        NUDGE_CHANNEL_ID,
                        "Daily Focus Reminder",
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply {
                        description = "Morning nudge reminding you of your focus goal"
                    }
                    nm.createNotificationChannel(channel)
                }
            }
        }

        fun scheduleDailyNudge(context: Context) {
            val prefs = context.getSharedPreferences(MainActivity.PREFS_NAME, Context.MODE_PRIVATE)
            if (!prefs.getBoolean(PREF_NUDGE_ENABLED, true)) {
                cancelDailyNudge(context)
                return
            }

            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pi = pendingIntent(context)

            val hour   = prefs.getInt(PREF_NUDGE_HOUR, 8)
            val minute = prefs.getInt(PREF_NUDGE_MINUTE, 0)

            val cal = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, hour)
                set(Calendar.MINUTE, minute)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
                if (timeInMillis <= System.currentTimeMillis()) {
                    add(Calendar.DAY_OF_YEAR, 1)
                }
            }

            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !am.canScheduleExactAlarms()) {
                    am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, cal.timeInMillis, pi)
                } else {
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, cal.timeInMillis, pi)
                }
            } catch (e: SecurityException) {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, cal.timeInMillis, pi)
            }
        }

        fun cancelDailyNudge(context: Context) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.cancel(pendingIntent(context))
        }

        private fun pendingIntent(context: Context): PendingIntent {
            val intent = Intent(context, MorningNudgeReceiver::class.java).apply {
                action = ACTION_MORNING_NUDGE
            }
            return PendingIntent.getBroadcast(
                context,
                NUDGE_NOTIFICATION_ID,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
    }
}
