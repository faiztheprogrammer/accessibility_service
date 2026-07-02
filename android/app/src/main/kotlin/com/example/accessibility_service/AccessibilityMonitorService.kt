package com.example.accessibility_service

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.graphics.Rect
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.core.app.NotificationCompat
import java.util.concurrent.Executors

class AccessibilityMonitorService : AccessibilityService() {

    companion object {
        const val CHANNEL_ID = "accessibility_monitor_service"
        const val INTERVENTION_CHANNEL_ID = "focus_interventions"
        const val NOTIFICATION_ID = 101
        const val INTERVENTION_NOTIFICATION_ID = 202
        const val FLUTTER_CHANNEL = "com.example.accessibility_service/monitor"
        const val ACTION_FLUTTER_EVENT = "com.example.accessibility_service.FLUTTER_EVENT"
        const val ACTION_UPDATE_SERVICE_NOTIFICATION =
            "com.example.accessibility_service.UPDATE_SERVICE_NOTIFICATION"
        const val ACTION_SHOW_INTERVENTION =
            "com.example.accessibility_service.SHOW_INTERVENTION"
        private const val YOUTUBE_PACKAGE = "com.google.android.youtube"
        private const val PLAY_SHORT_SUFFIX = " - play Short"
        private const val SHORTS_SCAN_THROTTLE_MS = 350L
        private const val SHORTS_DUPLICATE_WINDOW_MS = 10_000L
        private const val SHORTS_MAX_SCAN_NODES = 500
        private const val SHORTS_FOOTER_ID = "reel_player_footer_container"
        private const val SHORTS_ROOT_ID = "reel_watch_fragment_root"
        private const val MEDIA_SESSION_GRACE_MS = 2_000L
        private const val INSTAGRAM_PACKAGE = "com.instagram.android"
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val instagramReelsBlocker by lazy { InstagramReelsBlocker(this) }

    private val handler = Handler(Looper.getMainLooper())
    private var extractRunnable: Runnable? = null
    private var shortsRunnable: Runnable? = null
    private var receiverRegistered = false
    private var lastPackageName: String = "unknown"
    private var lastCapturedTitle = ""
    private var lastMediaTitle = ""
    private var lastMediaTitleAt = 0L
    private var lastShortsFingerprint = ""
    private var lastShortsCapturedAt = 0L
    private var lastShortsScanAt = 0L
    private var lastEventPlayShortTitle = ""

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        createInterventionNotificationChannel()
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(102)
        manager.cancel(201)
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.d("AccessibilityService", "Service connected")

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(102)
        manager.cancel(201)

        val notification = createNotification("Monitoring Active", "Watching your productivity...")
        startForeground(NOTIFICATION_ID, notification)
        ensureAccessibilityEventTypes()

        val filter = IntentFilter().apply {
            addAction("com.example.accessibility_service.MEDIA_UPDATE")
            addAction(ACTION_UPDATE_SERVICE_NOTIFICATION)
            addAction(ACTION_SHOW_INTERVENTION)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(mediaUpdateReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(mediaUpdateReceiver, filter)
            }
            receiverRegistered = true
        } catch (e: Exception) {
            Log.e("AccessibilityService", "Receiver init error: ${e.message}")
        }

        sendToFlutter("service_status", mapOf("isRunning" to true, "status" to "Connected"))
        Log.i("AccessibilityService", "Service status broadcast: isRunning=true")
    }

