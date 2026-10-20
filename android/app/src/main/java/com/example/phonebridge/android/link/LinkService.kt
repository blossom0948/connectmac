package com.example.phonebridge.android.link

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetAddress
import java.net.Socket
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.security.MessageDigest
import java.io.RandomAccessFile
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Environment
import android.media.AudioManager
import android.media.ToneGenerator
import android.util.Base64
import com.example.phonebridge.android.notifications.PhoneNotificationListener
import com.example.phonebridge.android.remote.PhoneRemoteControlService
import java.io.ByteArrayOutputStream
import java.io.File

object ConnectionState {
    val status = MutableStateFlow("연결 안 됨")
    val receivedFiles = kotlinx.coroutines.flow.MutableStateFlow<List<ReceivedFileItem>>(emptyList())
    val screenShareStatus = MutableStateFlow("화면 공유 안 함")
    val transfers = MutableStateFlow<List<TransferProgress>>(emptyList())
    val diagnostics = MutableStateFlow<List<PhoneBridgeDiagnostic>>(emptyList())

    @Synchronized
    fun updateTransfer(transfer: TransferProgress) {
        val current = transfers.value.filterNot { it.id == transfer.id }
        transfers.value = (listOf(transfer) + current).take(30)
    }

}

data class ReceivedFileItem(val name: String, val path: String, val contentType: String, val size: Long)
data class TransferProgress(
    val id: String,
    val name: String,
    val direction: String,
    val totalBytes: Long,
    val transferredBytes: Long,
    val status: String,
    val detail: String,
)

