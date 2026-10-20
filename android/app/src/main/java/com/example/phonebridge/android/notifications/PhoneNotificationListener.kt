package com.example.phonebridge.android.notifications

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Intent
import android.content.ComponentName
import android.media.session.PlaybackState
import android.media.session.MediaSessionManager
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import com.example.phonebridge.android.link.LinkService
import org.json.JSONObject
import org.json.JSONArray
import java.util.concurrent.ConcurrentHashMap

class PhoneNotificationListener : NotificationListenerService() {
    companion object {
        @Volatile private var active: PhoneNotificationListener? = null
        private val replyActions = ConcurrentHashMap<String, Notification.Action>()
        private val callActions = ConcurrentHashMap<String, Map<String, Notification.Action>>()
        private val postedNotificationKeys = ConcurrentHashMap.newKeySet<String>()

        fun sendReply(eventId: String, text: String): Boolean {
            val service = active ?: return false
            val action = replyActions[eventId] ?: return false
            val remoteInputs = action.remoteInputs ?: return false
            if (remoteInputs.isEmpty()) return false
            val intent = Intent()
            val results = android.os.Bundle().apply {
                remoteInputs.forEach { putCharSequence(it.resultKey, text) }
            }
            RemoteInput.addResultsToIntent(remoteInputs, intent, results)
            return runCatching {
                action.actionIntent.send(service, 0, intent)
                replyActions.remove(eventId)
                true
            }.getOrDefault(false)
        }

        fun controlMedia(action: String): String {
            val service = active ?: return "알림 접근을 허용하면 미디어를 제어할 수 있습니다."
            return runCatching {
                val manager = service.getSystemService(MEDIA_SESSION_SERVICE) as MediaSessionManager
                val sessions = manager.getActiveSessions(ComponentName(service, PhoneNotificationListener::class.java))
                val controller = sessions.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
                    ?: sessions.firstOrNull()
                    ?: return "활성 미디어 앱을 찾지 못했습니다."
                when (action) {
                    "play_pause" -> if (controller.playbackState?.state == PlaybackState.STATE_PLAYING) controller.transportControls.pause() else controller.transportControls.play()
                    "next" -> controller.transportControls.skipToNext()
                    "previous" -> controller.transportControls.skipToPrevious()
                    else -> return "지원하지 않는 미디어 명령입니다."
                }
                "미디어 제어 명령을 전달했습니다."
            }.getOrElse { "미디어 제어에 실패했습니다: ${it.localizedMessage ?: "권한 또는 재생 상태를 확인하세요"}" }
        }

        fun dispatchCallAction(eventId: String, actionId: String): Boolean {
            val service = active ?: return false
            val action = callActions[eventId]?.get(actionId) ?: return false
            return runCatching {
                action.actionIntent.send(service, 0, Intent())
                true
            }.getOrDefault(false)
        }

        fun dismissNotification(eventId: String): Boolean {
            val service = active ?: return false
            if (eventId !in postedNotificationKeys) return false
            return runCatching {
                service.cancelNotification(eventId)
                true
            }.getOrDefault(false)
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        active = this
    }

    override fun onListenerDisconnected() {
        active = null
        replyActions.clear()
        callActions.clear()
        postedNotificationKeys.clear()
        super.onListenerDisconnected()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        val extras = sbn.notification.extras ?: return
        val title = extras.getCharSequence(android.app.Notification.EXTRA_TITLE)?.toString().orEmpty()
        val body = (extras.getCharSequence(android.app.Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(android.app.Notification.EXTRA_TEXT))?.toString().orEmpty()
        if (title.isBlank() && body.isBlank()) return
        postedNotificationKeys.add(sbn.key)

        val replyAction = sbn.notification.actions?.firstOrNull { !it.remoteInputs.isNullOrEmpty() }
        if (replyAction != null) replyActions[sbn.key] = replyAction
        val callLike = sbn.notification.category == Notification.CATEGORY_CALL ||
            sbn.packageName.lowercase().let { it.contains("dialer") || it.contains("incall") || it.contains("telecom") }
        val availableCallActions = if (callLike) sbn.notification.actions.orEmpty().mapIndexedNotNull { index, action ->
            val title = action.title?.toString()?.trim().orEmpty()
            val normalized = title.lowercase()
            if (title.isNotBlank() && listOf("answer", "accept", "decline", "reject", "받기", "응답", "거절").any(normalized::contains)) {
                index.toString() to action
            } else null
        }.toMap() else emptyMap()
        if (availableCallActions.isNotEmpty()) callActions[sbn.key] = availableCallActions
        val messageApp = sbn.packageName.lowercase().let { app ->
            app.contains("messaging") || app.contains("messages") || app.contains("sms") || app.contains("mms")
        }
        val actionPayload = JSONArray()
        availableCallActions.forEach { (id, action) ->
            actionPayload.put(JSONObject().put("id", id).put("title", action.title.toString()))
        }
        val kind = when {
            availableCallActions.isNotEmpty() -> "call_notification"
            messageApp -> "message"
            else -> "notification"
        }
        val event = JSONObject()
            .put("kind", kind)
            .put("eventId", sbn.key)
            .put("title", title.take(300))
            .put("text", body.take(2_000))
            .put("source", sbn.packageName)
            .put("canReply", replyAction != null)
            .put("actions", actionPayload)
            .put("timestamp", sbn.postTime / 1000.0)
        LinkService.sendEvent(this, event)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        postedNotificationKeys.remove(sbn.key)
        replyActions.remove(sbn.key)
        callActions.remove(sbn.key)
    }
}