    private fun ensureAccessibilityEventTypes() {
        serviceInfo = (serviceInfo ?: AccessibilityServiceInfo()).apply {
            eventTypes = eventTypes or
                AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED or
                AccessibilityEvent.TYPE_VIEW_SCROLLED or
                AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            flags = flags or
                AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
            notificationTimeout = 100
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "App Content Monitor Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps background content monitoring active"
                setSound(null, null)
            }

            manager.createNotificationChannel(serviceChannel)
        }
    }

    private fun createNotification(title: String, message: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(message)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun createInterventionNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(
                INTERVENTION_CHANNEL_ID,
                "Focus Interventions",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Alerts when distraction pattern is detected"
                enableVibration(true)
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun showInterventionNotification(tier: Int, message: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val title = if (tier >= 3) "Refocus Now" else "Distraction Alert"
        val notification = NotificationCompat.Builder(this, INTERVENTION_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(message)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setVibrate(longArrayOf(0, 300, 100, 300))
            .build()
        manager.notify(INTERVENTION_NOTIFICATION_ID, notification)
    }

    private fun updateForegroundNotification(message: String, title: String = "Latest YouTube Title") {
        val notification = createNotification(title, message)
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, notification)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event ?: return

        val packageName = event.packageName?.toString() ?: return

        // Route Instagram events to the reels blocker — completely independent
        if (packageName == INSTAGRAM_PACKAGE) {
            instagramReelsBlocker.onAccessibilityEvent(event)
            return
        }

        if (packageName != YOUTUBE_PACKAGE) return

        val eventType = event.eventType
        val isRelevantEvent = eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
            eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED ||
            eventType == AccessibilityEvent.TYPE_VIEW_SCROLLED

        if (!isRelevantEvent) return

        lastPackageName = packageName

        lastEventPlayShortTitle = extractPlayShortTitle(event.contentDescription?.toString().orEmpty()).orEmpty()
        if (lastEventPlayShortTitle.isBlank()) {
            lastEventPlayShortTitle = event.text
                .asSequence()
                .mapNotNull { extractPlayShortTitle(it?.toString().orEmpty()) }
                .firstOrNull()
                .orEmpty()
        }

        Log.d("ShortsDebug", "Event received in YouTube")
        if (
            eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED ||
            eventType == AccessibilityEvent.TYPE_VIEW_SCROLLED
        ) {
            scheduleShortsFallbackExtraction()
        }
    }

    private fun scheduleShortsFallbackExtraction() {
        val now = System.currentTimeMillis()
        if (now - lastShortsScanAt < SHORTS_SCAN_THROTTLE_MS) return
        lastShortsScanAt = now

        shortsRunnable?.let { handler.removeCallbacks(it) }
        shortsRunnable = Runnable {
            executor.execute {
                performShortsFallbackExtraction()
            }
        }
        handler.postDelayed(shortsRunnable!!, 250L)
    }

    private fun performExtraction() {
        try {
            val rootNode = rootInActiveWindow ?: return

            if (lastPackageName != YOUTUBE_PACKAGE) {
                handleGenericExtraction(rootNode)
            }
            rootNode.recycle()
        } catch (e: Exception) {
            Log.e("Extract", "Error: ${e.message}")
        }
    }

    private fun performShortsFallbackExtraction() {
        try {
            if (hasFreshMediaSessionTitle()) return

            val rootNode = rootInActiveWindow
            if (rootNode == null) {
                Log.d("ShortsDebug", "Root node is null during Shorts fallback")
                return
            }
            val shortsContent = extractShortsContent(rootNode)
            rootNode.recycle()

            if (shortsContent == null) {
                Log.d("ShortsDebug", "No Shorts title candidate found")
                return
            }
            if (hasFreshMediaSessionTitle()) return

            val now = System.currentTimeMillis()
            val fingerprint = "${shortsContent.title}|${shortsContent.channel}|${shortsContent.description}"
            if (fingerprint == lastShortsFingerprint && now - lastShortsCapturedAt < SHORTS_DUPLICATE_WINDOW_MS) {
                return
            }

            lastShortsFingerprint = fingerprint
            lastShortsCapturedAt = now
            lastCapturedTitle = shortsContent.title

            Log.i("ShortsFallback", "Detected YouTube Short: ${shortsContent.title}")
            updateForegroundNotification("Analysing content…", "Monitoring Active")

            val extractedText = listOf(
                shortsContent.title,
                shortsContent.channel,
                shortsContent.description
            ).filter { it.isNotBlank() }.joinToString(" | ")

            val payload = mapOf(
                "package" to YOUTUBE_PACKAGE,
                "title" to shortsContent.title,
                "channel" to shortsContent.channel,
                "text" to extractedText,
                "source" to "accessibility_shorts",
                "timestamp" to System.currentTimeMillis()
            )
            sendToFlutter("content_extracted", payload)
        } catch (e: Exception) {
            Log.e("ShortsFallback", "Error: ${e.message}")
        }
    }

    private fun handleGenericExtraction(root: AccessibilityNodeInfo) {
        val texts = mutableListOf<String>()
        collectTextsRecursively(root, texts)
        val text = texts.distinct().filter { it.length > 10 }.joinToString(" | ")

        if (text.isNotEmpty()) {
            val payload = mapOf(
                "package" to lastPackageName,
                "text" to text,
                "timestamp" to System.currentTimeMillis()
            )
            sendToFlutter("content_extracted", payload)
        }
    }

    private data class ShortsContent(
        val title: String,
        val channel: String,
        val description: String
    )

    private fun extractShortsContent(root: AccessibilityNodeInfo): ShortsContent? {
        if (lastEventPlayShortTitle.isNotBlank()) {
            Log.d("ShortsDebug", "Shorts title from event play Short suffix: $lastEventPlayShortTitle")
            return ShortsContent(title = lastEventPlayShortTitle, channel = "", description = "")
        }

        val visitedCount = intArrayOf(0)
        val title = findPlayShortTitle(root, visitedCount)
        if (!title.isNullOrBlank()) {
            Log.d("ShortsDebug", "Shorts title from play Short suffix: $title")
            return ShortsContent(title = title, channel = "", description = "")
        }

        val footerTitle = extractShortsFooterTitle(root)
        if (!footerTitle.isNullOrBlank()) {
            Log.d("ShortsDebug", "Shorts title from footer fallback: $footerTitle")
            return ShortsContent(title = footerTitle, channel = "", description = "")
        }

        return null
    }

    private fun extractPlayShortTitle(value: String): String? {
        val text = value.replace(Regex("\\s+"), " ").trim()
        if (!text.endsWith(PLAY_SHORT_SUFFIX)) return null

        val title = stripTrailingViewCount(text.removeSuffix(PLAY_SHORT_SUFFIX).trim())
        if (title.isBlank()) return null
        if (isProgressOrTimestampText(title.lowercase())) return null

        return title
    }

    private fun stripTrailingViewCount(value: String): String {
        return value
            .replace(
                Regex(
                    """,?\s*\d+(?:[.,]\d+)?\s*(?:k|m|b|thousand|million|billion)?\s+views$""",
                    RegexOption.IGNORE_CASE
                ),
                ""
            )
            .trim()
    }

    private fun findPlayShortTitle(
        node: AccessibilityNodeInfo,
        visitedCount: IntArray
    ): String? {
        if (visitedCount[0] >= SHORTS_MAX_SCAN_NODES) return null
        visitedCount[0] = visitedCount[0] + 1

        val text = node.text?.toString()?.trim().orEmpty()
        val description = node.contentDescription?.toString()?.trim().orEmpty()

        extractPlayShortTitle(text)?.let { return it }
        extractPlayShortTitle(description)?.let { return it }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val title = findPlayShortTitle(child, visitedCount)
            child.recycle()
            if (title != null) return title
        }

        return null
    }

    private data class FooterTitleCandidate(
        val text: String,
        val bounds: Rect,
        val order: Int,
        val className: String,
        val clickable: Boolean,
        val hasImageDescendant: Boolean
    )

    private fun extractShortsFooterTitle(root: AccessibilityNodeInfo): String? {
        if (!hasNodeWithViewId(root, SHORTS_ROOT_ID, intArrayOf(0))) {
            Log.d("ShortsDebug", "Footer fallback skipped: Shorts root not found")
            return null
        }

        val footer = findNodeByViewId(root, SHORTS_FOOTER_ID, intArrayOf(0))
        if (footer == null) {
            Log.d("ShortsDebug", "Footer fallback skipped: footer node not found")
            return null
        }
        val candidates = mutableListOf<FooterTitleCandidate>()
        collectFooterTitleCandidates(footer, candidates, intArrayOf(0))

        val channelBottom = candidates
            .filter { it.text.startsWith("@") }
            .maxOfOrNull { it.bounds.bottom }

        val titleCandidates = candidates
            .filter { candidate ->
                channelBottom == null || candidate.bounds.top >= channelBottom
            }
            .filter { it.bounds.left <= 48 && it.bounds.right <= 592 }
            .filter { !isRelatedVideoLinkCandidate(it) }
            .filter { isShortsFooterTitleCandidate(it.text) }
            .sortedWith(compareBy<FooterTitleCandidate> { it.bounds.top }.thenBy { it.order })

        val prominentMainTitle = titleCandidates.firstOrNull { isProminentMainTitleRow(it) }
        if (prominentMainTitle != null) return prominentMainTitle.text

        if (channelBottom == null) {
            val bottomTitleCandidate = titleCandidates
                .filter { it.clickable && it.className.lowercase().contains("viewgroup") }
                .maxByOrNull { it.bounds.top }
            if (bottomTitleCandidate != null) {
                Log.d("ShortsDebug", "Footer fallback used bottom title without channel row")
                return bottomTitleCandidate.text
            }
        }

        Log.d("ShortsDebug", "Footer fallback candidates=${titleCandidates.size}, channelBottom=$channelBottom")
        return titleCandidates
            .firstOrNull()
            ?.text
    }

    private fun isProminentMainTitleRow(candidate: FooterTitleCandidate): Boolean {
        val lowerClass = candidate.className.lowercase()
        return candidate.clickable &&
            lowerClass.contains("viewgroup") &&
            !lowerClass.contains("button") &&
            !candidate.hasImageDescendant &&
            candidate.bounds.left <= 48 &&
            candidate.bounds.width() >= 360
    }

    private fun isRelatedVideoLinkCandidate(candidate: FooterTitleCandidate): Boolean {
        return candidate.clickable &&
            candidate.hasImageDescendant &&
            candidate.bounds.left <= 8 &&
            candidate.bounds.width() >= 360
    }

    private fun findNodeByViewId(
        node: AccessibilityNodeInfo,
        viewIdNeedle: String,
        visitedCount: IntArray
    ): AccessibilityNodeInfo? {
        if (visitedCount[0] >= SHORTS_MAX_SCAN_NODES) return null
        visitedCount[0] = visitedCount[0] + 1

        val viewId = node.viewIdResourceName?.lowercase().orEmpty()
        if (viewId.contains(viewIdNeedle)) return node

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val match = findNodeByViewId(child, viewIdNeedle, visitedCount)
            if (match != null) return match
            child.recycle()
        }

        return null
    }

    private fun hasNodeWithViewId(
        node: AccessibilityNodeInfo,
        viewIdNeedle: String,
        visitedCount: IntArray
    ): Boolean {
        val match = findNodeByViewId(node, viewIdNeedle, visitedCount)
        return match != null
    }

    private fun collectFooterTitleCandidates(
        node: AccessibilityNodeInfo,
        candidates: MutableList<FooterTitleCandidate>,
        visitedCount: IntArray
    ) {
        if (visitedCount[0] >= SHORTS_MAX_SCAN_NODES) return
        visitedCount[0] = visitedCount[0] + 1

        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        val order = visitedCount[0]

        listOf(
            node.text?.toString().orEmpty(),
            node.contentDescription?.toString().orEmpty()
        ).forEach { rawText ->
            val text = rawText.replace(Regex("\\s+"), " ").trim()
            if (text.isNotBlank()) {
                candidates.add(
                    FooterTitleCandidate(
                        text = text,
                        bounds = Rect(bounds),
                        order = order,
                        className = node.className?.toString().orEmpty(),
                        clickable = node.isClickable,
                        hasImageDescendant = hasImageDescendant(node, 0)
                    )
                )
            }
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            collectFooterTitleCandidates(child, candidates, visitedCount)
            child.recycle()
        }
    }

    private fun hasImageDescendant(node: AccessibilityNodeInfo, depth: Int): Boolean {
        if (depth > 3) return false
        val className = node.className?.toString()?.lowercase().orEmpty()
        if (className.contains("imageview")) return true

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = hasImageDescendant(child, depth + 1)
            child.recycle()
            if (found) return true
        }

        return false
    }

    private fun isShortsFooterTitleCandidate(value: String): Boolean {
        val text = value.trim()
        if (text.length < 8 || text.length > 180) return false
        if (text.startsWith("@")) return false

        val lower = text.lowercase()
        val blockedExact = setOf(
            "shop",
            "subscribe",
            "subscribed",
            "like",
            "dislike",
            "share",
            "remix",
            "comments",
            "comment",
            "home",
            "shorts",
            "subscriptions",
            "you",
            "create"
        )

        if (lower in blockedExact) return false
        if (isProgressOrTimestampText(lower)) return false
        if (lower.startsWith("go to channel")) return false
        if (lower.startsWith("subscribe to ")) return false
        if (lower.contains(" products")) return false
        if (lower.contains(" comments")) return false
        if (lower.contains("like this video")) return false
        if (lower.contains("dislike this video")) return false
        if (lower.contains("share this video")) return false
        if (lower.contains("see more videos using this sound")) return false
        if (text.matches(Regex("^[\\d.,]+[kKmMbB]?$"))) return false

        return true
    }

    private fun isUsefulShortsText(value: String): Boolean {
        val text = value.trim()
        if (text.length < 3 || text.length > 160) return false

        val lower = text.lowercase()
        val blockedControls = setOf(
            "home",
            "shorts",
            "subscriptions",
            "you",
            "library",
            "create",
            "search",
            "notifications",
            "like",
            "dislike",
            "comments",
            "comment",
            "share",
            "remix",
            "save",
            "more",
            "subscribe",
            "subscribed",
            "youtube",
            "more options",
            "report",
            "send feedback",
            "not interested"
        )

        if (isProgressOrTimestampText(lower)) return false
        if (lower in blockedControls) return false
        if (lower.startsWith("like,") || lower.startsWith("dislike,") || lower.startsWith("comments,")) return false
        if (lower.endsWith("views") || lower.endsWith("likes")) return false
        if (text.matches(Regex("^[\\d.,]+[kKmMbB]?$"))) return false

        return true
    }

    private fun isTitleCandidate(value: String): Boolean {
        val text = value.trim()
        if (!isUsefulShortsText(text)) return false
        if (text.startsWith("@")) return false

        val lower = text.lowercase()
        if (lower.startsWith("subscribe to ")) return false
        if (lower.startsWith("view channel")) return false

        return true
    }

    private fun isProgressOrTimestampText(lowerText: String): Boolean {
        val timePattern = Regex("""\b\d{1,2}:\d{2}(?::\d{2})?\b""")
        if (timePattern.containsMatchIn(lowerText)) return true

        val progressWords = listOf("minutes", "seconds", "of")
        return progressWords.any { Regex("""\b$it\b""").containsMatchIn(lowerText) }
    }

    private fun hasFreshMediaSessionTitle(): Boolean {
        if (!isUsefulShortsText(lastMediaTitle)) return false
        return System.currentTimeMillis() - lastMediaTitleAt < MEDIA_SESSION_GRACE_MS
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
                val intent = Intent(ACTION_FLUTTER_EVENT).setPackage(packageName)
                intent.putExtra("method", method)

                if (data is Map<*, *>) {
                    val bundle = Bundle()
                    data.forEach { (key, value) ->
                        val stringKey = key?.toString() ?: return@forEach
                        when (value) {
                            is String -> bundle.putString(stringKey, value)
                            is Boolean -> bundle.putBoolean(stringKey, value)
                            is Int -> bundle.putInt(stringKey, value)
                            is Long -> bundle.putLong(stringKey, value)
                            is Double -> bundle.putDouble(stringKey, value)
                            is Float -> bundle.putFloat(stringKey, value)
                            null -> bundle.putString(stringKey, null)
                            else -> bundle.putString(stringKey, value.toString())
                        }
                    }
                    intent.putExtra("data", bundle)
                }

                sendBroadcast(intent)
            } catch (e: Exception) {
                Log.e("SendToFlutter", "Error: ${e.message}")
            }
        }
    }

    private val mediaUpdateReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            intent ?: return
            if (intent.action == ACTION_UPDATE_SERVICE_NOTIFICATION) {
                val notificationTitle = intent.getStringExtra("notification_title")
                    ?: "Monitoring Active"
                val notificationText = intent.getStringExtra("notification_text")
                    ?: "Watching your productivity..."
                updateForegroundNotification(notificationText, notificationTitle)
                return
            }
            if (intent.action == ACTION_SHOW_INTERVENTION) {
                val tier = intent.getIntExtra("tier", 2)
                val message = intent.getStringExtra("message") ?: "You've been distracted. Time to refocus."
                showInterventionNotification(tier, message)
                return
            }

            val title = intent.getStringExtra("title") ?: return
            val channel = intent.getStringExtra("channel") ?: ""
            val packageName = intent.getStringExtra("package") ?: "unknown_media"

            if (title == lastCapturedTitle) return
            lastCapturedTitle = title
            lastMediaTitle = title
            lastMediaTitleAt = System.currentTimeMillis()

            Log.i("MEDIA_MONITOR", "Media session detected: $title by $channel")
            updateForegroundNotification("Analysing content…", "Monitoring Active")

            val payload = mapOf(
                "package" to packageName,
                "title" to title,
                "channel" to channel,
                "timestamp" to System.currentTimeMillis()
            )
            sendToFlutter("content_extracted", payload)
        }
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        if (receiverRegistered) {
            try {
                unregisterReceiver(mediaUpdateReceiver)
            } catch (e: Exception) {
                Log.w("AccessibilityService", "Receiver already unregistered: ${e.message}")
            }
            receiverRegistered = false
        }
        shortsRunnable?.let { handler.removeCallbacks(it) }
        extractRunnable?.let { handler.removeCallbacks(it) }
        instagramReelsBlocker.destroy()
        executor.shutdownNow()
        super.onDestroy()
    }
}
