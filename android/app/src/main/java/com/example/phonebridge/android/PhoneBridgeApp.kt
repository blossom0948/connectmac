package com.example.phonebridge.android

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.PhoneInTalk
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.RestartAlt
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.SystemUpdate
import androidx.compose.material.icons.automirrored.outlined.ScreenShare
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.phonebridge.android.link.ReceivedFileItem
import com.example.phonebridge.android.link.TransferProgress
import com.example.phonebridge.android.link.PhoneBridgeDiagnostic
import com.example.phonebridge.android.update.PhoneBridgeUpdateState

private enum class PhoneBridgeTab(val title: String, val icon: ImageVector) {
    Connection("연결", Icons.Outlined.Devices),
    Transfer("전송", Icons.Outlined.FolderOpen),
    Settings("설정", Icons.Outlined.Settings),
}

@Composable
fun PhoneBridgeApp(
    pairedName: String?,
    systemBarPadding: PaddingValues,
    linkStatus: String,
    receivedFiles: List<ReceivedFileItem>,
    transfers: List<TransferProgress>,
    diagnostics: List<PhoneBridgeDiagnostic>,
    screenShareStatus: String,
    galleryAccessGranted: Boolean,
    remoteControlEnabled: Boolean,
    updateState: PhoneBridgeUpdateState,
    notificationAccessGranted: Boolean,
    phonePermissionGranted: Boolean,
    onScan: () -> Unit,
    onReconnect: () -> Unit,
    onEnsureConnection: () -> Unit,
    onPickPhotos: () -> Unit,
    onPickFile: () -> Unit,
    onSendClipboard: () -> Unit,
    onOpenReceivedFile: (ReceivedFileItem) -> Unit,
    onShareReceivedFile: (ReceivedFileItem) -> Unit,
    onDeleteReceivedFile: (ReceivedFileItem) -> Unit,
    onCancelTransfer: (String) -> Unit,
    onExportDiagnostics: () -> Unit,
    onStartScreenShare: () -> Unit,
    onStopScreenShare: () -> Unit,
    onOpenNotificationSettings: () -> Unit,
    onRequestCallPermission: () -> Unit,
    onRequestGalleryPermission: () -> Unit,
    onOpenAccessibilitySettings: () -> Unit,
    onUnpair: () -> Unit,
    onUpdateAction: (PhoneBridgeUpdateState) -> Unit,
) {
    var selectedTab by rememberSaveable { mutableStateOf(PhoneBridgeTab.Connection) }
    var showUnpairConfirmation by remember { mutableStateOf(false) }
    val connected = linkStatus.startsWith("Mac에 연결됨")
    fun selectTab(tab: PhoneBridgeTab) {
        if (selectedTab != tab) onEnsureConnection()
        selectedTab = tab
    }

    Column(Modifier.fillMaxSize().padding(systemBarPadding)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 22.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(11.dp),
        ) {
            androidx.compose.foundation.Image(
                painter = androidx.compose.ui.res.painterResource(R.drawable.phonebridge_mark),
                contentDescription = "PhoneBridge",
                modifier = Modifier.size(42.dp),
            )
            Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text("PhoneBridge", fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Text("휴대폰과 Mac", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.weight(1f))
            ConnectionBadge(connected = connected)
        }

        AnimatedContent(
            targetState = selectedTab,
            modifier = Modifier.weight(1f),
            label = "phonebridge-tab-transition",
            transitionSpec = {
                (fadeIn(tween(170)) + slideInHorizontally(tween(190)) { it / 14 }) togetherWith
                    (fadeOut(tween(110)) + slideOutHorizontally(tween(150)) { -it / 14 })
            },
        ) { tab ->
            when (tab) {
                PhoneBridgeTab.Connection -> ConnectionTab(
                    pairedName = pairedName,
                    linkStatus = linkStatus,
                    connected = connected,
                    screenShareStatus = screenShareStatus,
                    onScan = onScan,
                    onReconnect = onReconnect,
                    onStartScreenShare = onStartScreenShare,
                    onStopScreenShare = onStopScreenShare,
                    onGoToTransfer = { selectTab(PhoneBridgeTab.Transfer) },
                    onGoToSettings = { selectTab(PhoneBridgeTab.Settings) },
                )
                PhoneBridgeTab.Transfer -> TransferTab(
                    connected = connected,
                    receivedFiles = receivedFiles,
                    transfers = transfers,
                    onPickPhotos = onPickPhotos,
                    onPickFile = onPickFile,
                    onSendClipboard = onSendClipboard,
                    onOpenReceivedFile = onOpenReceivedFile,
                    onShareReceivedFile = onShareReceivedFile,
                    onDeleteReceivedFile = onDeleteReceivedFile,
                    onCancelTransfer = onCancelTransfer,
                )
                PhoneBridgeTab.Settings -> SettingsTab(
                    updateState = updateState,
                    diagnostics = diagnostics,
                    notificationAccessGranted = notificationAccessGranted,
                    phonePermissionGranted = phonePermissionGranted,
                    galleryAccessGranted = galleryAccessGranted,
                    remoteControlEnabled = remoteControlEnabled,
                    onOpenNotificationSettings = onOpenNotificationSettings,
                    onRequestCallPermission = onRequestCallPermission,
                    onRequestGalleryPermission = onRequestGalleryPermission,
                    onOpenAccessibilitySettings = onOpenAccessibilitySettings,
                    onUpdateAction = { onUpdateAction(updateState) },
                    onExportDiagnostics = onExportDiagnostics,
                    onUnpair = { showUnpairConfirmation = true },
                )
            }
        }

        PhoneBridgeGlassPanel(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)) {
            NavigationBar(
                modifier = Modifier.fillMaxWidth(),
                containerColor = Color.Transparent,
                tonalElevation = 0.dp,
                windowInsets = WindowInsets(0.dp),
            ) {
                PhoneBridgeTab.entries.forEach { tab ->
                    NavigationBarItem(
                        selected = selectedTab == tab,
                        onClick = { selectTab(tab) },
                        icon = { Icon(tab.icon, contentDescription = null, modifier = Modifier.size(21.dp)) },
                        label = { Text(tab.title, fontSize = 13.sp, fontWeight = if (selectedTab == tab) FontWeight.SemiBold else FontWeight.Normal) },
                        alwaysShowLabel = true,
                    )
                }
            }
        }
    }

    if (showUnpairConfirmation) {
        AlertDialog(
            onDismissRequest = { showUnpairConfirmation = false },
            title = { Text("Mac 페어링을 해제할까요?") },
            text = { Text("저장된 연결 키가 삭제됩니다. 다시 연결하려면 Mac에서 새 QR 코드를 스캔해야 합니다.") },
            confirmButton = {
                TextButton(onClick = {
                    showUnpairConfirmation = false
                    onUnpair()
                }) { Text("페어링 해제", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { showUnpairConfirmation = false }) { Text("취소") }
            },
        )
    }
}

