package com.example.accessibility_service

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    // No longer needs a BroadcastReceiver because AccessibilityMonitorService 
    // now uses its own MethodChannel to talk to Flutter directly.
}
