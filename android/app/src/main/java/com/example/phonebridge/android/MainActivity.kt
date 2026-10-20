package com.example.phonebridge.android

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipboardManager
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.net.Uri
import android.provider.OpenableColumns
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.contract.ActivityResultContracts.PickMultipleVisualMedia
import androidx.activity.result.PickVisualMediaRequest
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.Image
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.phonebridge.android.link.ConnectionState
import com.example.phonebridge.android.link.LinkService
import com.example.phonebridge.android.link.PairingStore
import com.example.phonebridge.android.link.PairingPayload
import com.example.phonebridge.android.link.ReceivedFileItem
import com.example.phonebridge.android.link.PhoneGalleryBridge
import com.example.phonebridge.android.remote.PhoneRemoteControlService
import androidx.core.content.FileProvider
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import org.json.JSONObject
import com.example.phonebridge.android.update.PhoneBridgeUpdateManager
import com.example.phonebridge.android.update.PhoneBridgeUpdateState
import com.example.phonebridge.android.update.PhoneBridgeUpdatePreferences
import com.example.phonebridge.android.update.PhoneBridgeUpdateScheduler
import com.example.phonebridge.android.update.PhoneBridgeUpdateWorker

class MainActivity : ComponentActivity() {
    private var hasResumedOnce = false
    private var pairedName by mutableStateOf<String?>(null)
    private var systemBarPadding by mutableStateOf(PaddingValues(0.dp))
    private var galleryAccessGranted by mutableStateOf(false)
    private var remoteControlEnabled by mutableStateOf(false)
    private var notificationAccessGranted by mutableStateOf(false)
    private var phonePermissionGranted by mutableStateOf(false)
    private val updateManager by lazy { PhoneBridgeUpdateManager(this) }
    private val transferExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val updateCheckHandler = Handler(Looper.getMainLooper())
    private val foregroundUpdateCheck = object : Runnable {
        override fun run() {
            if (isFinishing || isDestroyed) return
            getSharedPreferences(PhoneBridgeUpdatePreferences.PREFERENCES, MODE_PRIVATE)
                .edit()
                .putLong(PhoneBridgeUpdatePreferences.KEY_LAST_FOREGROUND, System.currentTimeMillis())
                .apply()
            updateManager.checkForUpdates(force = false)
            updateCheckHandler.postDelayed(this, FOREGROUND_UPDATE_CHECK_INTERVAL_MS)
        }
    }

