package com.example.accessibility_service

import android.content.ComponentName
import android.content.Context
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.service.notification.NotificationListenerService
import android.util.Log

class MediaMonitorService : NotificationListenerService() {

    private lateinit var mediaSessionManager: MediaSessionManager
    private var activeControllers: List<MediaController> = emptyList()

    private val sessionListener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
        Log.d("MediaMonitor", "Active sessions changed")
        activeControllers = controllers ?: emptyList()
        registerCallbacks()
    }

    private val callback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) {
            super.onMetadataChanged(metadata)
            metadata?.let {
                val title = it.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""
                val artist = it.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: ""
                val album = it.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: ""

                if (title.isNotEmpty()) {
                    Log.i("MediaMonitor", "🎵 Media Playing: Title='$title', Artist='$artist', Album='$album'")
                    
                    // Broadcast the media info to our AccessibilityMonitorService
                    // so it can send it to Flutter using the existing MethodChannel
                    val intent = android.content.Intent("com.example.accessibility_service.MEDIA_UPDATE")
                    intent.putExtra("title", title)
                    intent.putExtra("channel", artist.ifEmpty { album })
                    intent.putExtra("package", "media_session") // Or extract package from controller
                    sendBroadcast(intent)
                }
            }
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i("MediaMonitor", "NotificationListener Connected - Media Monitoring Active")
        mediaSessionManager = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
        
        val componentName = ComponentName(this, MediaMonitorService::class.java)
        
        try {
            mediaSessionManager.addOnActiveSessionsChangedListener(sessionListener, componentName)
            activeControllers = mediaSessionManager.getActiveSessions(componentName)
            registerCallbacks()
        } catch (e: SecurityException) {
            Log.e("MediaMonitor", "Missing Notification Access permission: ${e.message}")
        }
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        try {
            mediaSessionManager.removeOnActiveSessionsChangedListener(sessionListener)
            unregisterCallbacks()
        } catch (e: Exception) {
            Log.e("MediaMonitor", "Error disconnecting listener: ${e.message}")
        }
    }

    private fun registerCallbacks() {
        activeControllers.forEach { controller ->
            controller.registerCallback(callback)
            // Get current metadata immediately upon registration
            callback.onMetadataChanged(controller.metadata)
        }
    }

    private fun unregisterCallbacks() {
        activeControllers.forEach { controller ->
            controller.unregisterCallback(callback)
        }
    }
}