class LinkService : Service() {
    companion object {
        const val ACTION_START = "com.example.phonebridge.action.START"
        const val ACTION_CHECK_CONNECTION = "com.example.phonebridge.action.CHECK_CONNECTION"
        const val ACTION_STOP = "com.example.phonebridge.action.STOP"
        const val ACTION_START_SCREEN_MIRROR = "com.example.phonebridge.action.START_SCREEN_MIRROR"
        const val ACTION_STOP_SCREEN_MIRROR = "com.example.phonebridge.action.STOP_SCREEN_MIRROR"
        const val EXTRA_PROJECTION_RESULT_CODE = "projection_result_code"
        const val EXTRA_PROJECTION_DATA = "projection_data"
        private const val CHANNEL_ID = "phonebridge_connection"
        private const val PHONE_ACTION_CHANNEL_ID = "phonebridge_phone_actions"
        private const val NOTIFICATION_ID = 4101
        private const val SERVICE_TYPE = "_phonebridge._tcp."
        private const val HEARTBEAT_INTERVAL_MS = 20_000L
        private const val HEARTBEAT_TIMEOUT_MS = 90_000L
        private const val CONNECTION_PROBE_TIMEOUT_MS = 8_000L
        private val executor: ExecutorService = Executors.newCachedThreadPool()
        private val fileTransferLock = Any()
        private val transferMonitor = Object()
        private val outgoingFileTransfers = mutableMapOf<String, OutgoingFileTransfer>()
        @Volatile private var currentService: LinkService? = null
        private val heartbeatScheduler = Executors.newSingleThreadScheduledExecutor()
        private val connectionLock = Any()
        private data class ActiveSession(
            val socket: Socket,
            val writer: BufferedWriter,
            val key: ByteArray,
            val heartbeatSupported: Boolean,
            val transferControlSupported: Boolean,
        )
        private class OutgoingFileTransfer(
            val id: String,
            val name: String,
            val contentType: String,
            val bytes: ByteArray,
            val count: Int,
        ) {
            var cancelled = false
            var readyNextIndex: Int? = null
            var acknowledgedNextIndex: Int? = null
            var completed: Boolean? = null
            var failure: String? = null
        }
        @Volatile private var activeSession: ActiveSession? = null
        @Volatile private var connecting = false
        @Volatile private var lastServerActivityAt = 0L
        @Volatile private var serverMessageSequence = 0L

        fun sendEvent(context: Context, event: JSONObject): Boolean {
            val session = activeSession ?: return false
            try {
                val line = LinkCrypto.seal(session.key, event).toString()
                return synchronized(session.writer) {
                    if (activeSession !== session || session.socket.isClosed) return@synchronized false
                    session.writer.write(line)
                    session.writer.newLine()
                    session.writer.flush()
                    true
                }
            } catch (_: Exception) {
                // Closing the socket wakes the reader, which clears this session and starts discovery again.
                if (activeSession === session) runCatching { session.socket.close() }
                return false
            }
        }

        fun isConnected(): Boolean = activeSession?.let { it.socket.isConnected && !it.socket.isClosed } == true

        fun sendRemoteControlStatus(context: Context) {
            val enabled = PhoneRemoteControlService.isRunning()
            sendEvent(context, JSONObject()
                .put("kind", "remote_control_status")
                .put("success", enabled)
                .put("text", if (enabled) "원격 터치를 사용할 수 있습니다." else "Android 설정에서 PhoneBridge 원격 터치 서비스를 켜세요."))
        }

        fun sendFile(context: Context, name: String, contentType: String, bytes: ByteArray, transferId: String? = null): Boolean {
            if (bytes.size > 100 * 1024 * 1024 || !isConnected()) return false
            return synchronized(fileTransferLock) {
                val currentTransferId = transferId ?: java.util.UUID.randomUUID().toString()
                val chunkSize = 24 * 1024
                val count = maxOf(1, (bytes.size + chunkSize - 1) / chunkSize)
                val transfer = OutgoingFileTransfer(currentTransferId, name, contentType, bytes, count)
                if (activeSession?.transferControlSupported != true) {
                    synchronized(transferMonitor) { outgoingFileTransfers[currentTransferId] = transfer }
                    return@synchronized try {
                        val sent = sendLegacyFile(context, transfer)
                        if (!sent && isCancelled(transfer)) {
                            ConnectionState.updateTransfer(TransferProgress(currentTransferId, name, "휴대폰 → Mac", bytes.size.toLong(), 0, "취소됨", "전송을 취소했습니다."))
                            PhoneBridgeDiagnostics.record("전송", "파일 전송을 취소했습니다.")
                        } else if (!sent) {
                            ConnectionState.updateTransfer(TransferProgress(currentTransferId, name, "휴대폰 → Mac", bytes.size.toLong(), 0, "실패", "구버전 Mac 연결이 끊겨 전송을 마치지 못했습니다."))
                            PhoneBridgeDiagnostics.record("전송", "구버전 Mac으로 파일 전송이 실패했습니다.")
                        } else PhoneBridgeDiagnostics.record("전송", "휴대폰에서 Mac으로 파일을 보냈습니다.")
                        sent
                    } finally {
                        synchronized(transferMonitor) { outgoingFileTransfers.remove(currentTransferId) }
                    }
                }
                synchronized(transferMonitor) { outgoingFileTransfers[currentTransferId] = transfer }
                PhoneBridgeDiagnostics.record("전송", "휴대폰에서 Mac으로 파일 전송을 시작했습니다.")
                try {
                    sendResumableFile(context, transfer)
                } finally {
                    synchronized(transferMonitor) { outgoingFileTransfers.remove(currentTransferId) }
                }
            }
        }

        private fun sendLegacyFile(context: Context, transfer: OutgoingFileTransfer): Boolean {
            ConnectionState.updateTransfer(TransferProgress(transfer.id, transfer.name, "휴대폰 → Mac", transfer.bytes.size.toLong(), 0, "전송 중", "구버전 Mac에 전송 중입니다."))
            val chunkSize = 24 * 1024
            for (index in 0 until transfer.count) {
                if (isCancelled(transfer)) return false
                if (!isConnected()) return false
                val start = index * chunkSize
                val end = minOf(start + chunkSize, transfer.bytes.size)
                if (!sendEvent(context, JSONObject()
                        .put("kind", "file_chunk")
                        .put("eventId", transfer.id)
                        .put("title", transfer.name)
                        .put("source", transfer.contentType)
                        .put("transferIndex", index)
                        .put("transferCount", transfer.count)
                        .put("payload", Base64.encodeToString(transfer.bytes.copyOfRange(start, end), Base64.NO_WRAP)))
                ) return false
                ConnectionState.updateTransfer(TransferProgress(transfer.id, transfer.name, "휴대폰 → Mac", transfer.bytes.size.toLong(), end.toLong(), "전송 중", "구버전 Mac에 전송 중입니다."))
            }
            ConnectionState.updateTransfer(TransferProgress(transfer.id, transfer.name, "휴대폰 → Mac", transfer.bytes.size.toLong(), transfer.bytes.size.toLong(), "완료", "파일을 전송했습니다."))
            return true
        }

        private fun sendResumableFile(context: Context, transfer: OutgoingFileTransfer): Boolean {
            val chunkSize = 24 * 1024
            var nextIndex = 0
            while (true) {
                if (isCancelled(transfer)) {
                    sendEvent(context, JSONObject().put("kind", "file_cancel").put("eventId", transfer.id))
                    ConnectionState.updateTransfer(TransferProgress(transfer.id, transfer.name, "휴대폰 → Mac", transfer.bytes.size.toLong(), minOf(transfer.bytes.size.toLong(), nextIndex.toLong() * chunkSize), "취소됨", "전송을 취소했습니다."))
                    return false
                }
                val session = activeSession?.takeIf { it.transferControlSupported }
                if (session == null) {
                    updateOutgoingTransfer(transfer, nextIndex, "이어받기 대기", "연결을 기다리는 중입니다.")
                    synchronized(transferMonitor) {
                        if (!transfer.cancelled) transferMonitor.wait(750)
                    }
                    continue
                }
                synchronized(transferMonitor) {
                    transfer.readyNextIndex = null
                    transfer.acknowledgedNextIndex = null
                    transfer.completed = null
                    transfer.failure = null
                }
                if (!sendEvent(context, JSONObject()
                        .put("kind", "file_start")
                        .put("eventId", transfer.id)
                        .put("title", transfer.name)
                        .put("source", transfer.contentType)
                        .put("size", transfer.bytes.size)
                        .put("transferCount", transfer.count)
                        .put("chunkSize", chunkSize))) continue
                if (!awaitTransferSignal(transfer, session, "ready")) {
                    if (isCancelled(transfer) || activeSession !== session) continue
                    ConnectionState.updateTransfer(TransferProgress(transfer.id, transfer.name, "휴대폰 → Mac", transfer.bytes.size.toLong(), 0, "실패", "Mac이 전송 준비에 응답하지 않았습니다."))
                    PhoneBridgeDiagnostics.record("전송", "Mac이 파일 전송 준비에 응답하지 않았습니다.")
                    return false
                }
                synchronized(transferMonitor) {
                    transfer.failure?.let { failure ->
                        ConnectionState.updateTransfer(TransferProgress(transfer.id, transfer.name, "휴대폰 → Mac", transfer.bytes.size.toLong(), 0, "실패", failure))
                        return false
                    }
                    nextIndex = transfer.readyNextIndex ?: 0
                }
                updateOutgoingTransfer(transfer, nextIndex, "전송 중", "이어받기를 시작했습니다.")
                var disconnected = false
                while (nextIndex < transfer.count) {
                    if (isCancelled(transfer)) break
                    val start = nextIndex * chunkSize
                    val end = minOf(start + chunkSize, transfer.bytes.size)
                    synchronized(transferMonitor) { transfer.acknowledgedNextIndex = null }
                    if (!sendEvent(context, JSONObject()
                            .put("kind", "file_chunk")
                            .put("eventId", transfer.id)
                            .put("title", transfer.name)
                            .put("source", transfer.contentType)
                            .put("transferIndex", nextIndex)
                            .put("transferCount", transfer.count)
                            .put("payload", Base64.encodeToString(transfer.bytes.copyOfRange(start, end), Base64.NO_WRAP)))) {
                        disconnected = true
                        break
                    }
                    if (!awaitTransferSignal(transfer, session, "ack")) {
                        if (isCancelled(transfer)) break
                        if (activeSession !== session) { disconnected = true; break }
                        ConnectionState.updateTransfer(TransferProgress(transfer.id, transfer.name, "휴대폰 → Mac", transfer.bytes.size.toLong(), nextIndex.toLong() * chunkSize, "실패", "Mac의 전송 확인이 시간 초과되었습니다."))
                        PhoneBridgeDiagnostics.record("전송", "Mac의 파일 조각 저장 확인이 시간 초과되었습니다.")
                        return false
                    }
                    synchronized(transferMonitor) {
                        transfer.failure?.let { failure ->
                            ConnectionState.updateTransfer(TransferProgress(transfer.id, transfer.name, "휴대폰 → Mac", transfer.bytes.size.toLong(), nextIndex.toLong() * chunkSize, "실패", failure))
                            return false
                        }
                        val acknowledged = transfer.acknowledgedNextIndex ?: nextIndex
                        if (acknowledged <= nextIndex || acknowledged > transfer.count) {
                            ConnectionState.updateTransfer(TransferProgress(transfer.id, transfer.name, "휴대폰 → Mac", transfer.bytes.size.toLong(), nextIndex.toLong() * chunkSize, "실패", "잘못된 전송 확인을 받았습니다."))
                            return false
                        }
                        nextIndex = acknowledged
                    }
                    updateOutgoingTransfer(transfer, nextIndex, "전송 중", "Mac에 저장 중입니다.")
                }
                if (isCancelled(transfer)) continue
                if (disconnected || activeSession !== session) continue
                if (!awaitTransferSignal(transfer, session, "complete")) {
                    if (activeSession !== session || isCancelled(transfer)) continue
                    ConnectionState.updateTransfer(TransferProgress(transfer.id, transfer.name, "휴대폰 → Mac", transfer.bytes.size.toLong(), transfer.bytes.size.toLong(), "실패", "Mac의 저장 확인이 시간 초과되었습니다."))
                    return false
                }
                synchronized(transferMonitor) {
                    val success = transfer.completed == true
                    val detail = transfer.failure ?: if (success) "Mac에 안전하게 저장했습니다." else "Mac에 파일을 저장하지 못했습니다."
                    ConnectionState.updateTransfer(TransferProgress(transfer.id, transfer.name, "휴대폰 → Mac", transfer.bytes.size.toLong(), if (success) transfer.bytes.size.toLong() else nextIndex.toLong() * chunkSize, if (success) "완료" else "실패", detail))
                    PhoneBridgeDiagnostics.record("전송", if (success) "휴대폰에서 Mac으로 파일 전송이 완료되었습니다." else "휴대폰에서 Mac으로 파일 전송이 실패했습니다.")
                    return success
                }
            }
        }

        private fun updateOutgoingTransfer(transfer: OutgoingFileTransfer, nextIndex: Int, status: String, detail: String) {
            val bytesSent = minOf(transfer.bytes.size.toLong(), nextIndex.toLong() * 24 * 1024)
            ConnectionState.updateTransfer(TransferProgress(transfer.id, transfer.name, "휴대폰 → Mac", transfer.bytes.size.toLong(), bytesSent, status, detail))
        }

        private fun isCancelled(transfer: OutgoingFileTransfer): Boolean = synchronized(transferMonitor) { transfer.cancelled }

        private fun awaitTransferSignal(transfer: OutgoingFileTransfer, session: ActiveSession, signal: String): Boolean {
            val deadline = SystemClock.elapsedRealtime() + TimeUnit.SECONDS.toMillis(60)
            synchronized(transferMonitor) {
                while (!transfer.cancelled && activeSession === session && SystemClock.elapsedRealtime() < deadline) {
                    val ready = when (signal) {
                        "ready" -> transfer.readyNextIndex != null || transfer.failure != null
                        "ack" -> transfer.acknowledgedNextIndex != null || transfer.failure != null
                        else -> transfer.completed != null || transfer.failure != null
                    }
                    if (ready) return true
                    transferMonitor.wait(500)
                }
                return false
            }
        }

        fun cancelFileTransfer(id: String) {
            val service = currentService
            synchronized(transferMonitor) {
                outgoingFileTransfers[id]?.cancelled = true
                transferMonitor.notifyAll()
            }
            if (service != null) sendEvent(service, JSONObject().put("kind", "file_cancel").put("eventId", id))
            ConnectionState.transfers.value.firstOrNull { it.id == id }?.let { current ->
                ConnectionState.updateTransfer(current.copy(status = "취소됨", detail = "전송을 취소했습니다."))
            }
            service?.let { instance -> executor.execute { instance.cancelIncomingFileTransfer(id, notifyPeer = false) } }
            PhoneBridgeDiagnostics.record("전송", "파일 전송을 사용자가 취소했습니다.")
        }

        fun sendClipboardText(context: Context, text: String): Boolean {
            if (text.isEmpty() || text.toByteArray(Charsets.UTF_8).size > 20 * 1024 || !isConnected()) return false
            sendEvent(context, JSONObject().put("kind", "clipboard_text").put("text", text))
            return true
        }
    }

