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
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import org.json.JSONObject
import com.example.phonebridge.android.update.PhoneBridgeUpdateManager
import com.example.phonebridge.android.update.PhoneBridgeUpdateState
import com.example.phonebridge.android.update.PhoneBridgeUpdatePreferences
import com.example.phonebridge.android.update.PhoneBridgeUpdateScheduler
import com.example.phonebridge.android.update.PhoneBridgeUpdateWorker

class MainActivity : ComponentActivity() {
    private var pairedName by mutableStateOf<String?>(null)
    private var galleryAccessGranted by mutableStateOf(false)
    private var remoteControlEnabled by mutableStateOf(false)
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
        if (granted && PairingStore.load(this) != null) startLink()
    }
    private val galleryPermission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        galleryAccessGranted = PhoneGalleryBridge.hasAccess(this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pairedName = PairingStore.load(this)?.let { Build.MODEL ?: "Android 휴대폰" }
        galleryAccessGranted = PhoneGalleryBridge.hasAccess(this)
        remoteControlEnabled = PhoneRemoteControlService.isRunning()
        ConnectionState.receivedFiles.value = listReceivedFiles()
        setContent {
            val linkStatus by ConnectionState.status.collectAsState()
            val receivedFiles by ConnectionState.receivedFiles.collectAsState()
            val screenShareStatus by ConnectionState.screenShareStatus.collectAsState()
            val updateState by updateManager.state.collectAsState()
            PhoneBridgeTheme {
                PhoneBridgeBackdrop {
                    Column(
                        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 24.dp),
                        verticalArrangement = Arrangement.spacedBy(17.dp)
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Image(
                                painter = painterResource(com.example.phonebridge.android.R.drawable.phonebridge_mark),
                                contentDescription = "PhoneBridge 아이콘",
                                modifier = Modifier.size(48.dp),
                            )
                            Column {
                                Text("PhoneBridge", fontSize = 22.sp, fontWeight = FontWeight.Bold)
                                Text("내 휴대폰과 Mac을 자연스럽게 연결", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                            }
                        }

                        PhoneBridgeGlassPanel(Modifier.fillMaxWidth()) {
                            Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(15.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text("기기 연결", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Spacer(Modifier.weight(1f))
                                    val connected = linkStatus.startsWith("Mac에 연결됨")
                                    Surface(
                                        color = (if (connected) Color(0xFF21A675) else Color(0xFFDC9A36)).copy(alpha = 0.14f),
                                        shape = CircleShape,
                                    ) {
                                        Row(Modifier.padding(horizontal = 11.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                                            Surface(color = if (connected) Color(0xFF21A675) else Color(0xFFDC9A36), shape = CircleShape, modifier = Modifier.size(7.dp)) { }
                                            Text(if (connected) "연결됨" else "연결 대기", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
                                        }
                                    }
                                }
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                                    Surface(
                                        color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
                                        shape = RoundedCornerShape(22.dp),
                                        modifier = Modifier.size(68.dp),
                                    ) {
                                        Box(contentAlignment = Alignment.Center) {
                                            Text("▯", fontSize = 37.sp, color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Light)
                                        }
                                    }
                                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                        Text(pairedName ?: "휴대폰을 연결하세요", fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                                        Text(if (PairingStore.load(this@MainActivity) != null) linkStatus else "QR 코드를 스캔해 안전하게 페어링", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                                    }
                                }
                                if (PairingStore.load(this@MainActivity) == null) {
                                    Button(
                                        onClick = ::launchScanner,
                                        modifier = Modifier.fillMaxWidth().height(54.dp),
                                        shape = RoundedCornerShape(18.dp),
                                        colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
                                    ) { Text("Mac QR 코드 스캔", fontWeight = FontWeight.SemiBold) }
                                } else {
                                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                        Button(
                                            onClick = ::startLink,
                                            modifier = Modifier.weight(1f).height(52.dp),
                                            shape = RoundedCornerShape(17.dp),
                                            colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
                                        ) { Text("Mac에 연결", fontWeight = FontWeight.SemiBold) }
                                        OutlinedButton(
                                            onClick = ::unpair,
                                            modifier = Modifier.weight(1f).height(52.dp),
                                            shape = RoundedCornerShape(17.dp),
                                        ) { Text("연결 해제") }
                                    }
                                }
                            }
                        }

                        PhoneBridgeSurface(Modifier.fillMaxWidth()) {
                            Column(Modifier.fillMaxWidth().padding(horizontal = 17.dp, vertical = 15.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text("앱 업데이트", fontWeight = FontWeight.SemiBold)
                                    Spacer(Modifier.weight(1f))
                                    Text("v${BuildConfig.VERSION_NAME}", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
                                }
                                Text(updateState.description(), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                                if (updateState is PhoneBridgeUpdateState.Downloading) {
                                    val progress = (updateState as PhoneBridgeUpdateState.Downloading).progress
                                    if (progress != null) Text("다운로드 $progress%", color = MaterialTheme.colorScheme.primary, fontSize = 12.sp)
                                }
                                TextButton(
                                    onClick = {
                                        when (val state = updateState) {
                                            is PhoneBridgeUpdateState.Available -> updateManager.download(state.release)
                                            is PhoneBridgeUpdateState.Ready -> updateManager.install(state.release, state.apk)
                                            is PhoneBridgeUpdateState.InstallPermissionRequired -> updateManager.openInstallPermissionSettings()
                                            else -> updateManager.checkForUpdates(force = true)
                                        }
                                    },
                                    enabled = updateState !is PhoneBridgeUpdateState.Checking && updateState !is PhoneBridgeUpdateState.Downloading && updateState !is PhoneBridgeUpdateState.AwaitingSystemConfirmation,
                                    modifier = Modifier.align(Alignment.End),
                                ) {
                                    Text(
                                        when (updateState) {
                                            is PhoneBridgeUpdateState.Available -> "업데이트 다운로드"
                                            is PhoneBridgeUpdateState.Ready -> "시스템에서 설치"
                                            is PhoneBridgeUpdateState.InstallPermissionRequired -> "설치 권한 설정"
                                            is PhoneBridgeUpdateState.AwaitingSystemConfirmation -> "시스템 확인 대기 중"
                                            is PhoneBridgeUpdateState.Checking -> "확인 중…"
                                            is PhoneBridgeUpdateState.Downloading -> "다운로드 중…"
                                            is PhoneBridgeUpdateState.Installed -> "업데이트 확인"
                                            is PhoneBridgeUpdateState.UpToDate -> "업데이트 확인"
                                            is PhoneBridgeUpdateState.Failed -> "다시 확인"
                                            PhoneBridgeUpdateState.Idle -> "업데이트 확인"
                                        }
                                    )
                                }
                            }
                        }

                        SectionHeading("함께 사용할 기능", "필요한 권한만 선택해 켜세요")
                        PermissionCard(
                            title = "알림",
                            detail = if (hasNotificationAccess()) "허용됨 · 휴대폰 알림을 Mac으로 전달할 수 있습니다" else "원하는 앱 알림을 Mac으로 전달하도록 접근을 허용하세요",
                            button = if (hasNotificationAccess()) "접근 설정 관리" else "알림 접근 허용",
                            onClick = { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }
                        )
                        PermissionCard(
                            title = "통화 상태",
                            detail = if (hasPhonePermission()) "허용됨 · 전화 수신/통화 상태만 전달합니다" else "선택 권한 · 발신자 정보나 통화 음성은 전달하지 않습니다",
                            button = if (hasPhonePermission()) "권한 허용됨" else "통화 상태 허용",
                            onClick = {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) callPermission.launch(Manifest.permission.READ_PHONE_STATE)
                            }
                        )
                        PermissionCard(
                            title = "사진 라이브러리",
                            detail = if (galleryAccessGranted) "허용됨 · 사용자가 허용한 범위의 사진만 Mac 갤러리에 표시합니다" else "Mac에서 사진을 둘러볼 때 사용합니다. Android 14 이상에서는 선택한 사진만 허용할 수 있습니다",
                            button = if (galleryAccessGranted) "사진 접근 범위 변경" else "사진 접근 허용",
                            onClick = ::requestGalleryPermission,
                        )
                        PermissionCard(
                            title = "Mac에서 화면 조작",
                            detail = if (remoteControlEnabled) "허용됨 · 화면 공유 중 탭/스와이프만 전달하며 화면의 글자나 접근성 트리는 읽지 않습니다" else "선택 권한 · 화면 공유와 별도로 Android 접근성 설정에서 직접 켜야 합니다",
                            button = if (remoteControlEnabled) "접근성 설정 관리" else "원격 터치 설정",
                            onClick = { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) },
                        )

                        SectionHeading("사진과 파일", "필요한 항목만 골라 기기 간 전송")
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            OutlinedButton(onClick = { photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }, modifier = Modifier.weight(1f).height(50.dp), shape = RoundedCornerShape(16.dp)) { Text("사진 선택") }
                            OutlinedButton(onClick = { filePicker.launch(arrayOf("*/*")) }, modifier = Modifier.weight(1f).height(50.dp), shape = RoundedCornerShape(16.dp)) { Text("파일 선택") }
                        }
                        Text("선택한 항목은 Mac으로 전송됩니다. Mac에서 보낸 파일은 이 앱의 다운로드 보관함에 저장됩니다.", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)

                        SectionHeading("클립보드", "직접 누를 때만 텍스트를 전송합니다")
                        OutlinedButton(
                            onClick = ::sendClipboardToMac,
                            enabled = LinkService.isConnected(),
                            modifier = Modifier.fillMaxWidth().height(52.dp),
                            shape = RoundedCornerShape(17.dp),
                        ) { Text("휴대폰 클립보드를 Mac으로 보내기") }

                        if (receivedFiles.isNotEmpty()) {
                            SectionHeading("Mac에서 받은 항목", "이 기기에 저장된 파일")
                            receivedFiles.forEach { item ->
                                PhoneBridgeSurface(Modifier.fillMaxWidth()) {
                                    Row(Modifier.fillMaxWidth().padding(15.dp), verticalAlignment = Alignment.CenterVertically) {
                                        Column(Modifier.weight(1f)) {
                                            Text(item.name, fontWeight = FontWeight.Medium, maxLines = 1)
                                            Text(android.text.format.Formatter.formatFileSize(this@MainActivity, item.size), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
                                        }
                                        TextButton(onClick = { openReceivedFile(item) }) { Text("열기") }
                                    }
                                }
                            }
                        }
                        SectionHeading("폰 화면", "공유를 시작하면 Mac에서 미리 볼 수 있습니다")
                        Text("화면을 Mac에 공유하려면 시스템 화면 캡처 확인을 승인하세요. 공유 중에는 Android 상태 표시줄에서 언제든 중지할 수 있습니다.", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                        OutlinedButton(
                            onClick = { if (screenShareStatus == "화면 공유 중") stopScreenMirror() else requestScreenMirror() },
                            enabled = LinkService.isConnected(),
                            modifier = Modifier.fillMaxWidth().height(52.dp),
                            shape = RoundedCornerShape(17.dp),
                        ) {
                            Text(if (screenShareStatus == "화면 공유 중") "화면 공유 중지" else "화면 공유 시작")
                        }
                        Text(screenShareStatus, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                        Text("연결은 로컬 Wi‑Fi에서 유지됩니다. 연결 중에는 Android에 PhoneBridge 지속 알림이 표시됩니다.", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                    }
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
        return directory.listFiles()?.filter { it.isFile }?.sortedByDescending { it.lastModified() }?.map { file ->
            ReceivedFileItem(file.name, file.absolutePath, java.net.URLConnection.guessContentTypeFromName(file.name) ?: "application/octet-stream", file.length())
        }.orEmpty()
    }

    private fun openReceivedFile(item: ReceivedFileItem) {
        val file = java.io.File(item.path)
        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
        val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, item.contentType).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(this, "이 파일을 열 수 있는 앱이 없습니다.", Toast.LENGTH_SHORT).show()
        }
    }

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
