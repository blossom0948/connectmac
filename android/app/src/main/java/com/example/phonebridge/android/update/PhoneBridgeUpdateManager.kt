package com.example.phonebridge.android.update

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.core.content.FileProvider
import com.example.phonebridge.android.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.Locale

data class PhoneBridgeRelease(
    val versionName: String,
    val versionCode: Long,
    val apkUrl: String,
    val sha256: String,
    val notes: String,
)

sealed interface PhoneBridgeUpdateState {
    data object Idle : PhoneBridgeUpdateState
    data object Checking : PhoneBridgeUpdateState
    data object UpToDate : PhoneBridgeUpdateState
    data class Available(val release: PhoneBridgeRelease) : PhoneBridgeUpdateState
    data class Downloading(val release: PhoneBridgeRelease, val progress: Int?) : PhoneBridgeUpdateState
    data class Ready(val release: PhoneBridgeRelease, val apk: File) : PhoneBridgeUpdateState
    data class InstallPermissionRequired(val release: PhoneBridgeRelease, val apk: File) : PhoneBridgeUpdateState
    data class AwaitingSystemConfirmation(val release: PhoneBridgeRelease, val apk: File) : PhoneBridgeUpdateState
    data object Installed : PhoneBridgeUpdateState
    data class Failed(val message: String) : PhoneBridgeUpdateState
}

/** Downloads only releases published by the PhoneBridge GitHub repository and verifies the APK before opening Android's installer. */
class PhoneBridgeUpdateManager(private val activity: ComponentActivity) {
    private val context = activity.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutableState = MutableStateFlow<PhoneBridgeUpdateState>(PhoneBridgeUpdateState.Idle)
    val state: StateFlow<PhoneBridgeUpdateState> = mutableState.asStateFlow()

    private var pendingInstall: Pair<PhoneBridgeRelease, File>? = null

    fun checkForUpdates(force: Boolean = true) {
        if (mutableState.value is PhoneBridgeUpdateState.Checking || mutableState.value is PhoneBridgeUpdateState.Downloading) return
        if (!force) {
            val lastCheck = context.getSharedPreferences(PREFERENCES, 0).getLong(KEY_LAST_CHECK, 0L)
            if (System.currentTimeMillis() - lastCheck < CHECK_INTERVAL_MS) return
        }
        mutableState.value = PhoneBridgeUpdateState.Checking
        scope.launch {
            val result = runCatching {
                withContext(Dispatchers.IO) { fetchRelease() }
            }
            context.getSharedPreferences(PREFERENCES, 0).edit().putLong(KEY_LAST_CHECK, System.currentTimeMillis()).apply()
            result.onSuccess { release ->
                mutableState.value = if (release.versionCode > BuildConfig.VERSION_CODE) {
                    PhoneBridgeUpdateState.Available(release)
                } else {
                    PhoneBridgeUpdateState.UpToDate
                }
            }.onFailure {
                mutableState.value = PhoneBridgeUpdateState.Failed(it.message ?: "업데이트 정보를 확인하지 못했습니다.")
            }
        }
    }