    private var nsdManager: NsdManager? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var callCallback: TelephonyCallback? = null
    @Suppress("DEPRECATION")
    private var legacyCallListener: PhoneStateListener? = null
    private var batteryReceiver: android.content.BroadcastReceiver? = null
    private var retryScheduled = false
    private var retryAttempt = 0
    private val retryLock = Any()
    private val discoveryLock = Any()
    private val retryHandler = Handler(Looper.getMainLooper())
    private var heartbeatFuture: ScheduledFuture<*>? = null
    @Volatile private var resolvingService = false
    private var findPhoneTone: ToneGenerator? = null
    private var mediaProjection: MediaProjection? = null
    private var projectionCallback: MediaProjection.Callback? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var imageThread: HandlerThread? = null
    private var lastScreenFrameAt = 0L
    private data class IncomingTransfer(
        val name: String,
        val contentType: String,
        val count: Int,
        var lastActivityAt: Long = SystemClock.elapsedRealtime(),
        val chunks: MutableMap<Int, ByteArray> = mutableMapOf(),
        var receivedBytes: Int = 0,
    )
    private val incomingTransfers = mutableMapOf<String, IncomingTransfer>()
    private data class ResumableIncomingTransfer(
        val id: String,
        val name: String,
        val contentType: String,
        val size: Long,
        val count: Int,
        val partFile: File,
        val manifestFile: File,
        var nextIndex: Int,
        var lastActivityAt: Long = SystemClock.elapsedRealtime(),
        var completedFileName: String? = null,
    )
    private val resumableIncomingTransfers = mutableMapOf<String, ResumableIncomingTransfer>()

    override fun onCreate() {
        super.onCreate()
        currentService = this
        createNotificationChannel()
        registerBatteryUpdates()
        cleanStaleIncomingTransfers()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopLink()
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_STOP_SCREEN_MIRROR) {
            stopScreenMirror(notifyMac = true)
            return START_STICKY
        }
        if (intent?.action == ACTION_CHECK_CONNECTION && isConnected()) {
            checkConnectionHealth()
            return START_STICKY
        }
        val startProjection = intent?.action == ACTION_START_SCREEN_MIRROR
        startForegroundForProjection(startProjection)
        registerCallState()
        val pairing = PairingStore.load(this)
        if (pairing == null) {
            ConnectionState.status.value = "먼저 Mac에서 QR 코드를 스캔하세요"
            stopSelf()
            return START_NOT_STICKY
        }
        if (!isConnected()) {
            ConnectionState.status.value = "Mac에 연결 중…"
            executor.execute { connect(pairing.host, pairing.port, pairing.secret) }
        }
        if (startProjection) {
            val resultCode = intent?.getIntExtra(EXTRA_PROJECTION_RESULT_CODE, 0) ?: 0
            val permissionData = if (Build.VERSION.SDK_INT >= 33) {
                intent?.getParcelableExtra(EXTRA_PROJECTION_DATA, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent?.getParcelableExtra(EXTRA_PROJECTION_DATA)
            }
            startScreenMirror(resultCode, permissionData)
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopLink()
        if (currentService === this) currentService = null
        stopScreenMirror(notifyMac = false)
        findPhoneTone?.release()
        findPhoneTone = null
        batteryReceiver?.let { runCatching { unregisterReceiver(it) } }
        if (Build.VERSION.SDK_INT >= 31) {
            val manager = getSystemService(TELEPHONY_SERVICE) as TelephonyManager
            callCallback?.let { runCatching { manager.unregisterTelephonyCallback(it) } }
        } else {
            @Suppress("DEPRECATION")
            val manager = getSystemService(TELEPHONY_SERVICE) as TelephonyManager
            @Suppress("DEPRECATION")
            legacyCallListener?.let { runCatching { manager.listen(it, PhoneStateListener.LISTEN_NONE) } }
        }
        discoveryListener?.let { listener -> runCatching { nsdManager?.stopServiceDiscovery(listener) } }
        super.onDestroy()
    }

    private fun startForegroundForProjection(includeProjection: Boolean) {
        if (Build.VERSION.SDK_INT >= 29) {
            var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            if (includeProjection) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            ServiceCompat.startForeground(this, NOTIFICATION_ID, connectionNotification(), types)
        } else {
            startForeground(NOTIFICATION_ID, connectionNotification())
        }
    }

    private fun startScreenMirror(resultCode: Int, permissionData: Intent?) {
        if (permissionData == null || resultCode == 0) {
            ConnectionState.screenShareStatus.value = "화면 공유 권한을 받지 못했습니다"
            return
        }
        stopScreenMirror(notifyMac = false)
        runCatching {
            val manager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val projection = requireNotNull(manager.getMediaProjection(resultCode, permissionData)) {
                "화면 공유 세션을 시작할 수 없습니다."
            }
            mediaProjection = projection

            val metrics = resources.displayMetrics
            val scale = minOf(360f / metrics.widthPixels, 720f / metrics.heightPixels, 1f)
            val captureWidth = (metrics.widthPixels * scale).toInt().coerceAtLeast(1)
            val captureHeight = (metrics.heightPixels * scale).toInt().coerceAtLeast(1)
            val reader = ImageReader.newInstance(captureWidth, captureHeight, PixelFormat.RGBA_8888, 2)
            imageReader = reader
            val thread = HandlerThread("PhoneBridgeScreenCapture").apply { start() }
            imageThread = thread
            val callback = object : MediaProjection.Callback() {
                override fun onStop() {
                    stopScreenMirror(notifyMac = true, stopProjection = false)
                }
            }
            projectionCallback = callback
            projection.registerCallback(callback, Handler(thread.looper))
            virtualDisplay = projection.createVirtualDisplay(
                "PhoneBridgeScreenShare",
                captureWidth,
                captureHeight,
                metrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                reader.surface,
                null,
                null
            )
            reader.setOnImageAvailableListener({ source -> sendScreenFrame(source) }, Handler(thread.looper))
            ConnectionState.screenShareStatus.value = "화면 공유 중"
        }.onFailure {
            stopScreenMirror(notifyMac = false)
            ConnectionState.screenShareStatus.value = "화면 공유를 시작하지 못했습니다"
        }
    }

    private fun sendScreenFrame(reader: ImageReader) {
        val now = System.currentTimeMillis()
        if (now - lastScreenFrameAt < 500) return
        val image = runCatching { reader.acquireLatestImage() }.getOrNull() ?: return
        try {
            val plane = image.planes.firstOrNull() ?: return
            val pixelStride = plane.pixelStride
            val paddedWidth = (plane.rowStride / pixelStride).coerceAtLeast(image.width)
            val padded = Bitmap.createBitmap(paddedWidth, image.height, Bitmap.Config.ARGB_8888)
            padded.copyPixelsFromBuffer(plane.buffer)
            val bitmap = Bitmap.createBitmap(padded, 0, 0, image.width, image.height)
            val output = ByteArrayOutputStream()
            var jpeg = ByteArray(0)
            for (quality in listOf(38, 30, 22)) {
                output.reset()
                bitmap.compress(Bitmap.CompressFormat.JPEG, quality, output)
                jpeg = output.toByteArray()
                if (jpeg.size <= 28 * 1024) break
            }
            bitmap.recycle()
            padded.recycle()
            if (jpeg.size <= 28 * 1024 && isConnected()) {
                lastScreenFrameAt = now
                sendEvent(this, JSONObject().put("kind", "screen_frame")
                    .put("payload", Base64.encodeToString(jpeg, Base64.NO_WRAP)))
            }
        } catch (_: Throwable) {
            // A transient buffer failure can happen during rotation; the next frame will retry.
        } finally {
            image.close()
        }
    }

    private fun stopScreenMirror(notifyMac: Boolean, stopProjection: Boolean = true) {
        val projection = mediaProjection
        mediaProjection = null
        projectionCallback?.let { callback -> runCatching { projection?.unregisterCallback(callback) } }
        projectionCallback = null
        virtualDisplay?.release()
        virtualDisplay = null
        imageReader?.close()
        imageReader = null
        imageThread?.quitSafely()
        imageThread = null
        if (stopProjection) runCatching { projection?.stop() }
        ConnectionState.screenShareStatus.value = "화면 공유 안 함"
        if (notifyMac) sendEvent(this, JSONObject().put("kind", "screen_share_stopped"))
    }

    private fun connect(host: String, port: Int, secret: ByteArray) {
        synchronized(connectionLock) {
            if (isConnected() || connecting) return
            connecting = true
        }
        var candidate: Socket? = null
        try {
            val socket = Socket()
            candidate = socket
            socket.connect(java.net.InetSocketAddress(host, port), 5_000)
            socket.tcpNoDelay = true
            socket.keepAlive = true
            socket.soTimeout = 10_000
            val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
            val writer = BufferedWriter(OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8))
            val challengeMessage = JSONObject(reader.readLine())
            check(challengeMessage.optString("type") == "challenge")
            val nonce = LinkCrypto.fromB64(challengeMessage.getString("nonce"))
            val deviceName = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android phone"
            val proof = LinkCrypto.hmac(secret, "auth|${LinkCrypto.b64(nonce)}|$deviceName")
            synchronized(writer) {
                writer.write(JSONObject().put("type", "auth").put("name", deviceName).put("proof", LinkCrypto.b64(proof))
                    .put("capabilities", org.json.JSONArray().put("peer-probe-v1").put("transfer-control-v1")).toString())
                writer.newLine()
                writer.flush()
            }
            val welcome = JSONObject(reader.readLine())
            check(welcome.optString("type") == "welcome")
            val expected = LinkCrypto.hmac(secret, "welcome|${LinkCrypto.b64(nonce)}|$deviceName")
            check(expected.contentEquals(LinkCrypto.fromB64(welcome.getString("proof"))))
            val capabilities = welcome.optJSONArray("capabilities")
            val heartbeatSupported = capabilities != null && (0 until capabilities.length()).any {
                capabilities.optString(it) == "heartbeat-v1"
            }
            val transferControlSupported = capabilities != null && (0 until capabilities.length()).any {
                capabilities.optString(it) == "transfer-control-v1"
            }
            socket.soTimeout = if (heartbeatSupported) (HEARTBEAT_TIMEOUT_MS + 5_000L).toInt() else 0
            val sessionKey = LinkCrypto.deriveSessionKey(secret, nonce)
            synchronized(connectionLock) {
                activeSession?.takeIf { it.socket !== socket }?.let { runCatching { it.socket.close() } }
                activeSession = ActiveSession(socket, writer, sessionKey, heartbeatSupported, transferControlSupported)
                lastServerActivityAt = SystemClock.elapsedRealtime()
                connecting = false
            }
            heartbeatFuture?.cancel(false)
            heartbeatFuture = if (heartbeatSupported) {
                heartbeatScheduler.scheduleAtFixedRate({
                    if (activeSession?.socket !== socket || socket.isClosed) return@scheduleAtFixedRate
                    if (SystemClock.elapsedRealtime() - lastServerActivityAt >= HEARTBEAT_TIMEOUT_MS) {
                        handleConnectionLoss(socket, "Mac 응답이 없어 다시 연결하는 중…")
                        return@scheduleAtFixedRate
                    }
                    sendEvent(this, JSONObject().put("kind", "heartbeat_ping"))
                }, HEARTBEAT_INTERVAL_MS, HEARTBEAT_INTERVAL_MS, TimeUnit.MILLISECONDS)
            } else null
            synchronized(retryLock) {
                retryAttempt = 0
                retryScheduled = false
                retryHandler.removeCallbacksAndMessages(null)
            }
            stopDiscovery()
            ConnectionState.status.value = "Mac에 연결됨"
            PhoneBridgeDiagnostics.record("연결", "Mac과 로컬 Wi‑Fi 연결이 수립되었습니다.")
            synchronized(transferMonitor) { transferMonitor.notifyAll() }
            sendBatterySnapshot()
            sendRemoteControlStatus(this)
            executor.execute { readServer(socket, reader, sessionKey) }
        } catch (error: Exception) {
            candidate?.let { runCatching { it.close() } }
            synchronized(connectionLock) {
                if (candidate != null && activeSession?.socket === candidate) clearSocket(candidate)
                connecting = false
            }
            ConnectionState.status.value = "Mac을 찾지 못했습니다 · 로컬 Wi‑Fi에서 검색 중"
            scheduleDiscovery()
        }
    }

