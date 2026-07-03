package com.example.accessibility_service

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Blocks Instagram Reels with a full-screen overlay.
 *
 * Detection strategy (confirmed from live device logcat):
 * - While Reels is playing, Instagram fires TYPE_WINDOW_CONTENT_CHANGED
 *   events from a SeekBar (video progress) at ~300ms intervals.
 * - When the user navigates to any other tab (Home/Search/Profile/DMs),
 *   these SeekBar events stop completely.
 *
 * So: receiving a SeekBar event → show overlay and reset a hide-timeout.
 * When the timeout expires with no new SeekBar event → hide overlay.
 *
 * The overlay window height is capped at the Instagram tab bar top (y=1424px
 * on this device) so the tab bar is never covered and always tappable.
 */
class InstagramReelsBlocker(private val context: Context) {

    companion object {
        private const val TAG = "IGReelsBlocker"

        // How long after the last SeekBar event before we assume the user left Reels.
        // Seekbar fires every ~300ms while playing; 900ms gives 3 missed beats of margin.
        private const val REELS_EXIT_TIMEOUT_MS = 900L

        // After hiding the overlay, ignore SeekBar events for this long.
        // Instagram keeps playing video in background briefly after tab switch.
        private const val POST_HIDE_COOLDOWN_MS = 2500L

        // Debounce for showing the overlay to avoid flicker on first entry
        private const val SHOW_DEBOUNCE_MS = 150L

        // Fraction of the screen height the overlay covers. The remaining bottom
        // strip is left uncovered so Instagram's tab bar stays tappable. Computed
        // at runtime from the real screen size instead of a hardcoded dp value so
        // it works across all device resolutions.
        private const val OVERLAY_HEIGHT_FRACTION = 0.90
    }

    private val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val handler = Handler(Looper.getMainLooper())

    private var overlayView: View? = null
    private var isOverlayShown = false
    private var inCooldown = false

    private var pendingShow: Runnable? = null
    private var exitTimeout: Runnable? = null
    private var cooldownRunnable: Runnable? = null

    // ── Public API ────────────────────────────────────────────────────────────

    private fun isEnabled(): Boolean {
        val prefs = context.getSharedPreferences(
            MainActivity.PREFS_NAME, Context.MODE_PRIVATE
        )
        return prefs.getBoolean(MainActivity.PREF_REELS_BLOCK, true)
    }

    fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (!isEnabled()) {
            if (isOverlayShown) hideOverlay()
            return
        }

        val eventType = event.eventType

        // Only care about content-changed events (type 2048)
        if (eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) return

        val desc = event.contentDescription?.toString() ?: ""
        val className = event.className?.toString() ?: ""

        // SeekBar from Instagram = Reels video progress bar, confirmed in logs.
        // Match loosely: class name (most reliable, version-independent) OR any
        // description containing "seek" (covers "Seekbar", "Seek bar", "Seek
        // control", and locale variants) so detection survives Instagram updates.
        val isSeekBarEvent = className.contains("SeekBar", ignoreCase = true) ||
                desc.contains("seek", ignoreCase = true)

        if (isSeekBarEvent) {
            onReelsDetected()
        }
    }

    fun destroy() {
        handler.removeCallbacksAndMessages(null)
        inCooldown = false
        hideOverlay()
    }

    // ── Detection ─────────────────────────────────────────────────────────────

    private fun onReelsDetected() {
        // During cooldown (just hid the overlay), ignore SeekBar events from
        // background video playback continuing after tab switch
        if (inCooldown) return

        // Reset the exit timeout every time we see a SeekBar event
        exitTimeout?.let { handler.removeCallbacks(it) }
        exitTimeout = Runnable {
            Log.i(TAG, "No SeekBar events for ${REELS_EXIT_TIMEOUT_MS}ms — user left Reels")
            pendingShow?.let { handler.removeCallbacks(it) }
            pendingShow = null
            hideOverlay()
            // Enter cooldown to ignore background SeekBar events
            inCooldown = true
            cooldownRunnable?.let { handler.removeCallbacks(it) }
            cooldownRunnable = Runnable { inCooldown = false }
            handler.postDelayed(cooldownRunnable!!, POST_HIDE_COOLDOWN_MS)
        }
        handler.postDelayed(exitTimeout!!, REELS_EXIT_TIMEOUT_MS)

        // Schedule show with small debounce if not already visible
        if (!isOverlayShown && pendingShow == null) {
            pendingShow = Runnable {
                showOverlay()
                pendingShow = null
            }
            handler.postDelayed(pendingShow!!, SHOW_DEBOUNCE_MS)
        }
    }

    // ── Overlay ───────────────────────────────────────────────────────────────

    private fun showOverlay() {
        if (isOverlayShown) return
        if (!canDrawOverlays()) {
            Log.w(TAG, "SYSTEM_ALERT_WINDOW not granted — cannot show overlay")
            return
        }

        val density = context.resources.displayMetrics.density
        // Derive overlay height from the real screen height so it scales to any
        // device. Leaves the bottom ~10% clear for Instagram's tab bar.
        val screenHeightPx = context.resources.displayMetrics.heightPixels
        val overlayHeightPx = (screenHeightPx * OVERLAY_HEIGHT_FRACTION).toInt()

        val overlayType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_SYSTEM_ALERT

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            overlayHeightPx,
            overlayType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
        }

        val view = buildBlockerView(density)
        try {
            windowManager.addView(view, params)
            overlayView = view
            isOverlayShown = true
            Log.i(TAG, "Reels overlay shown")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to add overlay: ${e.message}")
        }
    }

    private fun hideOverlay() {
        val view = overlayView ?: return
        try {
            windowManager.removeView(view)
            Log.i(TAG, "Reels overlay hidden")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to remove overlay: ${e.message}")
        } finally {
            overlayView = null
            isOverlayShown = false
        }
    }

    private fun buildBlockerView(density: Float): View {
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.argb(242, 18, 18, 18))
        }

        val icon = ImageView(context).apply {
            setImageResource(android.R.drawable.ic_lock_lock)
            setColorFilter(Color.parseColor("#FF5252"))
            val sizePx = (56 * density).toInt()
            layoutParams = LinearLayout.LayoutParams(sizePx, sizePx).also {
                it.bottomMargin = (16 * density).toInt()
            }
        }
        root.addView(icon)

        val title = TextView(context).apply {
            text = "Reels Blocked"
            textSize = 22f
            setTextColor(Color.WHITE)
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).also { it.bottomMargin = (10 * density).toInt() }
        }
        root.addView(title)

        val subtitle = TextView(context).apply {
            text = "Use the nav bar below to go\nto Home, Search or Profile"
            textSize = 14f
            setTextColor(Color.parseColor("#B0B0B0"))
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).also {
                it.bottomMargin = (32 * density).toInt()
                it.leftMargin = (32 * density).toInt()
                it.rightMargin = (32 * density).toInt()
            }
        }
        root.addView(subtitle)

        val hint = TextView(context).apply {
            text = "↓  Nav bar is active below  ↓"
            textSize = 11f
            setTextColor(Color.parseColor("#555555"))
            gravity = Gravity.CENTER
        }
        root.addView(hint)

        return root
    }

    private fun canDrawOverlays(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
            android.provider.Settings.canDrawOverlays(context)
        else true
    }
}
