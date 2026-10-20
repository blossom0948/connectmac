package com.example.phonebridge.android.update

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.example.phonebridge.android.BuildConfig
import com.example.phonebridge.android.MainActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

internal object PhoneBridgeUpdateScheduler {
    private const val WORK_NAME = "phonebridge-update-check"

    fun schedule(context: Context) {
        val request = PeriodicWorkRequestBuilder<PhoneBridgeUpdateWorker>(1, TimeUnit.HOURS)
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build()
            )
            .build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            WORK_NAME,
            ExistingPeriodicWorkPolicy.KEEP,
            request,
        )
    }
}

class PhoneBridgeUpdateWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result = runCatching {
        val release = withContext(Dispatchers.IO) { PhoneBridgeUpdateCatalog.fetchLatestRelease() }
        val now = System.currentTimeMillis()
        val preferences = applicationContext.getSharedPreferences(PhoneBridgeUpdatePreferences.PREFERENCES, Context.MODE_PRIVATE)
        preferences.edit().putLong(PhoneBridgeUpdatePreferences.KEY_LAST_CHECK, now).apply()

        if (release.versionCode <= BuildConfig.VERSION_CODE.toLong()) return Result.success()
        val lastForeground = preferences.getLong(PhoneBridgeUpdatePreferences.KEY_LAST_FOREGROUND, 0L)
        if (now - lastForeground < FOREGROUND_GRACE_MS) return Result.success()
        val lastNotifiedVersion = preferences.getLong(PhoneBridgeUpdatePreferences.KEY_LAST_NOTIFIED_VERSION, 0L)
        if (release.versionCode <= lastNotifiedVersion) return Result.success()
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(
                applicationContext,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) return Result.success()
        if (!NotificationManagerCompat.from(applicationContext).areNotificationsEnabled()) return Result.success()

        createNotificationChannel()
        val tapIntent = Intent(applicationContext, MainActivity::class.java)
            .putExtra(EXTRA_UPDATE_NOTICE, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pendingIntent = PendingIntent.getActivity(
            applicationContext,
            NOTIFICATION_ID,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("PhoneBridge 업데이트")
            .setContentText("v${release.versionName}을 앱에서 설치할 수 있습니다.")
            .setStyle(NotificationCompat.BigTextStyle().bigText(release.notes))
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        NotificationManagerCompat.from(applicationContext).notify(NOTIFICATION_ID, notification)
        preferences.edit().putLong(PhoneBridgeUpdatePreferences.KEY_LAST_NOTIFIED_VERSION, release.versionCode).apply()
        Result.success()
    }.getOrElse { Result.retry() }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "PhoneBridge 업데이트",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "새 PhoneBridge 버전이 있을 때 한 번 알려줍니다."
        }
        applicationContext.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    companion object {
        const val EXTRA_UPDATE_NOTICE = "com.example.phonebridge.UPDATE_NOTICE"
        private const val CHANNEL_ID = "phonebridge_updates"
        private const val NOTIFICATION_ID = 4302
        private const val FOREGROUND_GRACE_MS = 20 * 60 * 1000L
    }
}