    private fun readServer(socket: Socket, reader: BufferedReader, sessionKey: ByteArray) {
        try {
            while (!socket.isClosed) {
                val line = reader.readLine() ?: break
                val command = LinkCrypto.open(sessionKey, JSONObject(line))
                // Any authenticated Mac command proves the channel is alive. Counting only pongs
                // incorrectly dropped the session during larger interactive operations.
                lastServerActivityAt = SystemClock.elapsedRealtime()
                serverMessageSequence++
                if (command.optString("kind") == "heartbeat_pong") {
                    lastServerActivityAt = SystemClock.elapsedRealtime()
                } else {
                    handleCommand(command)
                }
            }
        } catch (_: Exception) {
            // A read timeout is also a link failure; heartbeat/retry below restores the session.
        }
        if (activeSession?.socket === socket) {
            handleConnectionLoss(socket, "연결이 끊어졌습니다 · 다시 연결 중")
        }
    }

    private fun handleConnectionLoss(socket: Socket, status: String) {
        synchronized(connectionLock) {
            if (activeSession?.socket !== socket) return
            clearSocket(socket)
        }
        stopDiscovery()
        stopScreenMirror(notifyMac = false)
        ConnectionState.status.value = status
        PhoneBridgeDiagnostics.record("연결", "연결이 끊겨 자동 재연결을 시작했습니다.")
        synchronized(transferMonitor) { transferMonitor.notifyAll() }
        scheduleDiscovery()
    }

