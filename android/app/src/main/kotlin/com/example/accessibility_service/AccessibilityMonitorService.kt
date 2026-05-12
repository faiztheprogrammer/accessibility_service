package com.example.accessibility_service

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class AccessibilityMonitorService : AccessibilityService() {
    
    companion object {
        const val CHANNEL_ID = "accessibility_monitor_service"
        const val NOTIFICATION_ID = 101
        const val FLUTTER_CHANNEL = "com.example.accessibility_service/monitor"
    }
    
    private lateinit var methodChannel: MethodChannel
    private lateinit var flutterEngine: FlutterEngine
    private val executor = Executors.newSingleThreadExecutor()
    
    private val handler = Handler(Looper.getMainLooper())
    private var extractRunnable: Runnable? = null
    private var lastPackageName: String = "unknown"
    private var lastCapturedTitle = ""

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }
    
    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.d("AccessibilityService", "Service Connected")
        
        // Start as Foreground Service to prevent being killed by Android
        val notification = createNotification("Monitoring Active", "Watching your productivity...")
        startForeground(NOTIFICATION_ID, notification)

        try {
            flutterEngine = FlutterEngine(applicationContext)
            flutterEngine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            )
            methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FLUTTER_CHANNEL)
            
            // Register broadcast receiver for media updates
            val filter = android.content.IntentFilter("com.example.accessibility_service.MEDIA_UPDATE")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(mediaUpdateReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(mediaUpdateReceiver, filter)
            }
        } catch (e: Exception) {
            Log.e("AccessibilityService", "Flutter Engine Init Error: ${e.message}")
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "App Content Monitor Service",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(serviceChannel)
        }
    }

    private fun createNotification(title: String, message: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(message)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(title: String, message: String) {
        val notification = createNotification(title, message)
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, notification)
    }
    
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event?.let {
            val packageName = event.packageName?.toString() ?: return
            
            if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED || 
                event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) {
                
                lastPackageName = packageName
                
                extractRunnable?.let { handler.removeCallbacks(it) }
                extractRunnable = Runnable { 
                    executor.execute {
                        performExtraction()
                    }
                }
                handler.postDelayed(extractRunnable!!, 1500) // Slightly increased delay for stability
            }
        }
    }
    
    private fun performExtraction() {
        try {
            val rootNode = rootInActiveWindow ?: return
            
            if (lastPackageName == "com.google.android.youtube") {
                handleYoutubeExtraction(rootNode)
            } else {
                handleGenericExtraction(rootNode)
            }
            rootNode.recycle()
        } catch (e: Exception) {
            Log.e("Extract", "Error: ${e.message}")
        }
    }

    private fun handleGenericExtraction(root: AccessibilityNodeInfo) {
        val texts = mutableListOf<String>()
        collectTextsRecursively(root, texts)
        val text = texts.distinct().filter { it.length > 10 }.joinToString(" | ")
        
        if (text.isNotEmpty()) {
            val payload = mapOf("package" to lastPackageName, "text" to text, "timestamp" to System.currentTimeMillis())
            sendToFlutter("content_extracted", payload)
        }
    }

    private fun isLikelyDistraction(text: String): Boolean {
        val lower = text.lowercase()
        val distractKeywords = listOf("funny", "prank", "song", "music", "trailer", "roast", "shorts", "gaming")
        val productiveKeywords = listOf("tutorial", "code", "programming", "flutter", "c++", "how to", "career")
        
        if (productiveKeywords.any { lower.contains(it) }) return false
        return distractKeywords.any { lower.contains(it) }
    }

    private fun collectTextsRecursively(node: AccessibilityNodeInfo, list: MutableList<String>) {
        node.text?.toString()?.trim()?.takeIf { it.isNotEmpty() }?.let { list.add(it) }
        for (i in 0 until node.childCount) {
            node.getChild(i)?.let { collectTextsRecursively(it, list) }
        }
    }

    private fun sendToFlutter(method: String, data: Any) {
        handler.post {
            try {
                methodChannel.invokeMethod(method, data)
            } catch (e: Exception) {
                Log.e("SendToFlutter", "Error: ${e.message}")
            }
        }
    }

    // Broadcast Receiver to get highly accurate MediaSession data from MediaMonitorService
    private val mediaUpdateReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: android.content.Intent?) {
            intent?.let {
                val title = it.getStringExtra("title") ?: return
                val channel = it.getStringExtra("channel") ?: ""
                val packageName = it.getStringExtra("package") ?: "unknown_media"

                if (title == lastCapturedTitle) return
                lastCapturedTitle = title

                Log.i("MEDIA_MONITOR", "🎯 MEDIA SESSION DETECTED: $title by $channel")

                // Distraction check for local notification
                if (isLikelyDistraction(title)) {
                    updateNotification("⚠️ Distraction Detected!", title)
                } else {
                    updateNotification("✅ Productive Mode", title)
                }

                val payload = mapOf(
                    "package" to "com.google.android.youtube", // Hardcoded for now assuming YT mostly
                    "title" to title,
                    "channel" to channel,
                    "timestamp" to System.currentTimeMillis()
                )
                sendToFlutter("content_extracted", payload)
            }
        }
    }

    override fun onInterrupt() {}
    
    override fun onDestroy() {
        super.onDestroy()
        unregisterReceiver(mediaUpdateReceiver)
    }
}