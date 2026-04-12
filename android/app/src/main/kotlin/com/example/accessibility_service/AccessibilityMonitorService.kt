package com.example.accessibility_service

import android.accessibilityservice.AccessibilityService
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class AccessibilityMonitorService : AccessibilityService() {
    
    companion object {
        const val CHANNEL = "com.example.accessibility_service/monitor"
    }
    
    private lateinit var methodChannel: MethodChannel
    private lateinit var flutterEngine: FlutterEngine
    
    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.d("AccessibilityService", "Service Connected")
        
        // Initialize Flutter Engine
        flutterEngine = FlutterEngine(applicationContext)
        flutterEngine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        sendToFlutter("status", "Service started")
    }
    
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event?.let {
            val packageName = event.packageName?.toString() ?: "unknown"
            
            if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
                Log.d("Accessibility", "App changed: $packageName")
                sendToFlutter("app_changed", packageName)
                
                // Extract text after a delay
                android.os.Handler(mainLooper).postDelayed({
                    extractText()
                }, 500)
            }
        }
    }
    
    private fun extractText() {
        try {
            val rootNode = rootInActiveWindow
            if (rootNode != null) {
                val text = extractAllText(rootNode)
                if (text.isNotEmpty()) {
                    Log.d("Extracted", "Text: ${text.take(50)}...")
                    sendToFlutter("text", text)
                }
                rootNode.recycle()
            }
        } catch (e: Exception) {
            Log.e("Extract", "Error: ${e.message}")
        }
    }
    
    private fun extractAllText(node: AccessibilityNodeInfo): String {
        val texts = mutableListOf<String>()
        
        // Get current node text
        node.text?.toString()?.trim()?.takeIf { it.isNotEmpty() }?.let {
            texts.add(it)
        }
        
        // Get children texts
        for (i in 0 until node.childCount) {
            node.getChild(i)?.let { child ->
                texts.add(extractAllText(child))
                child.recycle()
            }
        }
        
        return texts.filter { it.isNotEmpty() }.joinToString(" | ")
    }
    
    private fun sendToFlutter(type: String, data: String) {
        try {
            methodChannel.invokeMethod(type, data)
        } catch (e: Exception) {
            Log.e("SendToFlutter", "Error: ${e.message}")
        }
    }
    
    override fun onInterrupt() {
        Log.d("AccessibilityService", "Service Interrupted")
    }
}