    private fun handleCommand(command: JSONObject) {
        when (command.optString("kind")) {
            "heartbeat_ping" -> sendEvent(this, JSONObject().put("kind", "heartbeat_pong").put("timestamp", System.currentTimeMillis() / 1000.0))
            "file_transfer_ready" -> updateOutgoingTransferResponse(command, "ready")
            "file_chunk_ack" -> updateOutgoingTransferResponse(command, "ack")
            "file_received" -> updateOutgoingTransferResponse(command, "complete")
            "file_cancelled" -> updateOutgoingTransferResponse(command, "cancelled")
            "notification_reply" -> {
                val eventId = command.optString("eventId")
                val success = PhoneNotificationListener.sendReply(eventId, command.optString("text"))
                sendEvent(this, JSONObject().put("kind", "reply_result").put("eventId", eventId)
                    .put("text", if (success) "답장을 휴대폰 앱으로 보냈습니다." else "이 알림은 빠른 답장을 지원하지 않거나 만료되었습니다."))
            }
            "media_control" -> {
                val message = PhoneNotificationListener.controlMedia(command.optString("action"))
                sendEvent(this, JSONObject().put("kind", "media_result").put("text", message))
            }
            "call_action" -> {
                val success = PhoneNotificationListener.dispatchCallAction(command.optString("eventId"), command.optString("actionId"))
                sendEvent(this, JSONObject().put("kind", "call_action_result").put("text", if (success) "전화 동작을 휴대폰에 전달했습니다." else "전화 알림이 만료되었거나 이 동작을 사용할 수 없습니다."))
            }
            "dismiss_notification" -> {
                val eventId = command.optString("eventId")
                val success = PhoneNotificationListener.dismissNotification(eventId)
                sendEvent(this, JSONObject()
                    .put("kind", "dismiss_notification_result")
                    .put("eventId", eventId)
                    .put("success", success)
                    .put("text", if (success) "휴대폰 알림을 지웠습니다." else "알림이 이미 사라졌거나 알림 접근 권한을 사용할 수 없습니다."))
            }
            "compose_sms" -> enqueueSmsDraft(command.optString("recipient"), command.optString("text"))
            "open_dialer" -> enqueueDialRequest(command.optString("recipient"))
            "find_phone" -> {
                runCatching {
                    findPhoneTone?.release()
                    val tone = ToneGenerator(AudioManager.STREAM_ALARM, 90)
                    findPhoneTone = tone
                    tone.startTone(ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD, 12_000)
                    executor.execute {
                        Thread.sleep(12_500)
                        tone.release()
                        if (findPhoneTone === tone) findPhoneTone = null
                    }
                    sendEvent(this, JSONObject().put("kind", "find_phone_result").put("text", "휴대폰에서 찾기 알림음을 재생했습니다."))
                }.onFailure {
                    sendEvent(this, JSONObject().put("kind", "find_phone_result").put("text", "휴대폰에서 소리를 재생하지 못했습니다."))
                }
            }
            "stop_screen_mirror" -> stopScreenMirror(notifyMac = true)
            "remote_control" -> {
                val action = command.optString("action")
                val projectionActive = mediaProjection != null
                val serviceEnabled = PhoneRemoteControlService.isRunning()
                val result = if (projectionActive && serviceEnabled) {
                    PhoneRemoteControlService.dispatch(
                        action = action,
                        x = command.optDouble("x", 0.0).toFloat(),
                        y = command.optDouble("y", 0.0).toFloat(),
                        endX = command.optDouble("endX", 0.0).toFloat(),
                        endY = command.optDouble("endY", 0.0).toFloat(),
                    )
                } else false
                sendEvent(this, JSONObject()
                    .put("kind", "remote_control_result")
                    .put("success", result)
                    .put("text", when {
                        !projectionActive -> "Android에서 화면 공유를 먼저 시작하세요."
                        !serviceEnabled -> "Android 설정에서 PhoneBridge 원격 터치 서비스를 켜세요."
                        result -> "화면 조작을 휴대폰으로 보냈습니다."
                        else -> "화면 조작을 실행하지 못했습니다. 잠금 화면이나 보호된 앱인지 확인하세요."
                    }))
            }
            "gallery_list" -> executor.execute {
                PhoneGalleryBridge.sendPage(this, command.optInt("offset", 0), command.optInt("limit", 40))
            }
            "gallery_fetch" -> executor.execute {
                PhoneGalleryBridge.sendItem(this, command.optString("assetId"), command.optString("transferId"))
            }
            "clipboard_set" -> {
                val text = command.optString("text")
                if (text.isEmpty() || text.toByteArray(Charsets.UTF_8).size > 20 * 1024) {
                    sendEvent(this, JSONObject().put("kind", "clipboard_result").put("text", "클립보드 텍스트가 비어 있거나 20KB를 넘습니다."))
                } else {
                    runCatching {
                        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                        val clip = ClipData.newPlainText("PhoneBridge", text)
                        clip.description.extras = android.os.PersistableBundle().apply {
                            putBoolean("android.content.extra.IS_SENSITIVE", true)
                        }
                        clipboard.setPrimaryClip(clip)
                        sendEvent(this, JSONObject().put("kind", "clipboard_result").put("text", "휴대폰 클립보드에 텍스트를 복사했습니다."))
                    }.onFailure {
                        sendEvent(this, JSONObject().put("kind", "clipboard_result").put("text", "휴대폰 클립보드에 복사하지 못했습니다."))
                    }
                }
            }
            "file_start" -> beginIncomingFileTransfer(command)
            "file_cancel" -> cancelIncomingFileTransfer(command.optString("eventId"))
            "file_chunk" -> {
                if (command.optString("eventId") in resumableIncomingTransfers || hasIncomingTransferManifest(command.optString("eventId"))) {
                    receiveResumableFileChunk(command)
                } else receiveFileChunk(command)
            }
        }
    }

    private fun updateOutgoingTransferResponse(command: JSONObject, kind: String) {
        val id = command.optString("eventId")
        synchronized(transferMonitor) {
            val transfer = outgoingFileTransfers[id] ?: return
            when (kind) {
                "ready" -> {
                    if (command.optBoolean("success", true)) transfer.readyNextIndex = command.optInt("nextIndex", 0)
                    else transfer.failure = command.optString("text", "Mac이 전송 준비를 거부했습니다.")
                }
                "ack" -> {
                    if (command.optBoolean("success", true)) transfer.acknowledgedNextIndex = command.optInt("nextIndex", -1)
                    else transfer.failure = command.optString("text", "Mac이 파일 조각을 저장하지 못했습니다.")
                }
                "complete" -> {
                    transfer.completed = command.optBoolean("success", true)
                    if (!command.optBoolean("success", true)) transfer.failure = command.optString("text", "Mac에 파일을 저장하지 못했습니다.")
                }
                "cancelled" -> transfer.cancelled = true
            }
            transferMonitor.notifyAll()
        }
    }

    private fun enqueueSmsDraft(rawRecipient: String, body: String) {
        val recipient = normalizePhoneNumber(rawRecipient)
        if (recipient == null || body.isBlank() || body.toByteArray(Charsets.UTF_8).size > 4_000) {
            sendEvent(this, JSONObject().put("kind", "phone_action_result").put("text", "문자 작성 요청을 확인할 수 없습니다."))
            return
        }
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            sendEvent(this, JSONObject().put("kind", "phone_action_result").put("text", "Android에서 PhoneBridge 알림 권한을 켜야 문자 작성 알림을 받을 수 있습니다."))
            return
        }

        val notificationId = (System.currentTimeMillis() and 0x7FFFFFFF).toInt()
        val composeIntent = Intent(Intent.ACTION_SENDTO, Uri.fromParts("smsto", recipient, null))
            .putExtra("sms_body", body)
        val pendingIntent = PendingIntent.getActivity(
            this,
            notificationId,
            composeIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, PHONE_ACTION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentTitle("Mac에서 문자를 작성했습니다")
            .setContentText("눌러서 기본 메시지 앱에서 확인하고 전송하세요")
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setContentIntent(pendingIntent)
            .addAction(android.R.drawable.ic_dialog_email, "문자 작성 열기", pendingIntent)
            .setAutoCancel(true)
            .build()
        runCatching {
            getSystemService(NotificationManager::class.java).notify(notificationId, notification)
        }.onSuccess {
            sendEvent(this, JSONObject().put("kind", "phone_action_result").put("text", "휴대폰에 문자 작성 알림을 보냈습니다. 휴대폰에서 확인하고 직접 전송하세요."))
        }.onFailure {
            sendEvent(this, JSONObject().put("kind", "phone_action_result").put("text", "문자 작성 알림을 표시하지 못했습니다. Android 알림 권한을 확인하세요."))
        }
    }

    private fun enqueueDialRequest(rawRecipient: String) {
        val recipient = normalizePhoneNumber(rawRecipient)
        if (recipient == null) {
            sendEvent(this, JSONObject().put("kind", "phone_action_result").put("text", "전화번호를 확인할 수 없습니다."))
            return
        }
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            sendEvent(this, JSONObject().put("kind", "phone_action_result").put("text", "Android에서 PhoneBridge 알림 권한을 켜야 전화 걸기 알림을 받을 수 있습니다."))
            return
        }