    private val filePicker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let(::sendPickedItem)
    }
    private val photoPicker = registerForActivityResult(PickMultipleVisualMedia(10)) { uris ->
        uris.forEach(::sendPickedItem)
    }
    private val screenCapture = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val data = result.data
        if (result.resultCode == Activity.RESULT_OK && data != null) {
            val intent = Intent(this, LinkService::class.java)
                .setAction(LinkService.ACTION_START_SCREEN_MIRROR)
                .putExtra(LinkService.EXTRA_PROJECTION_RESULT_CODE, result.resultCode)
                .putExtra(LinkService.EXTRA_PROJECTION_DATA, data)
            ContextCompat.startForegroundService(this, intent)
        } else {
            ConnectionState.screenShareStatus.value = "화면 공유 권한을 받지 못했습니다"
        }
    }

    private val scanner = registerForActivityResult(ScanContract()) { result ->
        val raw = result.contents ?: return@registerForActivityResult
        runCatching {
            val json = JSONObject(raw)
            val payload = PairingPayload(
                host = json.getString("host"),
                port = json.getInt("port"),
                secret = android.util.Base64.decode(json.getString("secret"), android.util.Base64.DEFAULT)
            )
            require(json.getInt("version") == 1)
            PairingStore.save(this, payload)
            pairedName = android.os.Build.MODEL ?: "Android 휴대폰"
            startLink()
        }.onFailure {
            ConnectionState.status.value = "PhoneBridge 페어링 QR 코드가 아닙니다"
        }
    }

    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }
    private val callPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        phonePermissionGranted = granted
        if (granted && PairingStore.load(this) != null) startLink()
    }
    private val galleryPermission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        galleryAccessGranted = PhoneGalleryBridge.hasAccess(this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val nightMode = resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = nightMode != android.content.res.Configuration.UI_MODE_NIGHT_YES
            isAppearanceLightNavigationBars = nightMode != android.content.res.Configuration.UI_MODE_NIGHT_YES
        }
        ViewCompat.setOnApplyWindowInsetsListener(window.decorView) { _, windowInsets ->
            val bars = windowInsets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            val density = resources.displayMetrics.density
            systemBarPadding = PaddingValues(
                start = (bars.left / density).dp,
                top = (bars.top / density).dp,
                end = (bars.right / density).dp,
                bottom = (bars.bottom / density).dp,
            )
            windowInsets
        }
        ViewCompat.requestApplyInsets(window.decorView)
        pairedName = PairingStore.load(this)?.let { Build.MODEL ?: "Android 휴대폰" }
        galleryAccessGranted = PhoneGalleryBridge.hasAccess(this)
        remoteControlEnabled = PhoneRemoteControlService.isRunning()
        notificationAccessGranted = hasNotificationAccess()
        phonePermissionGranted = hasPhonePermission()
        ConnectionState.receivedFiles.value = listReceivedFiles()
        setContent {
            val linkStatus by ConnectionState.status.collectAsState()
            val receivedFiles by ConnectionState.receivedFiles.collectAsState()
            val screenShareStatus by ConnectionState.screenShareStatus.collectAsState()
            val updateState by updateManager.state.collectAsState()
            PhoneBridgeTheme {
                PhoneBridgeBackdrop {
                    PhoneBridgeApp(
                        pairedName = pairedName,
                        systemBarPadding = systemBarPadding,
                        linkStatus = linkStatus,
                        receivedFiles = receivedFiles,
                        screenShareStatus = screenShareStatus,
                        galleryAccessGranted = galleryAccessGranted,
                        remoteControlEnabled = remoteControlEnabled,
                        updateState = updateState,
                        notificationAccessGranted = notificationAccessGranted,
                        phonePermissionGranted = phonePermissionGranted,
                        onScan = ::launchScanner,
                        onReconnect = ::startLink,
                        onEnsureConnection = ::ensureLink,
                        onPickPhotos = { photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                        onPickFile = { filePicker.launch(arrayOf("*/*")) },
                        onSendClipboard = ::sendClipboardToMac,
                        onOpenReceivedFile = ::openReceivedFile,
                        onShareReceivedFile = ::shareReceivedFile,
                        onDeleteReceivedFile = ::deleteReceivedFile,
                        onStartScreenShare = ::requestScreenMirror,
                        onStopScreenShare = ::stopScreenMirror,
                        onOpenNotificationSettings = { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) },
                        onRequestCallPermission = { callPermission.launch(Manifest.permission.READ_PHONE_STATE) },
                        onRequestGalleryPermission = ::requestGalleryPermission,
                        onOpenAccessibilitySettings = { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) },
                        onUnpair = ::unpair,
                        onUpdateAction = { state ->
                            when (state) {
                                is PhoneBridgeUpdateState.Available -> updateManager.download(state.release)
                                is PhoneBridgeUpdateState.Ready -> updateManager.install(state.release, state.apk)
                                is PhoneBridgeUpdateState.InstallPermissionRequired -> updateManager.openInstallPermissionSettings()
                                else -> updateManager.checkForUpdates(force = true)
                            }
                        },
                    )
                }
            }
        }

        if (PairingStore.load(this) != null) startLink()
        handleSharedIntent(intent)
        PhoneBridgeUpdateScheduler.schedule(applicationContext)
        updateManager.checkForUpdates(force = true)

    }

    override fun onResume() {
        super.onResume()
        if (hasResumedOnce) ensureLink() else hasResumedOnce = true
        updateManager.onResume()
        getSharedPreferences(PhoneBridgeUpdatePreferences.PREFERENCES, MODE_PRIVATE)
            .edit()
            .putLong(PhoneBridgeUpdatePreferences.KEY_LAST_FOREGROUND, System.currentTimeMillis())
            .apply()
        updateManager.checkForUpdates(force = false)
        updateCheckHandler.removeCallbacks(foregroundUpdateCheck)
        updateCheckHandler.postDelayed(foregroundUpdateCheck, FOREGROUND_UPDATE_CHECK_INTERVAL_MS)
        galleryAccessGranted = PhoneGalleryBridge.hasAccess(this)
        remoteControlEnabled = PhoneRemoteControlService.isRunning()
        notificationAccessGranted = hasNotificationAccess()
        phonePermissionGranted = hasPhonePermission()
    }

    override fun onPause() {
        updateCheckHandler.removeCallbacks(foregroundUpdateCheck)
        super.onPause()
    }

    override fun onDestroy() {
        updateCheckHandler.removeCallbacks(foregroundUpdateCheck)
        updateManager.close()
        transferExecutor.shutdown()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleSharedIntent(intent)
        if (intent.getBooleanExtra(PhoneBridgeUpdateWorker.EXTRA_UPDATE_NOTICE, false)) {
            updateManager.checkForUpdates(force = true)
        }
    }

    private fun launchScanner() {
        val options = ScanOptions().apply {
            setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            setPrompt("Mac의 PhoneBridge에 표시된 QR 코드를 스캔하세요")
            setBeepEnabled(false)
            setOrientationLocked(false)
        }
        scanner.launch(options)
    }

    private fun startLink() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        val intent = Intent(this, LinkService::class.java).setAction(LinkService.ACTION_START)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
    }

    /** Keep tab navigation independent from the socket service and restart it if Android reclaimed it. */
    private fun ensureLink() {
        if (PairingStore.load(this) == null) return
        val intent = Intent(this, LinkService::class.java).setAction(LinkService.ACTION_CHECK_CONNECTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
    }

    companion object {
        private const val FOREGROUND_UPDATE_CHECK_INTERVAL_MS = 15 * 60 * 1000L
    }

    private fun requestScreenMirror() {
        if (!LinkService.isConnected()) {
            Toast.makeText(this, "Mac에 연결한 뒤 화면 공유를 시작하세요.", Toast.LENGTH_SHORT).show()
            return
        }
        val manager = getSystemService(MediaProjectionManager::class.java)
        screenCapture.launch(manager.createScreenCaptureIntent())
    }

    private fun requestGalleryPermission() {
        val permissions = when {
            Build.VERSION.SDK_INT >= 34 -> arrayOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
            )
            Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES)
            else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        galleryPermission.launch(permissions)
    }

    private fun stopScreenMirror() {
        startService(Intent(this, LinkService::class.java).setAction(LinkService.ACTION_STOP_SCREEN_MIRROR))
    }

    private fun sendPickedItem(uri: Uri) {
        if (PairingStore.load(this) == null) {
            Toast.makeText(this, "먼저 Mac과 페어링한 다음 공유 메뉴에서 다시 보내세요.", Toast.LENGTH_LONG).show()
            return
        }
        transferExecutor.execute {
            val result = runCatching {
                val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                } ?: "PhoneBridge-file"
                val mime = contentResolver.getType(uri) ?: "application/octet-stream"
                val bytes = contentResolver.openInputStream(uri)?.use { input ->
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(16 * 1024)
                    var total = 0
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        require(total <= 100 * 1024 * 1024) { "파일은 100MB 이하만 전송할 수 있습니다." }
                        output.write(buffer, 0, read)
                    }
                    output.toByteArray()
                } ?: error("파일을 열 수 없습니다.")
                val deadline = System.currentTimeMillis() + 20_000
                while (!LinkService.isConnected() && System.currentTimeMillis() < deadline) Thread.sleep(250)
                check(LinkService.sendFile(this, name, mime, bytes)) { "Mac과 연결되지 않았습니다. 같은 Wi‑Fi에서 다시 시도하세요." }
                name
            }
            runOnUiThread {
                result.onSuccess { name -> Toast.makeText(this, "$name 전송을 시작했습니다.", Toast.LENGTH_SHORT).show() }
                    .onFailure { Toast.makeText(this, it.localizedMessage ?: "파일 전송을 시작하지 못했습니다.", Toast.LENGTH_LONG).show() }
            }
        }
    }

    private fun handleSharedIntent(intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                uri?.let(::sendPickedItem)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
                uris.forEach(::sendPickedItem)
            }
        }
    }

    private fun listReceivedFiles(): List<ReceivedFileItem> {
        val directory = getExternalFilesDir(android.os.Environment.DIRECTORY_DOWNLOADS) ?: filesDir
        val now = System.currentTimeMillis()
        return directory.listFiles()?.onEach { file ->
            val isTemporary = file.name.startsWith("phonebridge-") && file.name.endsWith(".part")
            if (file.isFile && isTemporary && now - file.lastModified() > java.util.concurrent.TimeUnit.DAYS.toMillis(1)) file.delete()
        }?.filter { it.isFile && !(it.name.startsWith("phonebridge-") && it.name.endsWith(".part")) }
            ?.sortedByDescending { it.lastModified() }?.map { file ->
            ReceivedFileItem(file.name, file.absolutePath, java.net.URLConnection.guessContentTypeFromName(file.name) ?: "application/octet-stream", file.length())
        }.orEmpty()
    }

    private fun openReceivedFile(item: ReceivedFileItem) {
        try {
            val file = resolveReceivedFile(item) ?: error("받은 파일을 찾을 수 없습니다.")
            val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
            val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, item.contentType).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(this, "이 파일을 열 수 있는 앱이 없습니다.", Toast.LENGTH_SHORT).show()
        } catch (error: Exception) {
            Toast.makeText(this, error.localizedMessage ?: "파일을 열지 못했습니다.", Toast.LENGTH_LONG).show()
        }
    }

    private fun shareReceivedFile(item: ReceivedFileItem) {
        runCatching {
            val file = resolveReceivedFile(item) ?: error("받은 파일을 찾을 수 없습니다.")
            val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
            val shareIntent = Intent(Intent.ACTION_SEND)
                .setType(item.contentType.ifBlank { "application/octet-stream" })
                .putExtra(Intent.EXTRA_STREAM, uri)
            shareIntent.clipData = android.content.ClipData.newUri(contentResolver, item.name, uri)
            shareIntent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivity(Intent.createChooser(shareIntent, "파일 공유"))
        }.onFailure { error ->
            Toast.makeText(this, error.localizedMessage ?: "파일을 공유하지 못했습니다.", Toast.LENGTH_LONG).show()
        }
    }

    private fun deleteReceivedFile(item: ReceivedFileItem) {
        val file = resolveReceivedFile(item)
        if (file == null || !file.delete()) {
            Toast.makeText(this, "받은 파일을 삭제하지 못했습니다.", Toast.LENGTH_LONG).show()
            ConnectionState.receivedFiles.value = listReceivedFiles()
            return
        }
        ConnectionState.receivedFiles.value = listReceivedFiles()
        Toast.makeText(this, "받은 파일을 삭제했습니다.", Toast.LENGTH_SHORT).show()
    }

    private fun resolveReceivedFile(item: ReceivedFileItem): java.io.File? = runCatching {
        val directory = (getExternalFilesDir(android.os.Environment.DIRECTORY_DOWNLOADS) ?: filesDir).canonicalFile
        val file = java.io.File(item.path).canonicalFile
        file.takeIf { it.isFile && it.parentFile == directory }
    }.getOrNull()

    private fun sendClipboardToMac() {
        val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        val text = clipboard.primaryClip
            ?.takeIf { it.itemCount > 0 }
            ?.getItemAt(0)
            ?.coerceToText(this)
            ?.toString()
        if (text.isNullOrEmpty()) {
            Toast.makeText(this, "클립보드에 보낼 텍스트가 없습니다.", Toast.LENGTH_SHORT).show()
            return
        }
        if (LinkService.sendClipboardText(this, text)) {
            Toast.makeText(this, "클립보드 텍스트를 Mac으로 보냈습니다.", Toast.LENGTH_SHORT).show()
        } else {
            Toast.makeText(this, "연결되지 않았거나 텍스트가 20KB를 넘습니다.", Toast.LENGTH_LONG).show()
        }
    }

    private fun unpair() {
        stopService(Intent(this, LinkService::class.java))
        PairingStore.clear(this)
        pairedName = null
        ConnectionState.status.value = "페어링되지 않음"
    }

    private fun hasPhonePermission(): Boolean = Build.VERSION.SDK_INT < 23 || checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == android.content.pm.PackageManager.PERMISSION_GRANTED

    private fun hasNotificationAccess(): Boolean {
        val enabled = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: return false
        return enabled.contains(packageName)
    }

    @androidx.compose.runtime.Composable
    private fun PermissionCard(title: String, detail: String, button: String, onClick: () -> Unit) {
        PhoneBridgeSurface(Modifier.fillMaxWidth()) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 17.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(title, fontWeight = FontWeight.SemiBold)
                Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                TextButton(onClick = onClick, modifier = Modifier.align(Alignment.End)) { Text(button) }
            }
        }
    }

    @androidx.compose.runtime.Composable
    private fun SectionHeading(title: String, subtitle: String) {
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, fontSize = 19.sp, fontWeight = FontWeight.Bold)
            Text(subtitle, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }

}

