package com.example.phonebridge.android.update

import com.example.phonebridge.android.BuildConfig
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

internal object PhoneBridgeUpdatePreferences {
    const val PREFERENCES = "phonebridge_updates"
    const val KEY_LAST_CHECK = "last_check_at"
    const val KEY_LAST_FOREGROUND = "last_foreground_at"
    const val KEY_LAST_NOTIFIED_VERSION = "last_notified_version"
}

internal object PhoneBridgeUpdateCatalog {
    private const val UPDATE_MANIFEST_URL =
        "https://raw.githubusercontent.com/blossom0948/connectmac/main/updates/phonebridge-update.json"
    private const val RELEASE_APK_PREFIX = "https://github.com/blossom0948/connectmac/releases/download/"

    fun fetchLatestRelease(): PhoneBridgeRelease {
        val connection = URL(UPDATE_MANIFEST_URL).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("User-Agent", "PhoneBridge-Android/${BuildConfig.VERSION_NAME}")
            connection.instanceFollowRedirects = true
            check(connection.responseCode in 200..299) { "업데이트 서버 응답 오류 (${connection.responseCode})" }
            val manifest = connection.inputStream.bufferedReader(Charsets.UTF_8).use { JSONObject(it.readText()) }
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
}