        val notificationId = ((System.currentTimeMillis() + 1) and 0x7FFFFFFF).toInt()
        val dialIntent = Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", recipient, null))
        val pendingIntent = PendingIntent.getActivity(
            this,
            notificationId,
            dialIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, PHONE_ACTION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.sym_action_call)
            .setContentTitle("Mac에서 전화 걸기를 요청했습니다")
            .setContentText("눌러서 휴대폰에서 번호를 확인하고 통화를 시작하세요")
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setContentIntent(pendingIntent)
            .addAction(android.R.drawable.sym_action_call, "전화 앱 열기", pendingIntent)
            .setAutoCancel(true)
            .build()
        runCatching {
            getSystemService(NotificationManager::class.java).notify(notificationId, notification)
        }.onSuccess {
            sendEvent(this, JSONObject().put("kind", "phone_action_result").put("text", "휴대폰에 전화 걸기 알림을 보냈습니다. 휴대폰에서 확인하고 통화를 시작하세요."))
        }.onFailure {
            sendEvent(this, JSONObject().put("kind", "phone_action_result").put("text", "전화 걸기 알림을 표시하지 못했습니다. Android 알림 권한을 확인하세요."))
        }
    }

    private fun normalizePhoneNumber(raw: String): String? {
        val value = raw.trim()
        val digits = value.count(Char::isDigit)
        if (digits !in 3..20 || value.any { !it.isDigit() && it !in "+ ()-" }) return null
        return value.filter { it.isDigit() || it == '+' }
    }

    private fun transferStorageDirectory(): File = File(filesDir, "phonebridge-transfer-parts").apply { mkdirs() }

    private fun transferStorageFiles(id: String): Pair<File, File> {
        val safeKey = MessageDigest.getInstance("SHA-256").digest(id.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        val directory = transferStorageDirectory()
        return File(directory, "$safeKey.part") to File(directory, "$safeKey.json")
    }

    private fun hasIncomingTransferManifest(id: String): Boolean = id.isNotBlank() && transferStorageFiles(id).second.isFile

    private fun readIncomingTransferManifest(id: String): ResumableIncomingTransfer? = runCatching {
        val (partFile, manifestFile) = transferStorageFiles(id)
        val metadata = JSONObject(manifestFile.readText())
        require(metadata.optString("id") == id)
        ResumableIncomingTransfer(
            id = id,
            name = metadata.optString("name"),
            contentType = metadata.optString("contentType", "application/octet-stream"),
            size = metadata.optLong("size", -1),
            count = metadata.optInt("count", -1),
            partFile = partFile,
            manifestFile = manifestFile,
            nextIndex = metadata.optInt("nextIndex", 0),
            completedFileName = metadata.optString("completedFileName").takeIf { it.isNotBlank() },
        ).also { transfer ->
            require(transfer.size in 0..(100L * 1024 * 1024) && transfer.count in 1..5000)
            if (transfer.completedFileName == null) require(partFile.isFile)
        }
    }.getOrNull()

    private fun saveIncomingTransferManifest(transfer: ResumableIncomingTransfer) {
        val temporary = File(transfer.manifestFile.parentFile, "${transfer.manifestFile.name}.tmp")
        val value = JSONObject()
            .put("id", transfer.id)
            .put("name", transfer.name)
            .put("contentType", transfer.contentType)
            .put("size", transfer.size)
            .put("count", transfer.count)
            .put("nextIndex", transfer.nextIndex)
            .put("completedFileName", transfer.completedFileName ?: "")
        temporary.writeText(value.toString())
        if (!temporary.renameTo(transfer.manifestFile)) {
            transfer.manifestFile.writeText(value.toString())
            temporary.delete()
        }
    }

    private fun beginIncomingFileTransfer(command: JSONObject) {
        val id = command.optString("eventId")
        val name = File(command.optString("title", "PhoneBridge-file")).name.ifBlank { "PhoneBridge-file" }
        val contentType = command.optString("source", "application/octet-stream")
        val size = command.optLong("size", -1)
        val count = command.optInt("transferCount", -1)
        val chunkSize = command.optInt("chunkSize", 24 * 1024)
        val expectedCount = maxOf(1, ((size.coerceAtLeast(0) + chunkSize - 1) / chunkSize).toInt())
        if (id.isBlank() || size !in 0..(100L * 1024 * 1024) || chunkSize != 24 * 1024 || count != expectedCount || count !in 1..5000) {
            sendEvent(this, JSONObject().put("kind", "file_transfer_ready").put("eventId", id).put("success", false).put("text", "파일 정보가 올바르지 않습니다."))
            return
        }
        val (partFile, manifestFile) = transferStorageFiles(id)
        val old = readIncomingTransferManifest(id)
        val transfer = if (old != null && old.name == name && old.contentType == contentType && old.size == size && old.count == count) {
            old
        } else {
            old?.partFile?.delete()
            old?.manifestFile?.delete()
            runCatching {
                RandomAccessFile(partFile, "rw").use { it.setLength(size) }
                ResumableIncomingTransfer(id, name, contentType, size, count, partFile, manifestFile, 0).also(::saveIncomingTransferManifest)
            }.getOrElse {
                sendEvent(this, JSONObject().put("kind", "file_transfer_ready").put("eventId", id).put("success", false).put("text", "전송 공간을 준비하지 못했습니다. 저장 공간을 확인하세요."))
                PhoneBridgeDiagnostics.record("전송", "받는 파일의 임시 저장 공간을 준비하지 못했습니다.")
                return
            }
        }
        synchronized(resumableIncomingTransfers) { resumableIncomingTransfers[id] = transfer }
        if (transfer.completedFileName == null && transfer.nextIndex >= transfer.count) {
            transfer.nextIndex = maxOf(0, transfer.count - 1)
            saveIncomingTransferManifest(transfer)
        }
        if (transfer.completedFileName != null) {
            val directory = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir
            val completed = File(directory, transfer.completedFileName!!)
            if (completed.isFile) {
                sendEvent(this, JSONObject().put("kind", "file_transfer_ready").put("eventId", id).put("success", true).put("nextIndex", count).put("size", size))
                sendEvent(this, JSONObject().put("kind", "file_received").put("eventId", id).put("title", completed.name).put("success", true).put("size", completed.length()))
                return
            }
            transfer.completedFileName = null
            transfer.nextIndex = 0
            RandomAccessFile(partFile, "rw").use { it.setLength(size) }
            saveIncomingTransferManifest(transfer)
        }
        val receivedBytes = minOf(size, transfer.nextIndex.toLong() * chunkSize)
        ConnectionState.updateTransfer(TransferProgress(id, name, "Mac → 휴대폰", size, receivedBytes, "전송 중", "이어받기 준비 완료"))
        PhoneBridgeDiagnostics.record("전송", if (transfer.nextIndex > 0) "중단된 파일 전송을 이어받을 준비가 되었습니다." else "Mac에서 파일 받기를 시작했습니다.")
        sendEvent(this, JSONObject().put("kind", "file_transfer_ready").put("eventId", id).put("success", true).put("nextIndex", transfer.nextIndex).put("size", receivedBytes))
    }

    private fun receiveResumableFileChunk(chunk: JSONObject) {
        val id = chunk.optString("eventId")
        val transfer = synchronized(resumableIncomingTransfers) { resumableIncomingTransfers[id] }
            ?: readIncomingTransferManifest(id)?.also { synchronized(resumableIncomingTransfers) { resumableIncomingTransfers[id] = it } }
            ?: return
        val index = chunk.optInt("transferIndex", -1)
        val count = chunk.optInt("transferCount", -1)
        val bytes = runCatching { Base64.decode(chunk.getString("payload"), Base64.DEFAULT) }.getOrNull() ?: return
        if (count != transfer.count || index !in 0 until transfer.count || bytes.size > 24 * 1024) return
        synchronized(resumableIncomingTransfers) {
            if (transfer.completedFileName != null) {
                sendEvent(this, JSONObject().put("kind", "file_chunk_ack").put("eventId", id).put("transferIndex", index).put("nextIndex", transfer.count).put("size", transfer.size))
                return
            }
            if (index != transfer.nextIndex) {
                val currentBytes = minOf(transfer.size, transfer.nextIndex.toLong() * 24 * 1024)
                sendEvent(this, JSONObject().put("kind", "file_chunk_ack").put("eventId", id).put("transferIndex", index).put("nextIndex", transfer.nextIndex).put("size", currentBytes))
                return
            }
            val expectedBytes = minOf(24L * 1024, transfer.size - index.toLong() * 24 * 1024).toInt()
            if (bytes.size != expectedBytes) {
                sendEvent(this, JSONObject().put("kind", "file_chunk_ack").put("eventId", id).put("success", false).put("text", "파일 조각의 크기가 올바르지 않습니다."))
                return
            }
            runCatching {
                RandomAccessFile(transfer.partFile, "rw").use { file ->
                    file.seek(index.toLong() * 24 * 1024)
                    file.write(bytes)
                }
                transfer.nextIndex += 1
                transfer.lastActivityAt = SystemClock.elapsedRealtime()
                saveIncomingTransferManifest(transfer)
            }.onFailure {
                sendEvent(this, JSONObject().put("kind", "file_chunk_ack").put("eventId", id).put("success", false).put("text", "파일을 저장할 수 없습니다. 저장 공간을 확인하세요."))
                PhoneBridgeDiagnostics.record("전송", "받는 파일을 저장하지 못했습니다.")
                return
            }
            val receivedBytes = minOf(transfer.size, transfer.nextIndex.toLong() * 24 * 1024)
            ConnectionState.updateTransfer(TransferProgress(id, transfer.name, "Mac → 휴대폰", transfer.size, receivedBytes, "전송 중", "파일 조각을 저장했습니다."))
            sendEvent(this, JSONObject().put("kind", "file_chunk_ack").put("eventId", id).put("transferIndex", index).put("nextIndex", transfer.nextIndex).put("size", receivedBytes))
            if (transfer.nextIndex < transfer.count) return
            val directory = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir
            directory.mkdirs()
            val safeName = File(transfer.name).name.ifBlank { "PhoneBridge-file" }
            val transferKey = transferStorageFiles(id).first.name.removeSuffix(".part")
            val finalFile = File(directory, "PhoneBridge-$transferKey-$safeName")
            val staging = File(directory, "phonebridge-${java.util.UUID.randomUUID()}.part")
            runCatching {
                transfer.partFile.copyTo(staging, overwrite = true)
                finalFile.delete()
                check(staging.renameTo(finalFile)) { "파일을 저장 위치로 옮기지 못했습니다." }
                transfer.completedFileName = finalFile.name
                saveIncomingTransferManifest(transfer)
                transfer.partFile.delete()
                val received = ReceivedFileItem(finalFile.name, finalFile.absolutePath, transfer.contentType, finalFile.length())
                ConnectionState.receivedFiles.value = listOf(received) + ConnectionState.receivedFiles.value.filterNot { it.path == received.path }
                ConnectionState.updateTransfer(TransferProgress(id, transfer.name, "Mac → 휴대폰", transfer.size, transfer.size, "완료", "휴대폰에 안전하게 저장했습니다."))
                PhoneBridgeDiagnostics.record("전송", "Mac에서 받은 파일을 저장했습니다.")
                sendEvent(this, JSONObject().put("kind", "file_received").put("eventId", id).put("title", finalFile.name).put("success", true).put("size", finalFile.length()))
            }.onFailure {
                staging.delete()
                finalFile.delete()
                transfer.nextIndex = maxOf(0, transfer.count - 1)
                saveIncomingTransferManifest(transfer)
                sendEvent(this, JSONObject().put("kind", "file_received").put("eventId", id).put("success", false).put("text", "파일을 저장하지 못했습니다. 저장 공간을 확인하세요."))
                PhoneBridgeDiagnostics.record("전송", "받는 파일을 저장하지 못했습니다.")
            }
        }
    }

    private fun cancelIncomingFileTransfer(id: String, notifyPeer: Boolean = true) {
        if (id.isBlank()) return
        val existing = synchronized(resumableIncomingTransfers) { resumableIncomingTransfers[id] }
            ?: readIncomingTransferManifest(id)
        if (existing?.completedFileName != null) {
            val directory = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir
            val completed = File(directory, existing.completedFileName!!)
            if (completed.isFile) {
                if (notifyPeer) sendEvent(this, JSONObject().put("kind", "file_received").put("eventId", id)
                    .put("title", completed.name).put("success", true).put("size", completed.length()))
                return
            }
        }
        synchronized(resumableIncomingTransfers) {
            val transfer = resumableIncomingTransfers.remove(id) ?: existing
            if (transfer != null && transfer.completedFileName == null) {
                transfer.partFile.delete()
                transfer.manifestFile.delete()
            }
        }
        ConnectionState.transfers.value.firstOrNull { it.id == id }?.let { transfer ->
            ConnectionState.updateTransfer(transfer.copy(status = "취소됨", detail = "전송을 취소했습니다."))
        }
        if (notifyPeer) sendEvent(this, JSONObject().put("kind", "file_cancelled").put("eventId", id).put("success", true))
        PhoneBridgeDiagnostics.record("전송", "받는 파일 전송이 취소되었습니다.")
    }

    private fun cleanStaleIncomingTransfers() {
        val directory = transferStorageDirectory()
        val cutoff = System.currentTimeMillis() - TimeUnit.DAYS.toMillis(7)
        directory.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { file ->
            val id = runCatching { JSONObject(file.readText()).optString("id") }.getOrNull()
            if (file.extension == "json" && !id.isNullOrBlank()) transferStorageFiles(id).first.delete()
            file.delete()
        }
    }

    private fun receiveFileChunk(chunk: JSONObject) {
        synchronized(incomingTransfers) {
            val transferId = chunk.optString("eventId")
            val index = chunk.optInt("transferIndex", -1)
            val count = chunk.optInt("transferCount", -1)
            if (transferId.isBlank() || count !in 1..5000 || index !in 0 until count) return
            val data = runCatching { Base64.decode(chunk.getString("payload"), Base64.DEFAULT) }.getOrNull() ?: return
            val now = SystemClock.elapsedRealtime()
            incomingTransfers.entries.removeAll { now - it.value.lastActivityAt > TimeUnit.MINUTES.toMillis(3) }
            if (data.size > 24 * 1024 || (transferId !in incomingTransfers && incomingTransfers.size >= 4)) return
            val transfer = incomingTransfers.getOrPut(transferId) {
                IncomingTransfer(chunk.optString("title", "PhoneBridge-file"), chunk.optString("source", "application/octet-stream"), count)
            }
            if (transfer.count != count) {
                incomingTransfers.remove(transferId)
                return
            }
            transfer.lastActivityAt = now
            val previousChunk = transfer.chunks.put(index, data)
            transfer.receivedBytes += data.size - (previousChunk?.size ?: 0)
            val transferBytes = transfer.receivedBytes
            val totalPendingBytes = incomingTransfers.filterKeys { it != transferId }
                .values.sumOf { pending -> pending.receivedBytes } + transferBytes
            if (transferBytes > 100 * 1024 * 1024 || totalPendingBytes > 128 * 1024 * 1024) {
                incomingTransfers.remove(transferId)
                sendEvent(this, JSONObject().put("kind", "file_received").put("eventId", transferId)
                    .put("success", false).put("text", "전송 용량 제한을 초과했습니다."))
                return
            }
            if (transfer.chunks.size != count) return
            val directory = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir
            directory.mkdirs()
            val safeName = File(transfer.name).name.ifBlank { "PhoneBridge-file" }
            val outputFile = File(directory, "${System.currentTimeMillis()}-${java.util.UUID.randomUUID()}-$safeName")
            val temporaryFile = runCatching { File.createTempFile("phonebridge-", ".part", directory) }.getOrNull()
            if (temporaryFile == null) {
                incomingTransfers.remove(transferId)
                sendEvent(this, JSONObject().put("kind", "file_received").put("eventId", transferId)
                    .put("success", false).put("text", "임시 파일을 만들지 못했습니다."))
                return
            }
            runCatching {
                temporaryFile.outputStream().buffered().use { output ->
                    for (part in 0 until count) output.write(transfer.chunks[part] ?: error("파일 조각이 누락되었습니다."))
                }
                check(temporaryFile.renameTo(outputFile)) { "파일을 저장 위치로 옮기지 못했습니다." }
                val received = ReceivedFileItem(outputFile.name, outputFile.absolutePath, transfer.contentType, outputFile.length())
                ConnectionState.receivedFiles.value = listOf(received) + ConnectionState.receivedFiles.value.filterNot { it.path == received.path }
                sendEvent(this, JSONObject().put("kind", "file_received").put("eventId", transferId)
                    .put("title", outputFile.name).put("success", true).put("size", outputFile.length()))
            }.onFailure {
                temporaryFile.delete()
                outputFile.delete()
                sendEvent(this, JSONObject().put("kind", "file_received").put("eventId", transferId)
                    .put("success", false).put("text", "파일을 저장하지 못했습니다: ${it.localizedMessage ?: "저장 공간이나 접근 권한을 확인하세요."}"))
            }
            incomingTransfers.remove(transferId)
        }
    }

    private fun startDiscovery(secret: ByteArray) {
        synchronized(discoveryLock) {
            if (discoveryListener != null) return
        }
        val manager = getSystemService(NSD_SERVICE) as NsdManager
        nsdManager = manager
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) = Unit
            override fun onServiceFound(service: NsdServiceInfo) {
                if (service.serviceType.trimEnd('.') != SERVICE_TYPE.trimEnd('.')) return
                if (service.serviceName.startsWith("PhoneBridge-Mac") && !resolvingService) {
                    resolvingService = true
                    @Suppress("DEPRECATION")
                    manager.resolveService(service, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                            resolvingService = false
                            stopDiscovery()
                            scheduleDiscovery()
                        }
                        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                            resolvingService = false
                            val address: InetAddress? = serviceInfo.host
                            if (address != null) {
                                stopDiscovery()
                                executor.execute { connect(address.hostAddress ?: return@execute, serviceInfo.port, secret) }
                            } else {
                                stopDiscovery()
                                scheduleDiscovery()
                            }
                        }
                    })
                }
            }
            override fun onServiceLost(service: NsdServiceInfo) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                stopDiscovery()
                scheduleDiscovery()
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                stopDiscovery()
            }
        }
        synchronized(discoveryLock) {
            if (discoveryListener != null) return
            discoveryListener = listener
        }
        runCatching { manager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure {
                synchronized(discoveryLock) {
                    if (discoveryListener === listener) discoveryListener = null
                }
                scheduleDiscovery()
            }
    }

    private fun scheduleDiscovery() {
        synchronized(retryLock) {
            if (retryScheduled) return
            retryScheduled = true
            val delay = (1_000L shl retryAttempt.coerceAtMost(5)).coerceAtMost(30_000L)
            retryAttempt = (retryAttempt + 1).coerceAtMost(5)
            retryHandler.postDelayed({
                synchronized(retryLock) { retryScheduled = false }
                val pairing = PairingStore.load(this) ?: return@postDelayed
                if (!isConnected()) startDiscovery(pairing.secret)
            }, delay)
        }
    }

    /** A navigation tap probes the existing socket; an unresponsive peer is dropped and rediscovered. */
    private fun checkConnectionHealth() {
        val session = activeSession ?: return
        if (!session.heartbeatSupported) return
        val sequenceAtPing = serverMessageSequence
        sendEvent(this, JSONObject().put("kind", "heartbeat_ping").put("timestamp", System.currentTimeMillis() / 1000.0))
        retryHandler.postDelayed({
            if (activeSession === session && serverMessageSequence == sequenceAtPing) {
                handleConnectionLoss(session.socket, "Mac 응답이 없어 다시 연결하는 중…")
            }
        }, CONNECTION_PROBE_TIMEOUT_MS)
    }

    private fun stopDiscovery() {
        val listener = synchronized(discoveryLock) {
            val current = discoveryListener
            discoveryListener = null
            resolvingService = false
            current
        } ?: return
        runCatching { nsdManager?.stopServiceDiscovery(listener) }
    }

    private fun stopLink() {
        synchronized(retryLock) {
            retryHandler.removeCallbacksAndMessages(null)
            retryScheduled = false
            retryAttempt = 0
        }
        stopDiscovery()
        stopScreenMirror(notifyMac = false)
        clearSocket()
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    private fun clearSocket(expectedSocket: Socket? = null) {
        synchronized(connectionLock) {
            val session = activeSession
            if (expectedSocket != null && session?.socket !== expectedSocket) return
            heartbeatFuture?.cancel(false)
            heartbeatFuture = null
            session?.let { runCatching { it.socket.close() } }
            activeSession = null
            synchronized(incomingTransfers) { incomingTransfers.clear() }
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(CHANNEL_ID, "PhoneBridge 연결", NotificationManager.IMPORTANCE_LOW)
            val phoneActions = NotificationChannel(PHONE_ACTION_CHANNEL_ID, "Mac에서 보낸 작업", NotificationManager.IMPORTANCE_DEFAULT)
            getSystemService(NotificationManager::class.java).createNotificationChannels(listOf(channel, phoneActions))
        }
    }

    private fun connectionNotification(): Notification = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
        .setContentTitle("PhoneBridge 연결 활성화")
        .setContentText("로컬 Wi‑Fi에서 Mac 연결을 유지합니다")
        .setOngoing(true)
        .setCategory(Notification.CATEGORY_SERVICE)
        .build()

    private fun registerBatteryUpdates() {
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val level = intent?.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1) ?: return
                val scale = intent.getIntExtra(android.os.BatteryManager.EXTRA_SCALE, 100).coerceAtLeast(1)
                sendEvent(this@LinkService, JSONObject().put("kind", "battery").put("battery", level * 100 / scale).put("timestamp", System.currentTimeMillis() / 1000.0))
            }
        }
        batteryReceiver = receiver
        registerReceiver(receiver, android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    }

    private fun sendBatterySnapshot() {
        val intent = registerReceiver(null, android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return
        val level = intent.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(android.os.BatteryManager.EXTRA_SCALE, 100).coerceAtLeast(1)
        if (level >= 0) sendEvent(this, JSONObject().put("kind", "battery").put("battery", level * 100 / scale).put("timestamp", System.currentTimeMillis() / 1000.0))
    }

    private fun registerCallState() {
        if (callCallback != null || legacyCallListener != null) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) return
        if (Build.VERSION.SDK_INT >= 31) {
            val manager = getSystemService(TELEPHONY_SERVICE) as TelephonyManager
            val callback = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                override fun onCallStateChanged(state: Int) {
                    val value = when (state) {
                        TelephonyManager.CALL_STATE_RINGING -> "ringing"
                        TelephonyManager.CALL_STATE_OFFHOOK -> "offhook"
                        else -> "idle"
                    }
                    sendEvent(this@LinkService, JSONObject().put("kind", "call_state").put("callState", value).put("timestamp", System.currentTimeMillis() / 1000.0))
                }
            }
            callCallback = callback
            runCatching { manager.registerTelephonyCallback(mainExecutor, callback) }
        } else {
            @Suppress("DEPRECATION")
            val manager = getSystemService(TELEPHONY_SERVICE) as TelephonyManager
            @Suppress("DEPRECATION")
            val listener = object : PhoneStateListener() {
                override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                    val value = when (state) {
                        TelephonyManager.CALL_STATE_RINGING -> "ringing"
                        TelephonyManager.CALL_STATE_OFFHOOK -> "offhook"
                        else -> "idle"
                    }
                    sendEvent(this@LinkService, JSONObject().put("kind", "call_state").put("callState", value).put("timestamp", System.currentTimeMillis() / 1000.0))
                }
            }
            legacyCallListener = listener
            @Suppress("DEPRECATION")
            runCatching { manager.listen(listener, PhoneStateListener.LISTEN_CALL_STATE) }
        }
    }
}
