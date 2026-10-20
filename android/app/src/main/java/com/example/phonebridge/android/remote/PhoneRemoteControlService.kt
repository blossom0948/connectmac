package com.example.phonebridge.android.remote

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import com.example.phonebridge.android.link.LinkService
import java.lang.ref.WeakReference

/**
 * Optional, user-enabled touch bridge. It dispatches gestures only; it does not
 * request or inspect the accessibility tree or read on-screen text.
 */
class PhoneRemoteControlService : AccessibilityService() {
    companion object {
        @Volatile private var current = WeakReference<PhoneRemoteControlService>(null)

        fun isRunning(): Boolean = current.get() != null

        fun dispatch(action: String, x: Float = 0f, y: Float = 0f, endX: Float = 0f, endY: Float = 0f): Boolean {
            val service = current.get() ?: return false
            return service.dispatchRemoteAction(action, x, y, endX, endY)
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        current = WeakReference(this)
        LinkService.sendRemoteControlStatus(this)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        if (current.get() === this) current.clear()
        LinkService.sendRemoteControlStatus(this)
        super.onDestroy()
    }

    private fun dispatchRemoteAction(action: String, x: Float, y: Float, endX: Float, endY: Float): Boolean {
        when (action) {
            "back" -> return performGlobalAction(GLOBAL_ACTION_BACK)
            "home" -> return performGlobalAction(GLOBAL_ACTION_HOME)
            "recents" -> return performGlobalAction(GLOBAL_ACTION_RECENTS)
            "tap", "swipe" -> Unit
            else -> return false
        }

        val metrics = resources.displayMetrics
        val width = metrics.widthPixels.coerceAtLeast(1)
        val height = metrics.heightPixels.coerceAtLeast(1)
        fun px(value: Float, bound: Int) = (value.coerceIn(0f, 1f) * (bound - 1)).coerceIn(0f, (bound - 1).toFloat())
        val startX = px(x, width)
        val startY = px(y, height)
        val path = Path().apply {
            moveTo(startX, startY)
            if (action == "swipe") lineTo(px(endX, width), px(endY, height))
        }
        val duration = if (action == "swipe") 260L else 45L
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, duration))
            .build()
        return dispatchGesture(gesture, null, Handler(Looper.getMainLooper()))
    }
}
