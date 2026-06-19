package com.example.accessibility_service

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.service.notification.NotificationListenerService
import android.util.Log

class MediaMonitorService : NotificationListenerService() {

    private lateinit var mediaSessionManager: MediaSessionManager
    private var activeControllers: List<MediaController> = emptyList()
    private val controllerCallbacks = mutableMapOf<MediaController, MediaController.Callback>()
    private var lastBroadcastSignature = ""

    private val sessionListener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
        Log.d("MediaMonitor", "Active sessions changed")
        unregisterCallbacks()
        activeControllers = controllers ?: emptyList()
        registerCallbacks()
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i("MediaMonitor", "NotificationListener connected - media monitoring active")
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
            if (::mediaSessionManager.isInitialized) {
                mediaSessionManager.removeOnActiveSessionsChangedListener(sessionListener)
            }
            unregisterCallbacks()
        } catch (e: Exception) {
            Log.e("MediaMonitor", "Error disconnecting listener: ${e.message}")
        }
    }

    override fun onDestroy() {
        unregisterCallbacks()
        super.onDestroy()
    }

    private fun registerCallbacks() {
        activeControllers.forEach { controller ->
            if (controllerCallbacks.containsKey(controller)) return@forEach

            val callback = object : MediaController.Callback() {
                override fun onMetadataChanged(metadata: MediaMetadata?) {
                    super.onMetadataChanged(metadata)
                    emitMediaUpdate(controller, "metadata")
                }

                override fun onPlaybackStateChanged(state: PlaybackState?) {
                    super.onPlaybackStateChanged(state)
                    emitMediaUpdate(controller, "playback_state")
                }

                override fun onSessionDestroyed() {
                    super.onSessionDestroyed()
                    unregisterController(controller)
                }
            }

            controllerCallbacks[controller] = callback
            controller.registerCallback(callback)
            emitMediaUpdate(controller, "initial")
        }
    }

    private fun unregisterCallbacks() {
        controllerCallbacks.toMap().forEach { (controller, callback) ->
            try {
                controller.unregisterCallback(callback)
            } catch (e: Exception) {
                Log.w("MediaMonitor", "Failed to unregister callback: ${e.message}")
            }
        }
        controllerCallbacks.clear()
    }

    private fun unregisterController(controller: MediaController) {
        controllerCallbacks.remove(controller)?.let { callback ->
            try {
                controller.unregisterCallback(callback)
            } catch (e: Exception) {
                Log.w("MediaMonitor", "Failed to unregister destroyed session: ${e.message}")
            }
        }
    }

    private fun emitMediaUpdate(controller: MediaController, reason: String) {
        val metadata = controller.metadata ?: return
        val title = metadata.getString(MediaMetadata.METADATA_KEY_TITLE)?.trim().orEmpty()
        if (title.isEmpty()) return

        val artist = metadata.getString(MediaMetadata.METADATA_KEY_ARTIST)?.trim().orEmpty()
        val album = metadata.getString(MediaMetadata.METADATA_KEY_ALBUM)?.trim().orEmpty()
        val channel = artist.ifEmpty { album }
        val packageName = controller.packageName ?: "media_session"
        val signature = "$packageName|$title|$channel"
        if (signature == lastBroadcastSignature) {
            return
        }

        lastBroadcastSignature = signature

        Log.i("MediaMonitor", "Media update ($reason): title='$title', channel='$channel', package='$packageName'")

        val intent = Intent("com.example.accessibility_service.MEDIA_UPDATE")
        intent.putExtra("title", title)
        intent.putExtra("channel", channel)
        intent.putExtra("package", packageName)
        sendBroadcast(intent)
    }
}
