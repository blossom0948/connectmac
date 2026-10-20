package com.example.phonebridge.android.link

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Base64
import android.util.Size
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/** Queries only media the user has granted PhoneBridge access to. */
object PhoneGalleryBridge {
    private val imageCollection: Uri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI

    fun hasAccess(context: Context): Boolean = when {
        Build.VERSION.SDK_INT >= 34 -> has(context, Manifest.permission.READ_MEDIA_IMAGES) ||
            has(context, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        Build.VERSION.SDK_INT >= 33 -> has(context, Manifest.permission.READ_MEDIA_IMAGES)
        Build.VERSION.SDK_INT >= 23 -> has(context, Manifest.permission.READ_EXTERNAL_STORAGE)
        else -> true
    }

    fun sendPage(context: Context, offset: Int, requestedLimit: Int) {
        if (!LinkService.isConnected()) return
        if (!hasAccess(context)) {
            LinkService.sendEvent(context, JSONObject()
                .put("kind", "gallery_result")
                .put("success", false)
                .put("text", "Android 앱에서 사진 라이브러리 접근을 허용한 뒤 다시 불러오세요."))
            return
        }

        val safeOffset = offset.coerceIn(0, 20_000)
        val limit = requestedLimit.coerceIn(1, 60)
        val rows = mutableListOf<GalleryRow>()
        runCatching {
            val projection = arrayOf(
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.DISPLAY_NAME,
                MediaStore.Images.Media.SIZE,
                MediaStore.Images.Media.MIME_TYPE,
                MediaStore.Images.Media.DATE_ADDED,
            )
            val sortOrder = "${MediaStore.Images.Media.DATE_ADDED} DESC LIMIT ${safeOffset + limit + 1}"
            context.contentResolver.query(imageCollection, projection, null, null, sortOrder)?.use { cursor ->
                val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
                val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
                val mimeColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.MIME_TYPE)
                val dateColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED)
                var position = 0
                while (cursor.moveToNext()) {
                    if (position++ < safeOffset) continue
                    if (rows.size >= limit + 1) break
                    val id = cursor.getLong(idColumn)
                    val uri = ContentUris.withAppendedId(imageCollection, id)
                    rows.add(
                        GalleryRow(
                            id = id,
                            uri = uri,
                            name = cursor.getString(nameColumn)?.take(240)?.ifBlank { "photo-$id" } ?: "photo-$id",
                            size = cursor.getLong(sizeColumn).coerceAtLeast(0),
                            mime = cursor.getString(mimeColumn)?.take(120) ?: "image/*",
                            dateAdded = cursor.getLong(dateColumn),
                        )
                    )
                }
            }
        }.onFailure {
            LinkService.sendEvent(context, JSONObject()
                .put("kind", "gallery_result")
                .put("success", false)
                .put("text", "사진 라이브러리를 읽지 못했습니다. 접근 권한이 바뀌었을 수 있습니다."))
            return
        }

        val hasMore = rows.size > limit
        rows.take(limit).forEach { row ->
            val thumbnail = loadThumbnail(context, row)
            LinkService.sendEvent(context, JSONObject()
                .put("kind", "gallery_item")
                .put("eventId", row.id.toString())
                .put("title", row.name)
                .put("source", row.mime)
                .put("size", row.size)
                .put("timestamp", row.dateAdded.toDouble())
                .put("payload", thumbnail))
        }
        LinkService.sendEvent(context, JSONObject()
            .put("kind", "gallery_result")
            .put("success", true)
            .put("pageOffset", safeOffset)
            .put("hasMore", hasMore)
            .put("text", "사진 ${safeOffset + 1}–${safeOffset + rows.take(limit).size}개를 불러왔습니다."))
    }

    fun sendItem(context: Context, rawId: String, transferId: String) {
        val id = rawId.toLongOrNull()
        if (id == null || transferId.isBlank() || transferId.length > 80) return
        if (!hasAccess(context)) {
            LinkService.sendEvent(context, JSONObject().put("kind", "gallery_download_result")
                .put("success", false).put("eventId", transferId)
                .put("text", "Android 사진 접근 권한을 다시 확인하세요."))
            return
        }
        val uri = ContentUris.withAppendedId(imageCollection, id)
        runCatching {
            val name = context.contentResolver.query(
                uri,
                arrayOf(MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.MIME_TYPE, MediaStore.Images.Media.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                Triple(
                    cursor.getString(0)?.ifBlank { "photo-$id" } ?: "photo-$id",
                    cursor.getString(1) ?: "image/jpeg",
                    cursor.getLong(2),
                )
            } ?: error("사진을 찾을 수 없습니다.")
            require(name.third in 0..100L * 1024 * 1024) { "사진이 100MB 전송 한도를 넘습니다." }
            val bytes = context.contentResolver.openInputStream(uri)?.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(32 * 1024)
                var total = 0
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    require(total <= 100 * 1024 * 1024) { "사진이 100MB 전송 한도를 넘습니다." }
                    output.write(buffer, 0, read)
                }
                output.toByteArray()
            } ?: error("사진 파일을 열 수 없습니다.")
            check(LinkService.sendFile(context, name.first, name.second, bytes, transferId)) { "휴대폰 연결이 끊어졌습니다." }
            LinkService.sendEvent(context, JSONObject().put("kind", "gallery_download_result")
                .put("success", true).put("eventId", transferId).put("text", "사진 전송을 시작했습니다."))
        }.onFailure { error ->
            LinkService.sendEvent(context, JSONObject().put("kind", "gallery_download_result")
                .put("success", false).put("eventId", transferId)
                .put("text", error.message ?: "사진을 보내지 못했습니다."))
        }
    }

    private fun loadThumbnail(context: Context, row: GalleryRow): String {
        val bitmap = runCatching {
            if (Build.VERSION.SDK_INT >= 29) {
                context.contentResolver.loadThumbnail(row.uri, Size(180, 180), null)
            } else {
                @Suppress("DEPRECATION")
                MediaStore.Images.Thumbnails.getThumbnail(
                    context.contentResolver,
                    row.id,
                    MediaStore.Images.Thumbnails.MINI_KIND,
                    null,
                )
            }
        }.getOrNull() ?: return ""
        return runCatching {
            val output = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 56, output)
            Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP)
        }.getOrDefault("").also { if (!bitmap.isRecycled) bitmap.recycle() }
    }

    private fun has(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private data class GalleryRow(
        val id: Long,
        val uri: Uri,
        val name: String,
        val size: Long,
        val mime: String,
        val dateAdded: Long,
    )
}