private fun PhoneBridgeUpdateState.description(): String = when (this) {
    PhoneBridgeUpdateState.Idle -> "최신 버전을 앱 안에서 확인하고 설치할 수 있습니다."
    PhoneBridgeUpdateState.Checking -> "최신 PhoneBridge 버전을 확인하고 있습니다."
    PhoneBridgeUpdateState.UpToDate -> "현재 최신 버전입니다."
    is PhoneBridgeUpdateState.Available -> "v${release.versionName} 업데이트가 있습니다. 앱에서 내려받고 Android 설치 화면에서 승인하세요. ${release.notes}"
    is PhoneBridgeUpdateState.Downloading -> "v${release.versionName} 업데이트를 안전하게 내려받고 있습니다."
    is PhoneBridgeUpdateState.Ready -> "다운로드 파일과 앱 서명을 확인했습니다. 시스템 설치를 진행할 수 있습니다."
    is PhoneBridgeUpdateState.InstallPermissionRequired -> "이 앱에서 설치하도록 Android 설정에서 한 번 허용한 뒤 돌아오세요."
    is PhoneBridgeUpdateState.AwaitingSystemConfirmation -> "Android 시스템 설치 화면에서 업데이트를 승인하세요."
    PhoneBridgeUpdateState.Installed -> "PhoneBridge 업데이트가 완료되었습니다."
    is PhoneBridgeUpdateState.Failed -> message
}