@Composable
private fun ConnectionTab(
    pairedName: String?,
    linkStatus: String,
    connected: Boolean,
    screenShareStatus: String,
    onScan: () -> Unit,
    onReconnect: () -> Unit,
    onStartScreenShare: () -> Unit,
    onStopScreenShare: () -> Unit,
    onGoToTransfer: () -> Unit,
    onGoToSettings: () -> Unit,
) {
    val paired = pairedName != null
    val connecting = linkStatus.contains("연결 중") || linkStatus.contains("복구 중")
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text("기기 연결", fontSize = 25.sp, fontWeight = FontWeight.Bold)
                Text("연결 상태와 빠른 동작", fontSize = 15.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        item {
            PhoneBridgeGlassPanel(Modifier.fillMaxWidth()) {
                Column(
                    Modifier.fillMaxWidth().padding(20.dp).animateContentSize(),
                    verticalArrangement = Arrangement.spacedBy(15.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Surface(
                            modifier = Modifier.size(58.dp),
                            shape = RoundedCornerShape(19.dp),
                            color = MaterialTheme.colorScheme.primary.copy(alpha = 0.13f),
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(Icons.Outlined.PhoneAndroid, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(31.dp))
                            }
                        }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(pairedName ?: "Mac과 연결하세요", fontSize = 21.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(
                                when {
                                    connected -> "같은 Wi-Fi에서 안전하게 연결됨"
                                    connecting -> linkStatus
                                    paired -> "같은 Wi-Fi에서 자동으로 다시 연결합니다"
                                    else -> "Mac 앱의 QR 코드를 스캔해 페어링하세요"
                                },
                                fontSize = 14.sp,
                                lineHeight = 19.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    if (!paired) {
                        MotionButton(text = "Mac QR 코드 스캔", icon = Icons.Outlined.PhoneAndroid, onClick = onScan, modifier = Modifier.fillMaxWidth())
                    } else {
                        MotionButton(
                            text = when {
                                connected -> "Mac에 연결됨"
                                connecting -> "다시 연결하는 중…"
                                else -> "다시 연결"
                            },
                            icon = if (connected) Icons.Outlined.CheckCircle else Icons.Outlined.RestartAlt,
                            onClick = onReconnect,
                            enabled = !connected && !connecting,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(11.dp)) {
                MotionTile(
                    modifier = Modifier.weight(1f),
                    icon = Icons.Outlined.FolderOpen,
                    title = "파일 보내기",
                    detail = "사진과 문서",
                    onClick = onGoToTransfer,
                )
                MotionTile(
                    modifier = Modifier.weight(1f),
                    icon = Icons.Outlined.Notifications,
                    title = "연결 설정",
                    detail = "알림과 권한",
                    onClick = onGoToSettings,
                )
            }
        }
        item {
            PhoneBridgeSurface(Modifier.fillMaxWidth()) {
                Column(Modifier.fillMaxWidth().padding(17.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Icon(Icons.AutoMirrored.Outlined.ScreenShare, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                        Column(Modifier.weight(1f)) {
                            Text("휴대폰 화면", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                            Text(screenShareStatus, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    MotionOutlinedButton(
                        text = if (screenShareStatus == "화면 공유 중") "화면 공유 중지" else "화면 공유 시작",
                        onClick = if (screenShareStatus == "화면 공유 중") onStopScreenShare else onStartScreenShare,
                        enabled = connected,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
        item {
            Text("같은 Wi-Fi에서 연결을 유지하고, 신호가 끊기면 자동으로 다시 찾습니다.", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 3.dp))
        }
    }
}

@Composable
private fun TransferTab(
    connected: Boolean,
    receivedFiles: List<ReceivedFileItem>,
    transfers: List<TransferProgress>,
    onPickPhotos: () -> Unit,
    onPickFile: () -> Unit,
    onSendClipboard: () -> Unit,
    onOpenReceivedFile: (ReceivedFileItem) -> Unit,
    onShareReceivedFile: (ReceivedFileItem) -> Unit,
    onDeleteReceivedFile: (ReceivedFileItem) -> Unit,
    onCancelTransfer: (String) -> Unit,
) {
    var selectedFilter by rememberSaveable { mutableStateOf("모두") }
    var pendingDelete by remember { mutableStateOf<ReceivedFileItem?>(null) }
    val visibleFiles = receivedFiles.filter { item ->
        when (selectedFilter) {
            "사진" -> item.contentType.startsWith("image/")
            "파일" -> !item.contentType.startsWith("image/")
            else -> true
        }
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text("파일 전송", fontSize = 25.sp, fontWeight = FontWeight.Bold)
                Text(if (connected) "이 휴대폰과 Mac 사이에 전송" else "파일을 보내려면 Mac에 연결하세요", fontSize = 15.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        item {
            PhoneBridgeGlassPanel(Modifier.fillMaxWidth()) {
                Column(Modifier.fillMaxWidth().padding(17.dp), verticalArrangement = Arrangement.spacedBy(13.dp)) {
                    Text("Mac으로 보내기", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        MotionButton(
                            text = "사진",
                            icon = Icons.Outlined.PhotoLibrary,
                            onClick = onPickPhotos,
                            enabled = connected,
                            modifier = Modifier.weight(1f),
                        )
                        MotionOutlinedButton(
                            text = "파일",
                            icon = Icons.Outlined.FolderOpen,
                            onClick = onPickFile,
                            enabled = connected,
                            modifier = Modifier.weight(1f),
                        )
                    }
                    Text("선택한 항목만 전송합니다. 최대 100 MB", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        if (transfers.isNotEmpty()) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("전송 상태", fontSize = 18.sp, fontWeight = FontWeight.Bold)
                        Spacer(Modifier.weight(1f))
                        Text("${transfers.count { it.status == "전송 중" || it.status == "이어받기 대기" }}개 진행 중", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    transfers.take(5).forEach { transfer ->
                        PhoneBridgeSurface(Modifier.fillMaxWidth()) {
                            Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                        Text(transfer.name, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                        Text("${transfer.direction} · ${transfer.status} · ${transfer.detail}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                    }
                                    if (transfer.status == "전송 중" || transfer.status == "이어받기 대기") {
                                        TextButton(onClick = { onCancelTransfer(transfer.id) }) { Text("취소", color = MaterialTheme.colorScheme.error) }
                                    }
                                }
                                val fraction = if (transfer.totalBytes > 0L) {
                                    (transfer.transferredBytes.toFloat() / transfer.totalBytes.toFloat()).coerceIn(0f, 1f)
                                } else 0f
                                androidx.compose.material3.LinearProgressIndicator(
                                    progress = { fraction },
                                    modifier = Modifier.fillMaxWidth(),
                                )
                                Text(
                                    "${android.text.format.Formatter.formatFileSize(androidx.compose.ui.platform.LocalContext.current, transfer.transferredBytes)} / ${android.text.format.Formatter.formatFileSize(androidx.compose.ui.platform.LocalContext.current, transfer.totalBytes)}",
                                    fontSize = 12.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                }
            }
        }
        item {
            PhoneBridgeSurface(Modifier.fillMaxWidth()) {
                Column(Modifier.fillMaxWidth().padding(17.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Icon(Icons.Outlined.ContentPaste, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                        Column(Modifier.weight(1f)) {
                            Text("클립보드 보내기", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                            Text("버튼을 누를 때 텍스트만 전송", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    MotionOutlinedButton(text = "Mac으로 보내기", onClick = onSendClipboard, enabled = connected, modifier = Modifier.fillMaxWidth())
                }
            }
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Mac에서 받은 파일", fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                Text("${visibleFiles.size}개", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("모두", "사진", "파일").forEach { filter ->
                    FilterChip(
                        selected = selectedFilter == filter,
                        onClick = { selectedFilter = filter },
                        label = { Text(filter, fontSize = 14.sp) },
                    )
                }
            }
        }
        if (visibleFiles.isEmpty()) {
            item {
                if (receivedFiles.isEmpty()) EmptyTransferCard()
                else Text("이 분류에 받은 항목이 없습니다.", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 4.dp, vertical = 8.dp))
            }
        } else {
            items(visibleFiles.take(20), key = { it.path }) { item ->
                PhoneBridgeSurface(Modifier.fillMaxWidth()) {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 15.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Surface(
                            modifier = Modifier.size(40.dp),
                            shape = RoundedCornerShape(14.dp),
                            color = MaterialTheme.colorScheme.primary.copy(alpha = 0.10f),
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(
                                    if (item.contentType.startsWith("image/")) Icons.Outlined.PhotoLibrary else Icons.Outlined.FolderOpen,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(21.dp),
                                )
                            }
                        }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(item.name, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(android.text.format.Formatter.formatFileSize(androidx.compose.ui.platform.LocalContext.current, item.size), fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        IconButton(onClick = { onShareReceivedFile(item) }, modifier = Modifier.size(40.dp)) {
                            Icon(Icons.Outlined.Share, contentDescription = "다른 앱으로 공유", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        TextButton(onClick = { onOpenReceivedFile(item) }) { Text("열기", fontSize = 14.sp) }
                        IconButton(onClick = { pendingDelete = item }, modifier = Modifier.size(40.dp)) {
                            Icon(Icons.Outlined.DeleteOutline, contentDescription = "받은 파일 삭제", tint = MaterialTheme.colorScheme.error)
                        }
                    }
                }
            }
            if (visibleFiles.size > 20) {
                item { Text("최근 20개를 표시하고 있습니다.", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
    }

    pendingDelete?.let { item ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("받은 파일을 삭제할까요?") },
            text = { Text("${item.name}을(를) PhoneBridge 저장 공간에서 삭제합니다.") },
            confirmButton = {
                TextButton(onClick = {
                    pendingDelete = null
                    onDeleteReceivedFile(item)
                }) { Text("삭제", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("취소") } },
        )
    }
}

@Composable
private fun SettingsTab(
    updateState: PhoneBridgeUpdateState,
    diagnostics: List<PhoneBridgeDiagnostic>,
    notificationAccessGranted: Boolean,
    phonePermissionGranted: Boolean,
    galleryAccessGranted: Boolean,
    remoteControlEnabled: Boolean,
    onOpenNotificationSettings: () -> Unit,
    onRequestCallPermission: () -> Unit,
    onRequestGalleryPermission: () -> Unit,
    onOpenAccessibilitySettings: () -> Unit,
    onUpdateAction: () -> Unit,
    onExportDiagnostics: () -> Unit,
    onUnpair: () -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text("설정", fontSize = 25.sp, fontWeight = FontWeight.Bold)
                Text("원하는 기능만 켜서 사용하세요", fontSize = 15.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("권한", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 2.dp))
                PhoneBridgeSurface(Modifier.fillMaxWidth()) {
                    Column(Modifier.fillMaxWidth()) {
                        PermissionRow(
                            title = "알림 전달",
                            detail = "휴대폰 앱 알림을 Mac에 표시",
                            granted = notificationAccessGranted,
                            onClick = onOpenNotificationSettings,
                        )
                        PermissionDivider()
                        PermissionRow(
                            title = "전화 상태",
                            detail = "통화 상태 알림만 전달",
                            granted = phonePermissionGranted,
                            onClick = onRequestCallPermission,
                        )
                        PermissionDivider()
                        PermissionRow(
                            title = "사진 보관함",
                            detail = "허용한 사진만 Mac에서 보기",
                            granted = galleryAccessGranted,
                            onClick = onRequestGalleryPermission,
                        )
                        PermissionDivider()
                        PermissionRow(
                            title = "원격 터치",
                            detail = "화면 공유 중 탭과 스와이프 전달",
                            granted = remoteControlEnabled,
                            onClick = onOpenAccessibilitySettings,
                        )
                    }
                }
                Text("전화 권한은 발신자 정보나 통화 음성을 읽지 않습니다.", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 2.dp))
            }
        }
        item {
            PhoneBridgeSurface(Modifier.fillMaxWidth()) {
                Column(Modifier.fillMaxWidth().padding(17.dp).animateContentSize(), verticalArrangement = Arrangement.spacedBy(9.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                        Icon(Icons.Outlined.SystemUpdate, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                        Text("앱 업데이트", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                        Spacer(Modifier.weight(1f))
                        Text("v${BuildConfig.VERSION_NAME}", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text(updateState.shortDescription(), fontSize = 14.sp, lineHeight = 19.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    if (updateState is PhoneBridgeUpdateState.Downloading && updateState.progress != null) {
                        Text("다운로드 ${updateState.progress}%", fontSize = 14.sp, color = MaterialTheme.colorScheme.primary)
                    }
                    MotionOutlinedButton(
                        text = updateState.actionTitle(),
                        icon = Icons.Outlined.SystemUpdate,
                        onClick = onUpdateAction,
                        enabled = updateState !is PhoneBridgeUpdateState.Checking &&
                            updateState !is PhoneBridgeUpdateState.Downloading &&
                            updateState !is PhoneBridgeUpdateState.AwaitingSystemConfirmation,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
        item {
            PhoneBridgeSurface(Modifier.fillMaxWidth()) {
                Column(Modifier.fillMaxWidth().padding(17.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("연결 진단", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    Text("최근 연결·전송 오류 기록 ${diagnostics.size}개 · 알림 내용, 전화번호, 파일 이름은 저장하지 않습니다.", fontSize = 13.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    diagnostics.take(3).forEach { entry ->
                        Text("${android.text.format.DateFormat.format("HH:mm:ss", entry.timestamp)} · ${entry.category}: ${entry.detail}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                    MotionOutlinedButton(
                        text = "진단 기록 공유",
                        icon = Icons.Outlined.Share,
                        onClick = onExportDiagnostics,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
        item {
            PhoneBridgeSurface(Modifier.fillMaxWidth()) {
                Row(
                    Modifier.fillMaxWidth().clickable(onClick = onUnpair).padding(horizontal = 17.dp, vertical = 15.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Icon(Icons.Outlined.DeleteOutline, contentDescription = null, tint = MaterialTheme.colorScheme.error)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("Mac 페어링 해제", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.error)
                        Text("확인 창에서 한 번 더 묻습니다", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Icon(Icons.Outlined.ChevronRight, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
private fun ConnectionBadge(connected: Boolean) {
    val color = if (connected) Color(0xFF159A6A) else Color(0xFFB87912)
    Surface(color = color.copy(alpha = 0.13f), shape = CircleShape) {
        Row(
            Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            Surface(color = color, shape = CircleShape, modifier = Modifier.size(7.dp)) {}
            Text(if (connected) "연결됨" else "대기 중", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
        }
    }
}

@Composable
private fun MotionButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    icon: ImageVector? = null,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed && enabled) 0.965f else 1f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = Spring.StiffnessMedium),
        label = "button-press-scale",
    )
    Button(
        onClick = onClick,
        modifier = modifier.height(54.dp).graphicsLayer { scaleX = scale; scaleY = scale },
        enabled = enabled,
        shape = RoundedCornerShape(18.dp),
        interactionSource = interaction,
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
        colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (icon != null) Icon(icon, contentDescription = null, modifier = Modifier.size(19.dp))
            Text(text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun MotionOutlinedButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    icon: ImageVector? = null,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed && enabled) 0.965f else 1f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = Spring.StiffnessMedium),
        label = "outlined-button-press-scale",
    )
    OutlinedButton(
        onClick = onClick,
        modifier = modifier.height(52.dp).graphicsLayer { scaleX = scale; scaleY = scale },
        enabled = enabled,
        shape = RoundedCornerShape(17.dp),
        interactionSource = interaction,
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            if (icon != null) Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
            Text(text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun MotionTile(
    modifier: Modifier = Modifier,
    icon: ImageVector,
    title: String,
    detail: String,
    onClick: () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.975f else 1f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = Spring.StiffnessMedium),
        label = "quick-tile-press-scale",
    )
    PhoneBridgeSurface(
        modifier.graphicsLayer { scaleX = scale; scaleY = scale }
            .clip(RoundedCornerShape(22.dp))
            .clickable(interactionSource = interaction, indication = LocalIndication.current, onClick = onClick),
    ) {
        Column(Modifier.fillMaxWidth().padding(15.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(22.dp))
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text(detail, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun PermissionRow(title: String, detail: String, granted: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 15.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        Icon(
            if (granted) Icons.Outlined.CheckCircle else Icons.Outlined.ChevronRight,
            contentDescription = null,
            tint = if (granted) Color(0xFF159A6A) else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(20.dp),
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text(detail, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(if (granted) "허용" else "설정", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = if (granted) Color(0xFF159A6A) else MaterialTheme.colorScheme.primary)
    }
}

@Composable
private fun PermissionDivider() {
    androidx.compose.material3.HorizontalDivider(
        modifier = Modifier.padding(start = 46.dp, end = 14.dp),
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f),
    )
}

@Composable
private fun EmptyTransferCard() {
    PhoneBridgeSurface(Modifier.fillMaxWidth()) {
        Column(
            Modifier.fillMaxWidth().padding(vertical = 21.dp, horizontal = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(Icons.Outlined.FolderOpen, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(26.dp))
            Text("받은 파일이 여기에 표시됩니다", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

private fun PhoneBridgeUpdateState.shortDescription(): String = when (this) {
    PhoneBridgeUpdateState.Idle -> "앱 안에서 업데이트를 확인하고 설치할 수 있습니다."
    PhoneBridgeUpdateState.Checking -> "최신 버전을 확인하고 있습니다."
    PhoneBridgeUpdateState.UpToDate -> "현재 최신 버전을 사용 중입니다."
    is PhoneBridgeUpdateState.Available -> "새 버전 v${release.versionName}을 설치할 수 있습니다."
    is PhoneBridgeUpdateState.Downloading -> "v${release.versionName}을 안전하게 내려받고 있습니다."
    is PhoneBridgeUpdateState.Ready -> "다운로드와 서명을 확인했습니다."
    is PhoneBridgeUpdateState.InstallPermissionRequired -> "Android 설정에서 앱 설치 권한을 허용해 주세요."
    is PhoneBridgeUpdateState.AwaitingSystemConfirmation -> "Android 설치 화면에서 업데이트를 승인해 주세요."
    PhoneBridgeUpdateState.Installed -> "PhoneBridge 업데이트를 마쳤습니다."
    is PhoneBridgeUpdateState.Failed -> message
}

private fun PhoneBridgeUpdateState.actionTitle(): String = when (this) {
    is PhoneBridgeUpdateState.Available -> "업데이트 다운로드"
    is PhoneBridgeUpdateState.Ready -> "업데이트 설치"
    is PhoneBridgeUpdateState.InstallPermissionRequired -> "설치 권한 설정"
    is PhoneBridgeUpdateState.AwaitingSystemConfirmation -> "설치 확인 대기 중"
    is PhoneBridgeUpdateState.Checking -> "확인 중…"
    is PhoneBridgeUpdateState.Downloading -> "다운로드 중…"
    PhoneBridgeUpdateState.Idle, PhoneBridgeUpdateState.UpToDate, PhoneBridgeUpdateState.Installed -> "업데이트 확인"
    is PhoneBridgeUpdateState.Failed -> "다시 확인"
}
