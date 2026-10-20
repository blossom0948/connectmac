package com.example.phonebridge.android.link

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class PhoneBridgeDiagnostic(val timestamp: Long, val category: String, val detail: String)

object PhoneBridgeDiagnostics {
    private const val MAX_ENTRIES = 150
    private val entries = ArrayDeque<PhoneBridgeDiagnostic>()
    private val formatter = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())

    fun record(category: String, detail: String) {
        synchronized(entries) {
            entries.addLast(PhoneBridgeDiagnostic(System.currentTimeMillis(), category, detail))
            while (entries.size > MAX_ENTRIES) entries.removeFirst()
            ConnectionState.diagnostics.value = entries.toList().asReversed()
        }
    }

    fun exportText(appVersion: String, status: String): String = synchronized(entries) {
        buildString {
            appendLine("PhoneBridge Android $appVersion")
            appendLine("연결 상태: $status")
            appendLine("개인정보, 알림 내용, 전화번호, 파일 이름은 진단 기록에 포함하지 않습니다.")
            appendLine()
            entries.forEach { item ->
                append(formatter.format(Date(item.timestamp)))
                append(" · ")
                append(item.category)
                append(" · ")
                appendLine(item.detail)
            }
        }
    }
}