    fun download(release: PhoneBridgeRelease) {
        if (mutableState.value is PhoneBridgeUpdateState.Downloading) return
        mutableState.value = PhoneBridgeUpdateState.Downloading(release, null)
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) { downloadAndVerify(release) }
            }.onSuccess { apk ->
                pendingInstall = release to apk
                mutableState.value = PhoneBridgeUpdateState.Ready(release, apk)
            }.onFailure {
                mutableState.value = PhoneBridgeUpdateState.Failed(it.message ?: "업데이트를 내려받지 못했습니다.")
            }
        }
    }

    fun install(release: PhoneBridgeRelease, apk: File) {
        pendingInstall = release to apk
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !context.packageManager.canRequestPackageInstalls()) {
            mutableState.value = PhoneBridgeUpdateState.InstallPermissionRequired(release, apk)
            return
        }
        openSystemInstaller(release, apk)
    }

    fun openInstallPermissionSettings() {
        val current = mutableState.value as? PhoneBridgeUpdateState.InstallPermissionRequired ?: return
        runCatching {
            activity.startActivity(
                Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                    .setData(Uri.parse("package:${context.packageName}"))
            )
        }.onFailure {
            mutableState.value = PhoneBridgeUpdateState.Failed("앱별 알 수 없는 앱 설치 설정을 열지 못했습니다.")
        }
        pendingInstall = current.release to current.apk
    }

    /** Called when the user returns from Android's install-source permission screen or installer. */
    fun onResume() {
        val pending = pendingInstall ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !context.packageManager.canRequestPackageInstalls()) return
        val currentCode = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).longVersionCodeCompat()
        }.getOrDefault(BuildConfig.VERSION_CODE.toLong())
        if (currentCode >= pending.first.versionCode) {
            mutableState.value = PhoneBridgeUpdateState.Installed
            pendingInstall = null
        } else if (mutableState.value is PhoneBridgeUpdateState.InstallPermissionRequired) {
            openSystemInstaller(pending.first, pending.second)
        } else if (mutableState.value is PhoneBridgeUpdateState.AwaitingSystemConfirmation) {
            mutableState.value = PhoneBridgeUpdateState.Ready(pending.first, pending.second)
        }
    }

    fun close() {
        scope.cancel()
    }

    private fun openSystemInstaller(release: PhoneBridgeRelease, apk: File) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", apk)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, APK_MIME_TYPE)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        runCatching { activity.startActivity(intent) }
            .onSuccess { mutableState.value = PhoneBridgeUpdateState.AwaitingSystemConfirmation(release, apk) }
            .onFailure {
                mutableState.value = PhoneBridgeUpdateState.Failed(
                    if (it is ActivityNotFoundException) "Android 시스템 설치 화면을 찾지 못했습니다." else "Android 설치 화면을 열지 못했습니다."
                )
            }
    }

    private fun fetchRelease(): PhoneBridgeRelease {
        val connection = URL(UPDATE_MANIFEST_URL).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = NETWORK_TIMEOUT_MS
            connection.readTimeout = NETWORK_TIMEOUT_MS
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("User-Agent", "PhoneBridge-Android/${BuildConfig.VERSION_NAME}")
            connection.instanceFollowRedirects = true
            check(connection.responseCode in 200..299) { "업데이트 서버 응답 오류 (${connection.responseCode})" }
            val json = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            val manifest = JSONObject(json)
            val release = PhoneBridgeRelease(
                versionName = manifest.getString("versionName"),
                versionCode = manifest.getLong("versionCode"),
                apkUrl = manifest.getString("apkUrl"),
                sha256 = manifest.getString("sha256").lowercase(Locale.ROOT).removePrefix("sha256:"),
                notes = manifest.optString("notes", "PhoneBridge 업데이트"),
            )
            require(release.apkUrl.startsWith(RELEASE_APK_PREFIX)) { "허용되지 않은 업데이트 주소입니다." }
            require(release.sha256.matches(Regex("[a-f0-9]{64}"))) { "업데이트 해시가 올바르지 않습니다." }
            require(release.versionCode > 0 && release.versionName.isNotBlank()) { "업데이트 버전 정보가 올바르지 않습니다." }
            return release
        } finally {
            connection.disconnect()
        }
    }

    private suspend fun downloadAndVerify(release: PhoneBridgeRelease): File {
        require(release.apkUrl.startsWith(RELEASE_APK_PREFIX)) { "허용되지 않은 업데이트 주소입니다." }
        val updatesDirectory = File(context.cacheDir, "updates").apply { mkdirs() }
        val partial = File(updatesDirectory, "phonebridge-${release.versionName}.apk.part")
        val apk = File(updatesDirectory, "phonebridge-${release.versionName}.apk")
        val connection = URL(release.apkUrl).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = NETWORK_TIMEOUT_MS
            connection.readTimeout = DOWNLOAD_TIMEOUT_MS
            connection.instanceFollowRedirects = true
            connection.setRequestProperty("User-Agent", "PhoneBridge-Android/${BuildConfig.VERSION_NAME}")
            check(connection.responseCode in 200..299) { "APK 서버 응답 오류 (${connection.responseCode})" }
            val total = connection.contentLengthLong
            require(total <= MAX_APK_BYTES) { "APK 파일이 허용된 크기보다 큽니다." }
            val digest = MessageDigest.getInstance("SHA-256")
            var downloaded = 0L
            connection.inputStream.use { input ->
                partial.outputStream().buffered().use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE * 4)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        downloaded += count
                        require(downloaded <= MAX_APK_BYTES) { "APK 파일이 허용된 크기보다 큽니다." }
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                        if (total > 0) {
                            val percent = ((downloaded * 100) / total).toInt().coerceIn(0, 100)
                            mutableState.value = PhoneBridgeUpdateState.Downloading(release, percent)
                        }
                    }
                }
            }
            val actualHash = digest.digest().joinToString("") { "%02x".format(it) }
            require(actualHash.equals(release.sha256, ignoreCase = true)) { "APK SHA-256 검증에 실패했습니다." }
            val archive = context.packageManager.getPackageArchiveInfo(partial.absolutePath, PackageManager.GET_SIGNING_CERTIFICATES)
                ?: error("APK 정보를 읽지 못했습니다.")
            require(archive.packageName == context.packageName) { "다른 앱의 APK입니다." }
            require(archive.longVersionCodeCompat() == release.versionCode) { "APK 버전과 업데이트 정보가 일치하지 않습니다." }
            val signatures = archive.signingInfo?.apkContentsSigners?.map { sha256(it.toByteArray()) }.orEmpty()
            require(RELEASE_SIGNER_SHA256 in signatures) { "게시자 서명이 기존 PhoneBridge 앱과 다릅니다." }
            if (apk.exists()) apk.delete()
            check(partial.renameTo(apk)) { "업데이트 APK를 저장하지 못했습니다." }
            return apk
        } finally {
            connection.disconnect()
            if (partial.exists()) partial.delete()
        }
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes)
        .joinToString("") { "%02x".format(it) }

    @Suppress("DEPRECATION")
    private fun android.content.pm.PackageInfo.longVersionCodeCompat(): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) longVersionCode else versionCode.toLong()

    companion object {
        private const val UPDATE_MANIFEST_URL = "https://raw.githubusercontent.com/blossom0948/connectmac/main/updates/phonebridge-update.json"
        private const val RELEASE_APK_PREFIX = "https://github.com/blossom0948/connectmac/releases/download/"
        // The APKs are signed with the existing local Android debug certificate so current sideload installs upgrade in place.
        private const val RELEASE_SIGNER_SHA256 = "669674a2114fb59d85c56bba774b89fec9ce7f7ee79825769826130362a091c9"
        private const val PREFERENCES = "phonebridge_updates"
        private const val KEY_LAST_CHECK = "last_check_at"
        private const val CHECK_INTERVAL_MS = 6 * 60 * 60 * 1000L
        private const val NETWORK_TIMEOUT_MS = 15_000
        private const val DOWNLOAD_TIMEOUT_MS = 120_000
        private const val MAX_APK_BYTES = 200L * 1024 * 1024
        private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    }
}
