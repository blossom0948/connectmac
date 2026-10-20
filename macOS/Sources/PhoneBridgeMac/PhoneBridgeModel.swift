import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import Network
import Security
import UniformTypeIdentifiers
import UserNotifications

struct PhoneEvent: Identifiable, Codable {
    let eventId: String?
    let kind: String
    let title: String?
    let text: String?
    let source: String?
    let battery: Int?
    let callState: String?
    let timestamp: Double?
    let canReply: Bool?
    let transferIndex: Int?
    let transferCount: Int?
    let nextIndex: Int?
    let payload: String?
    let actions: [PhoneEventAction]?
    let success: Bool?
    let size: Int64?
    let pageOffset: Int?
    let hasMore: Bool?

    var id: String { eventId ?? "\(kind)-\(timestamp ?? 0)-\(title ?? "")" }

    enum CodingKeys: String, CodingKey {
        case eventId, kind, title, text, source, battery, callState, timestamp
        case canReply, transferIndex, transferCount, nextIndex, payload, actions, success, size, pageOffset, hasMore
    }
}

struct PhoneEventAction: Identifiable, Codable {
    let id: String
    let title: String
}

struct ReceivedFile: Identifiable {
    let id: String
    let name: String
    let contentType: String
    let data: Data
    let receivedAt: Date
}

enum OutgoingTransferStatus: Equatable {
    case queued
    case preparing
    case sending
    case paused
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .queued: "대기 중"
        case .preparing: "준비 중"
        case .sending: "전송 중"
        case .paused: "연결 대기"
        case .completed: "휴대폰에 저장됨"
        case .failed: "전송 실패"
        case .cancelled: "취소됨"
        }
    }
}

struct OutgoingTransfer: Identifiable {
    let id: String
    let name: String
    let sourceURL: URL
    var size: Int64
    var transferredBytes: Int64
    var status: OutgoingTransferStatus
    var detail: String
}

struct PhoneBridgeTransferProgress: Identifiable {
    let id: String
    let name: String
    let direction: String
    let totalBytes: Int64
    let transferredBytes: Int64
    let status: String
    let detail: String
}

struct PhoneBridgeDiagnosticEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let category: String
    let detail: String
}

private struct PhoneBridgeDiagnosticReport: Codable {
    let appVersion: String
    let connected: Bool
    let entries: [PhoneBridgeDiagnosticEntry]
}

struct PhoneGalleryItem: Identifiable {
    let id: String
    let name: String
    let contentType: String
    let size: Int64
    let dateAdded: Date?
    let thumbnailData: Data?

    var thumbnail: NSImage? {
        guard let thumbnailData else { return nil }
        return NSImage(data: thumbnailData)
    }
}

private struct IncomingTransfer {
    let name: String
    let contentType: String
    let count: Int
    var receivedBytes = 0
    var chunks: [Int: Data] = [:]
}

private struct ResumableIncomingTransfer: Codable {
    let id: String
    let name: String
    let contentType: String
    let size: Int64
    let count: Int
    var nextIndex: Int
    var partPath: String
    var completed: Bool? = false
}

struct PairedDevice: Codable {
    let name: String
    let secret: Data
}

@MainActor
final class PhoneBridgeModel: ObservableObject {
    @Published var selectedSection = "개요"
    @Published var status = "로컬 연결 시작 중…"
    @Published var isConnected = false
    @Published var deviceName: String?
    @Published var battery: Int?
    @Published var callState = "통화 중이 아닙니다"
    @Published var events: [PhoneEvent] = []
    @Published var pairingImage: NSImage?
    @Published var pairingError: String?
    @Published var isPaired = false
    @Published var localAddress = ""
    @Published var showUnpairConfirmation = false
    @Published var pairingExpiresAt: Date?
    @Published var receivedFiles: [ReceivedFile] = []
    @Published var outgoingTransfers: [OutgoingTransfer] = []
    @Published var incomingTransferProgress: [PhoneBridgeTransferProgress] = []
    @Published private(set) var diagnostics: [PhoneBridgeDiagnosticEntry] = []
    @Published var actionMessage: String?
    @Published var screenFrame: NSImage?
    @Published var phoneClipboardText: String?
    @Published var remoteControlEnabled = false
    @Published var galleryItems: [PhoneGalleryItem] = []
    @Published var galleryStatus = "휴대폰 사진 라이브러리를 불러오세요."
    @Published var galleryHasMore = false
    @Published var galleryIsLoading = false
    @Published var galleryDownloadingAssetIDs: Set<String> = []
    @Published var activeGalleryDownloadAssetID: String?

    private let server = MacLinkServer()
    private var incomingTransfers: [String: IncomingTransfer] = [:]
    private var resumableIncomingTransfers: [String: ResumableIncomingTransfer] = [:]
    private var galleryDownloadQueue: [PhoneGalleryItem] = []
    private var activeGalleryDownload: (transferID: String, item: PhoneGalleryItem)?
    private var galleryTransferToAsset: [String: String] = [:]
    private var activeOutgoingTransferID: String?
    private var activeOutgoingTransferData: Data?
    private var activeOutgoingTransferChunkSize = 24 * 1_024
    private var peerSupportsTransferControl = false

    init() {
        let paired = PairKeyStore.load()
        isPaired = paired != nil
        deviceName = paired?.name
        localAddress = NetworkAddress.localIPv4() ?? ""
        server.onStatus = { [weak self] status, connected in
            Task { @MainActor in
                let connectionChanged = self?.isConnected != connected
                self?.status = status
                self?.isConnected = connected
                if connectionChanged {
                    self?.recordDiagnostic("연결", connected ? "Mac과 휴대폰이 연결되었습니다." : "연결이 끊겨 자동 재연결을 시작했습니다.")
                }
                if !connected {
                    self?.screenFrame = nil
                    self?.galleryIsLoading = false
                    self?.incomingTransfers.removeAll()
                    self?.resumableIncomingTransfers.values.forEach { transfer in
                        self?.updateIncomingTransferProgress(transfer,
                            bytes: min(transfer.size, Int64(transfer.nextIndex * 24 * 1_024)),
                            status: "이어받기 대기", detail: "연결되면 파일 받기를 이어갑니다.")
                    }
                    if let active = self?.activeGalleryDownload {
                        self?.galleryDownloadQueue.insert(active.item, at: 0)
                        self?.activeGalleryDownload = nil
                        self?.activeGalleryDownloadAssetID = nil
                        self?.galleryTransferToAsset.removeAll()
                        self?.galleryStatus = "연결이 끊겨 사진 전송을 대기 중입니다. 다시 연결되면 이어집니다."
                    }
                    if let transferID = self?.activeOutgoingTransferID {
                        self?.updateOutgoingTransfer(transferID, status: .paused, detail: "연결이 끊겼습니다. 재연결 후 이어서 전송합니다.")
                        self?.activeOutgoingTransferID = nil
                        self?.activeOutgoingTransferData = nil
                    }
                } else {
                    self?.startNextGalleryDownload()
                    self?.startNextOutgoingTransfer()
                }
            }
        }
        server.onPaired = { [weak self] name in
            Task { @MainActor in
                self?.deviceName = name
                self?.isPaired = true
                self?.pairingImage = nil
                self?.pairingExpiresAt = nil
                self?.pairingError = nil
            }
        }
        server.onEvent = { [weak self] event in
            Task { @MainActor in self?.receive(event) }
        }
        server.onCapabilities = { [weak self] capabilities in
            Task { @MainActor in self?.peerSupportsTransferControl = capabilities.contains("transfer-control-v1") }
        }
        server.start()
        cleanTransferStorage()
        restoreCompletedIncomingTransfers()
        if paired == nil {
            createPairingCode()
        }
    }

    func createPairingCode() {
        pairingImage = nil
        pairingError = nil
        let secret = SecureRandom.bytes(count: 32)
        let expiry = Date().addingTimeInterval(300)
        server.setPendingSecret(secret, expiresAt: expiry)
        pairingExpiresAt = expiry
        guard let address = NetworkAddress.localIPv4() else {
            pairingError = "Mac의 Wi‑Fi 주소를 찾을 수 없습니다. Wi‑Fi를 켠 뒤 다시 시도하세요."
            return
        }
        localAddress = address
        let payload: [String: Any] = [
            "version": 1,
            "host": address,
            "port": MacLinkServer.port,
            "secret": secret.base64EncodedString()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let image = QRCodeRenderer.make(from: data) else {
            pairingError = "페어링 코드를 만들지 못했습니다."
            return
        }
        pairingImage = image
        pairingError = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard let self, self.pairingExpiresAt == expiry, !self.isPaired else { return }
            self.pairingImage = nil
            self.pairingError = "QR 코드가 만료되었습니다. 새 코드를 만들어 다시 연결하세요."
            self.server.expirePendingSecret()
        }
    }

    func unpair() {
        PairKeyStore.clear()
        server.clearPairing()
        isPaired = false
        isConnected = false
        deviceName = nil
        battery = nil
        events.removeAll()
        galleryItems.removeAll()
        galleryHasMore = false
        galleryDownloadQueue.removeAll()
        activeGalleryDownload = nil
        activeGalleryDownloadAssetID = nil
        galleryTransferToAsset.removeAll()
        galleryDownloadingAssetIDs.removeAll()
        outgoingTransfers.removeAll()
        activeOutgoingTransferID = nil
        activeOutgoingTransferData = nil
        createPairingCode()
        status = "Android 앱에서 QR 코드를 스캔하세요"
    }

    func selectSection(_ section: String) {
        guard selectedSection != section else { return }
        selectedSection = section
    }

    func requestMacNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                if let error {
                    self?.actionMessage = "Mac 알림 권한을 요청하지 못했습니다: \(error.localizedDescription)"
                } else if !granted {
                    self?.actionMessage = "Mac 시스템 설정에서 PhoneBridge 알림을 허용하면 알림 배너를 볼 수 있습니다."
                } else {
                    self?.actionMessage = "PhoneBridge 알림을 켰습니다."
                }
            }
        }
    }

    func sendReply(to event: PhoneEvent, text: String) {
        guard let eventId = event.eventId, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        server.sendSecure(["kind": "notification_reply", "eventId": eventId, "text": text])
        actionMessage = "답장을 휴대폰으로 보내는 중입니다."
    }

    func dismissPhoneNotification(_ event: PhoneEvent) {
        guard isConnected, let eventId = event.eventId else {
            actionMessage = "휴대폰 알림을 지우려면 연결을 확인하세요."
            return
        }
        server.sendSecure(["kind": "dismiss_notification", "eventId": eventId])
        actionMessage = "휴대폰에서 알림을 지우는 중입니다."
    }

    func composeSMS(to recipient: String, body: String) {
        guard isConnected else {
            actionMessage = "문자를 작성하려면 휴대폰을 연결하세요."
            return
        }
        let number = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-")
        let digits = number.filter(\.isNumber).count
        guard !number.isEmpty, number.unicodeScalars.allSatisfy(allowed.contains), (3...20).contains(digits) else {
            actionMessage = "전화번호를 확인하세요. 숫자와 +, 공백, 괄호, 하이픈만 사용할 수 있습니다."
            return
        }
        guard !message.isEmpty, message.utf8.count <= 4_000 else {
            actionMessage = "문자 내용을 입력하세요. 한 번에 4KB까지 작성할 수 있습니다."
            return
        }
        server.sendSecure(["kind": "compose_sms", "recipient": number, "text": message])
        actionMessage = "휴대폰에 문자 작성 알림을 보냈습니다. 휴대폰에서 내용을 확인하고 직접 전송하세요."
    }

    func openPhoneDialer(number: String) {
        guard isConnected else {
            actionMessage = "전화를 걸려면 휴대폰을 연결하세요."
            return
        }
        let recipient = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-")
        let digits = recipient.filter(\.isNumber).count
        guard !recipient.isEmpty, recipient.unicodeScalars.allSatisfy(allowed.contains), (3...20).contains(digits) else {
            actionMessage = "전화번호를 확인하세요. 숫자와 +, 공백, 괄호, 하이픈만 사용할 수 있습니다."
            return
        }
        server.sendSecure(["kind": "open_dialer", "recipient": recipient])
        actionMessage = "휴대폰에 전화 걸기 알림을 보냈습니다. 휴대폰에서 번호를 확인하고 통화를 시작하세요."
    }

    func clearEvents() {
        events.removeAll()
        actionMessage = "최근 활동을 지웠습니다."
    }

    func controlMedia(_ action: String) {
        server.sendSecure(["kind": "media_control", "action": action])
        actionMessage = "미디어 제어 명령을 보냈습니다."
    }

    func sendCallAction(event: PhoneEvent, actionId: String) {
        guard let eventId = event.eventId else { return }
        server.sendSecure(["kind": "call_action", "eventId": eventId, "actionId": actionId])
        actionMessage = "전화 동작을 휴대폰으로 보내는 중입니다."
    }

    func findPhone() {
        server.sendSecure(["kind": "find_phone"])
        actionMessage = "휴대폰 찾기 알림음을 요청했습니다."
    }

    func stopScreenMirror() {
        server.sendSecure(["kind": "stop_screen_mirror"])
        actionMessage = "Android 화면 공유 중지를 요청했습니다."
    }

    func controlPhoneScreen(action: String, x: CGPoint? = nil, end: CGPoint? = nil) {
        guard isConnected else {
            actionMessage = "휴대폰을 연결한 뒤 다시 시도하세요."
            return
        }
        guard remoteControlEnabled else {
            actionMessage = "Android 앱의 접근성 설정에서 PhoneBridge 원격 터치를 켜세요."
            return
        }
        var command: [String: Any] = ["kind": "remote_control", "action": action]
        if let x {
            command["x"] = Double(x.x)
            command["y"] = Double(x.y)
        }
        if let end {
            command["endX"] = Double(end.x)
            command["endY"] = Double(end.y)
        }
        server.sendSecure(command)
    }

    func requestGallery(offset: Int = 0) {
        guard isConnected else {
            galleryStatus = "사진을 보려면 Android 휴대폰을 연결하세요."
            return
        }
        if offset == 0 { galleryItems.removeAll() }
        galleryIsLoading = true
        galleryStatus = "휴대폰 사진을 불러오는 중…"
        server.sendSecure(["kind": "gallery_list", "offset": offset, "limit": 24])
    }

    func downloadGalleryItem(_ item: PhoneGalleryItem) {
        downloadGalleryItems([item])
    }

    func downloadGalleryItems(_ items: [PhoneGalleryItem]) {
        guard isConnected else { galleryStatus = "사진을 받으려면 휴대폰을 연결하세요."; return }
        var added = 0
        for item in items where galleryDownloadingAssetIDs.insert(item.id).inserted {
            galleryDownloadQueue.append(item)
            added += 1
        }
        guard added > 0 else {
            galleryStatus = "선택한 사진은 이미 전송 중이거나 대기 중입니다."
            return
        }
        galleryStatus = added == 1 ? "사진 전송을 시작합니다…" : "사진 \(added)개를 순서대로 받습니다."
        startNextGalleryDownload()
    }

    private func startNextGalleryDownload() {
        guard isConnected, activeGalleryDownload == nil, !galleryDownloadQueue.isEmpty else { return }
        let item = galleryDownloadQueue.removeFirst()
        let transferId = UUID().uuidString
        activeGalleryDownload = (transferId, item)
        activeGalleryDownloadAssetID = item.id
        galleryTransferToAsset[transferId] = item.id
        galleryStatus = "\(item.name)을(를) 휴대폰에서 받는 중…"
        server.sendSecure([
            "kind": "gallery_fetch",
            "assetId": item.id,
            "transferId": transferId,
        ])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard let self, self.activeGalleryDownload?.transferID == transferId else { return }
            self.activeGalleryDownload = nil
            self.activeGalleryDownloadAssetID = nil
            self.galleryTransferToAsset.removeValue(forKey: transferId)
            self.galleryDownloadingAssetIDs.remove(item.id)
            self.galleryStatus = "사진 응답 시간이 초과되었습니다. 연결을 확인한 뒤 다시 시도하세요."
            self.startNextGalleryDownload()
        }
    }

    func sendMacClipboardToPhone() {
        guard isConnected else {
            actionMessage = "휴대폰을 연결한 뒤 다시 시도하세요."
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            actionMessage = "Mac 클립보드에 보낼 텍스트가 없습니다."
            return
        }
        guard text.utf8.count <= 20 * 1_024 else {
            actionMessage = "클립보드 텍스트는 20KB 이하만 보낼 수 있습니다."
            return
        }
        server.sendSecure(["kind": "clipboard_set", "text": text])
        actionMessage = "Mac 클립보드 텍스트를 휴대폰으로 보내는 중입니다."
    }

    func copyPhoneClipboardToMac() {
        guard let text = phoneClipboardText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        actionMessage = "휴대폰에서 받은 텍스트를 Mac 클립보드에 복사했습니다."
    }

    func selectAndSendFile(photosOnly: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if photosOnly { panel.allowedContentTypes = [.image] }
        panel.message = "Android 휴대폰으로 보낼 파일을 선택하세요."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        sendFiles(panel.urls)
    }

    func sendFiles(_ urls: [URL]) {
        guard isConnected else { actionMessage = "전송하려면 휴대폰을 연결하세요."; return }
        let newTransfers = urls.map { url in
            OutgoingTransfer(id: UUID().uuidString, name: url.lastPathComponent, sourceURL: url,
                size: 0, transferredBytes: 0, status: .queued, detail: "전송 차례를 기다립니다.")
        }
        outgoingTransfers.insert(contentsOf: newTransfers, at: 0)
        actionMessage = "파일 \(newTransfers.count)개를 전송 대기열에 추가했습니다."
        startNextOutgoingTransfer()
    }

    func retryFileTransfer(_ id: String) {
        guard let index = outgoingTransfers.firstIndex(where: { $0.id == id }),
              outgoingTransfers[index].status == .failed || outgoingTransfers[index].status == .paused else { return }
        outgoingTransfers[index].status = .queued
        outgoingTransfers[index].transferredBytes = 0
        outgoingTransfers[index].detail = "이어받기를 기다립니다."
        startNextOutgoingTransfer()
    }

    func cancelFileTransfer(_ id: String) {
        guard let transfer = outgoingTransfers.first(where: { $0.id == id }) else { return }
        if activeOutgoingTransferID == id || transfer.status == .queued || transfer.status == .paused {
            server.sendSecure(["kind": "file_cancel", "eventId": id])
        }
        if activeOutgoingTransferID == id {
            activeOutgoingTransferID = nil
            activeOutgoingTransferData = nil
        }
        updateOutgoingTransfer(id, status: .cancelled, detail: "전송을 취소했습니다.")
        recordDiagnostic("전송", "Mac에서 파일 전송을 취소했습니다.")
        startNextOutgoingTransfer()
    }

    func cancelIncomingFileTransfer(_ id: String) {
        guard let transfer = incomingTransferProgress.first(where: { $0.id == id }),
              transfer.status == "전송 중" || transfer.status == "이어받기 대기" else { return }
        server.sendSecure(["kind": "file_cancel", "eventId": id])
        if let resumable = resumableIncomingTransfers[id] {
            cancelResumableIncomingTransfer(id, notifyPeer: false)
            updateIncomingTransferProgress(resumable,
                bytes: min(resumable.size, Int64(resumable.nextIndex * 24 * 1_024)),
                status: "취소됨", detail: "받기를 취소했습니다.")
        } else {
            incomingTransfers.removeValue(forKey: id)
            incomingTransferProgress.removeAll { $0.id == id }
            incomingTransferProgress.insert(PhoneBridgeTransferProgress(id: id, name: transfer.name,
                direction: transfer.direction, totalBytes: transfer.totalBytes,
                transferredBytes: transfer.transferredBytes, status: "취소됨", detail: "받기를 취소했습니다."), at: 0)
        }
        recordDiagnostic("전송", "받는 파일 전송을 취소했습니다.")
    }

    private func startNextOutgoingTransfer() {
        guard isConnected, activeOutgoingTransferID == nil,
              let index = outgoingTransfers.firstIndex(where: { $0.status == .queued || $0.status == .paused }) else { return }
        let transfer = outgoingTransfers[index]
        activeOutgoingTransferID = transfer.id
        updateOutgoingTransfer(transfer.id, status: .preparing, detail: "파일을 확인하고 있습니다.")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hasScopedAccess = transfer.sourceURL.startAccessingSecurityScopedResource()
            defer { if hasScopedAccess { transfer.sourceURL.stopAccessingSecurityScopedResource() } }
            do {
                let fileSize = try transfer.sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard fileSize <= 100 * 1_024 * 1_024 else { throw TransferError.fileTooLarge }
                let data = try Data(contentsOf: transfer.sourceURL, options: .mappedIfSafe)
                guard data.count <= 100 * 1_024 * 1_024 else { throw TransferError.fileTooLarge }
                DispatchQueue.main.async {
                    guard let self, self.activeOutgoingTransferID == transfer.id else { return }
                    guard self.isConnected else {
                        self.updateOutgoingTransfer(transfer.id, status: .failed, detail: "휴대폰 연결이 끊겼습니다. 다시 시도할 수 있습니다.")
                        self.activeOutgoingTransferID = nil
                        return
                    }
                    self.updateOutgoingTransfer(transfer.id, status: .sending, size: Int64(data.count), detail: "휴대폰 저장을 기다리는 중입니다.")
                    self.activeOutgoingTransferData = data
                    self.activeOutgoingTransferChunkSize = 24 * 1_024
                    self.recordDiagnostic("전송", "Mac에서 휴대폰으로 파일 전송을 시작했습니다.")
                    if self.peerSupportsTransferControl {
                        let count = max(1, (data.count + self.activeOutgoingTransferChunkSize - 1) / self.activeOutgoingTransferChunkSize)
                        self.server.sendSecure([
                            "kind": "file_start",
                            "eventId": transfer.id,
                            "title": transfer.name,
                            "source": UTType(filenameExtension: transfer.sourceURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                            "size": data.count,
                            "transferCount": count,
                            "chunkSize": self.activeOutgoingTransferChunkSize,
                        ])
                    } else {
                        self.sendLegacyOutgoingTransfer(transferID: transfer.id)
                    }
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(300))
                        guard let self, self.activeOutgoingTransferID == transfer.id else { return }
                        self.updateOutgoingTransfer(transfer.id, status: .failed, detail: "휴대폰 응답이 없습니다. 연결을 확인하고 다시 시도하세요.")
                        self.activeOutgoingTransferID = nil
                        self.activeOutgoingTransferData = nil
                        self.startNextOutgoingTransfer()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateOutgoingTransfer(transfer.id, status: .failed, detail: error.localizedDescription)
                    if self.activeOutgoingTransferID == transfer.id { self.activeOutgoingTransferID = nil }
                    self.startNextOutgoingTransfer()
                }
            }
        }
    }

    private func updateOutgoingTransfer(_ id: String, status: OutgoingTransferStatus, size: Int64? = nil, transferredBytes: Int64? = nil, detail: String) {
        guard let index = outgoingTransfers.firstIndex(where: { $0.id == id }) else { return }
        outgoingTransfers[index].status = status
        outgoingTransfers[index].detail = detail
        if let size { outgoingTransfers[index].size = size }
        if let transferredBytes { outgoingTransfers[index].transferredBytes = transferredBytes }
        var keptHistory = 0
        outgoingTransfers = outgoingTransfers.filter { transfer in
            switch transfer.status {
            case .queued, .preparing, .sending:
                return true
            case .paused, .completed, .failed, .cancelled:
                guard keptHistory < 30 else { return false }
                keptHistory += 1
                return true
            }
        }
    }

    private func sendLegacyOutgoingTransfer(transferID: String) {
        guard activeOutgoingTransferID == transferID,
              let transfer = outgoingTransfers.first(where: { $0.id == transferID }),
              let data = activeOutgoingTransferData else { return }
        let chunkSize = activeOutgoingTransferChunkSize
        let count = max(1, (data.count + chunkSize - 1) / chunkSize)
        for index in 0..<count {
            guard activeOutgoingTransferID == transferID, isConnected else { return }
            let lower = index * chunkSize
            let upper = min(lower + chunkSize, data.count)
            server.sendSecure([
                "kind": "file_chunk", "eventId": transferID, "title": transfer.name,
                "source": UTType(filenameExtension: transfer.sourceURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                "transferIndex": index, "transferCount": count,
                "payload": data.subdata(in: lower..<upper).base64EncodedString(),
            ])
            if index.isMultiple(of: 8) || index == count - 1 {
                updateOutgoingTransfer(transferID, status: .sending, transferredBytes: Int64(upper), detail: "휴대폰으로 파일을 전송하고 있습니다.")
            }
        }
    }

    private func sendNextResumableChunk(transferID: String, nextIndex: Int) {
        guard activeOutgoingTransferID == transferID, let data = activeOutgoingTransferData,
              let transfer = outgoingTransfers.first(where: { $0.id == transferID }) else { return }
        let chunkSize = activeOutgoingTransferChunkSize
        let count = max(1, (data.count + chunkSize - 1) / chunkSize)
        guard nextIndex >= 0, nextIndex <= count else {
            finishOutgoingTransfer(transferID, success: false, detail: "휴대폰이 올바르지 않은 이어받기 위치를 보냈습니다.")
            return
        }
        let bytesSent = min(data.count, nextIndex * chunkSize)
        updateOutgoingTransfer(transferID, status: .sending, transferredBytes: Int64(bytesSent), detail: "휴대폰에 저장 중입니다.")
        guard nextIndex < count else { return }
        let lower = nextIndex * chunkSize
        let upper = min(lower + chunkSize, data.count)
        server.sendSecure([
            "kind": "file_chunk", "eventId": transferID, "title": transfer.name,
            "source": UTType(filenameExtension: transfer.sourceURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
            "transferIndex": nextIndex, "transferCount": count,
            "payload": data.subdata(in: lower..<upper).base64EncodedString(),
        ])
    }

    private func finishOutgoingTransfer(_ id: String, success: Bool, detail: String) {
        let size = outgoingTransfers.first(where: { $0.id == id })?.size
        updateOutgoingTransfer(id, status: success ? .completed : .failed,
                               transferredBytes: success ? size : nil, detail: detail)
        recordDiagnostic("전송", success ? "Mac에서 휴대폰으로 파일 전송이 완료되었습니다." : "Mac에서 휴대폰으로 파일 전송이 실패했습니다.")
        if activeOutgoingTransferID == id {
            activeOutgoingTransferID = nil
            activeOutgoingTransferData = nil
        }
        startNextOutgoingTransfer()
    }

    func saveReceivedFile(_ file: ReceivedFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        if let type = UTType(mimeType: file.contentType) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try file.data.write(to: url, options: .atomic)
            actionMessage = "파일을 저장했습니다."
        } catch {
            actionMessage = "파일을 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func exportEvents() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PhoneBridge-events.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? JSONEncoder().encode(events) else { return }
        do {
            try data.write(to: url, options: .atomic)
            actionMessage = "최근 활동을 JSON 파일로 내보냈습니다."
        } catch {
            actionMessage = "최근 활동을 내보내지 못했습니다: \(error.localizedDescription)"
        }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PhoneBridge-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = PhoneBridgeDiagnosticReport(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            connected: isConnected,
            entries: diagnostics,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(report).write(to: url, options: .atomic)
            actionMessage = "진단 기록을 저장했습니다. 알림 내용, 전화번호, 파일 이름은 포함되지 않습니다."
        } catch {
            actionMessage = "진단 기록을 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func recordDiagnostic(_ category: String, _ detail: String) {
        diagnostics.insert(PhoneBridgeDiagnosticEntry(id: UUID(), timestamp: Date(), category: category, detail: detail), at: 0)
        diagnostics = Array(diagnostics.prefix(200))
    }

    private func receive(_ event: PhoneEvent) {
        if event.kind == "remote_control_status" {
            remoteControlEnabled = event.success == true
            return
        }
        if event.kind == "gallery_item" {
            guard let id = event.eventId else { return }
            let item = PhoneGalleryItem(
                id: id,
                name: event.title ?? "사진",
                contentType: event.source ?? "image/*",
                size: event.size ?? 0,
                dateAdded: event.timestamp.map { Date(timeIntervalSince1970: $0) },
                thumbnailData: event.payload.flatMap { Data(base64Encoded: $0) },
            )
            if let existing = galleryItems.firstIndex(where: { $0.id == id }) {
                galleryItems[existing] = item
            } else {
                galleryItems.append(item)
            }
            return
        }
        if event.kind == "gallery_result" {
            galleryIsLoading = false
            galleryHasMore = event.hasMore == true
            galleryStatus = event.text ?? (event.success == true ? "휴대폰 사진을 불러왔습니다." : "Android 사진 권한을 확인하세요.")
            return
        }
        if event.kind == "gallery_download_result" {
            galleryStatus = event.text ?? "사진 전송 상태를 확인하세요."
            if event.success != true, let transferId = event.eventId {
                if let assetId = galleryTransferToAsset.removeValue(forKey: transferId) {
                    galleryDownloadingAssetIDs.remove(assetId)
                }
                if activeGalleryDownload?.transferID == transferId {
                    activeGalleryDownload = nil
                    activeGalleryDownloadAssetID = nil
                }
                startNextGalleryDownload()
            }
            return
        }
        if event.kind == "remote_control_result" {
            actionMessage = event.text
            return
        }
        if event.kind == "screen_frame" {
            if let encoded = event.payload, let data = Data(base64Encoded: encoded) {
                screenFrame = NSImage(data: data)
            }
            return
        }
        if event.kind == "screen_share_stopped" {
            screenFrame = nil
            actionMessage = "Android 화면 공유가 중지되었습니다."
            return
        }
        if event.kind == "clipboard_text" {
            guard let text = event.text, text.utf8.count <= 20 * 1_024 else { return }
            phoneClipboardText = text
            actionMessage = "휴대폰 클립보드 텍스트를 받았습니다. 복사 버튼을 누르면 Mac 클립보드에 저장됩니다."
            return
        }
        if event.kind == "file_start" {
            beginResumableIncomingTransfer(event)
            return
        }
        if event.kind == "file_cancel" {
            cancelResumableIncomingTransfer(event.eventId ?? "", notifyPeer: true)
            return
        }
        if event.kind == "file_transfer_ready" {
            guard let transferID = event.eventId, transferID == activeOutgoingTransferID else { return }
            guard event.success != false else {
                finishOutgoingTransfer(transferID, success: false, detail: event.text ?? "휴대폰이 전송을 준비하지 못했습니다.")
                return
            }
            sendNextResumableChunk(transferID: transferID, nextIndex: event.nextIndex ?? 0)
            return
        }
        if event.kind == "file_chunk_ack" {
            guard let transferID = event.eventId, transferID == activeOutgoingTransferID else { return }
            guard event.success != false else {
                finishOutgoingTransfer(transferID, success: false, detail: event.text ?? "휴대폰에 파일 조각을 저장하지 못했습니다.")
                return
            }
            sendNextResumableChunk(transferID: transferID, nextIndex: event.nextIndex ?? 0)
            return
        }
        if event.kind == "file_cancelled" {
            if let transferID = event.eventId,
               let current = outgoingTransfers.first(where: { $0.id == transferID }),
               current.status != .completed, current.status != .cancelled {
                updateOutgoingTransfer(transferID, status: .cancelled, detail: "휴대폰에서 전송을 취소했습니다.")
                if activeOutgoingTransferID == transferID {
                    activeOutgoingTransferID = nil
                    activeOutgoingTransferData = nil
                }
                startNextOutgoingTransfer()
            }
            return
        }
        if event.kind == "file_chunk" {
            if event.eventId.map({ resumableIncomingTransfers[$0] != nil }) == true {
                receiveResumableFileChunk(event)
            } else {
            receiveFileChunk(event)
            }
            return
        }
        if event.kind == "file_received" {
            guard let transferID = event.eventId ?? activeOutgoingTransferID,
                  outgoingTransfers.contains(where: { $0.id == transferID }) else {
                actionMessage = event.success == false ? (event.text ?? "휴대폰에 파일을 저장하지 못했습니다.") : "Android 휴대폰에 \(event.title ?? "파일")을(를) 저장했습니다."
                return
            }
            if event.success != false {
                finishOutgoingTransfer(transferID, success: true, detail: "휴대폰에 안전하게 저장했습니다.")
                actionMessage = "Android 휴대폰에 \(event.title ?? "파일")을(를) 저장했습니다."
            } else {
                finishOutgoingTransfer(transferID, success: false, detail: event.text ?? "휴대폰에 저장하지 못했습니다.")
                actionMessage = event.text ?? "휴대폰에 파일을 저장하지 못했습니다."
            }
            return
        }
        if event.kind == "dismiss_notification_result" {
            if event.success == true, let eventId = event.eventId {
                events.removeAll { $0.eventId == eventId }
            }
            actionMessage = event.text
            return
        }
        if event.kind.hasSuffix("_result") {
            actionMessage = event.text
            return
        }
        events.removeAll { $0.id == event.id }
        events.insert(event, at: 0)
        events = Array(events.prefix(100))
        switch event.kind {
        case "battery":
            battery = event.battery
        case "call_state":
            callState = event.callState == "ringing" ? "전화가 오고 있습니다" :
                event.callState == "offhook" ? "통화 중" : "통화 중이 아닙니다"
        case "notification", "message", "call_notification":
            showMacNotification(event)
        default:
            break
        }
    }

    private func incomingTransferDirectory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PhoneBridge/TransferParts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func incomingTransferURLs(id: String) throws -> (part: URL, manifest: URL) {
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = try incomingTransferDirectory()
        return (directory.appendingPathComponent("\(digest).part"), directory.appendingPathComponent("\(digest).json"))
    }

    private func restoreCompletedIncomingTransfers() {
        guard let directory = try? incomingTransferDirectory(),
              let manifests = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let completed = manifests.filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        var retainedBytes = 0
        for manifestURL in completed {
            guard let transfer = try? JSONDecoder().decode(ResumableIncomingTransfer.self, from: Data(contentsOf: manifestURL)),
                  transfer.completed == true,
                  let urls = try? incomingTransferURLs(id: transfer.id),
                  let values = try? urls.part.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = values.fileSize, Int64(fileSize) == transfer.size,
                  retainedBytes + fileSize <= 128 * 1_024 * 1_024,
                  let data = try? Data(contentsOf: urls.part, options: .mappedIfSafe) else { continue }
            retainedBytes += data.count
            receivedFiles.append(ReceivedFile(id: transfer.id, name: transfer.name, contentType: transfer.contentType,
                                              data: data, receivedAt: (try? urls.part.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()))
            incomingTransferProgress.append(PhoneBridgeTransferProgress(id: transfer.id, name: transfer.name,
                direction: "휴대폰 → Mac", totalBytes: transfer.size, transferredBytes: transfer.size,
                status: "완료", detail: "Mac에 안전하게 저장했습니다."))
        }
        incomingTransferProgress = Array(incomingTransferProgress.prefix(20))
    }

    private func cleanTransferStorage() {
        guard let directory = try? incomingTransferDirectory(),
              let manifests = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let ordered = manifests.filter { $0.pathExtension == "json" }.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        let now = Date()
        let completedExpiry = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let incompleteExpiry = now.addingTimeInterval(-7 * 24 * 60 * 60)
        var retainedCompletedBytes = 0
        for manifestURL in ordered {
            guard let transfer = try? JSONDecoder().decode(ResumableIncomingTransfer.self, from: Data(contentsOf: manifestURL)),
                  let urls = try? incomingTransferURLs(id: transfer.id) else {
                try? FileManager.default.removeItem(at: manifestURL)
                continue
            }
            let modifiedAt = (try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if transfer.completed == true {
                let fileSize = (try? urls.part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if modifiedAt < completedExpiry || retainedCompletedBytes + fileSize > 128 * 1_024 * 1_024 {
                    try? FileManager.default.removeItem(at: urls.part)
                    try? FileManager.default.removeItem(at: manifestURL)
                } else {
                    retainedCompletedBytes += fileSize
                }
            } else if modifiedAt < incompleteExpiry {
                try? FileManager.default.removeItem(at: urls.part)
                try? FileManager.default.removeItem(at: manifestURL)
            }
        }
    }

    private func saveIncomingTransferManifest(_ transfer: ResumableIncomingTransfer, to url: URL) throws {
        let encoder = JSONEncoder()
        try encoder.encode(transfer).write(to: url, options: .atomic)
    }

    private func beginResumableIncomingTransfer(_ event: PhoneEvent) {
        guard let id = event.eventId, !id.isEmpty, let size = event.size,
              let count = event.transferCount, size >= 0, size <= 100 * 1_024 * 1_024,
              count > 0, count <= 5_000 else {
            if let id = event.eventId { server.sendSecure(["kind": "file_transfer_ready", "eventId": id, "success": false, "text": "파일 정보가 올바르지 않습니다."]) }
            return
        }
        let chunkSize = 24 * 1_024
        let expectedCount = max(1, (Int(size) + chunkSize - 1) / chunkSize)
        guard count == expectedCount else {
            server.sendSecure(["kind": "file_transfer_ready", "eventId": id, "success": false, "text": "파일 조각 정보가 올바르지 않습니다."])
            return
        }
        do {
            let urls = try incomingTransferURLs(id: id)
            let name = URL(fileURLWithPath: event.title ?? "PhoneBridge-file").lastPathComponent
            let contentType = event.source ?? "application/octet-stream"
            var transfer: ResumableIncomingTransfer
            if let stored = try? JSONDecoder().decode(ResumableIncomingTransfer.self, from: Data(contentsOf: urls.manifest)),
               stored.id == id, stored.name == name, stored.contentType == contentType,
               stored.size == size, stored.count == count, FileManager.default.fileExists(atPath: urls.part.path) {
                transfer = stored
                transfer.partPath = urls.part.path
            } else {
                try? FileManager.default.removeItem(at: urls.part)
                try? FileManager.default.removeItem(at: urls.manifest)
                FileManager.default.createFile(atPath: urls.part.path, contents: nil)
                let file = try FileHandle(forWritingTo: urls.part)
                try file.truncate(atOffset: UInt64(size))
                try file.close()
                transfer = ResumableIncomingTransfer(id: id, name: name, contentType: contentType, size: size,
                                                     count: count, nextIndex: 0, partPath: urls.part.path)
                try saveIncomingTransferManifest(transfer, to: urls.manifest)
            }
            if transfer.completed != true && transfer.nextIndex >= transfer.count {
                transfer.nextIndex = max(0, transfer.count - 1)
                try saveIncomingTransferManifest(transfer, to: urls.manifest)
            }
            resumableIncomingTransfers[id] = transfer
            if transfer.completed == true {
                updateIncomingTransferProgress(transfer, bytes: transfer.size, status: "완료", detail: "Mac에 안전하게 저장했습니다.")
                server.sendSecure(["kind": "file_transfer_ready", "eventId": id, "success": true,
                                   "nextIndex": transfer.count, "size": transfer.size])
                server.sendSecure(["kind": "file_received", "eventId": id, "title": transfer.name,
                                   "success": true, "size": transfer.size])
                return
            }
            let receivedBytes = min(size, Int64(transfer.nextIndex * chunkSize))
            updateIncomingTransferProgress(transfer, bytes: receivedBytes, status: "전송 중", detail: transfer.nextIndex > 0 ? "중단된 전송을 이어받습니다." : "휴대폰에서 받는 중입니다.")
            recordDiagnostic("전송", transfer.nextIndex > 0 ? "중단된 파일 전송을 이어받습니다." : "휴대폰에서 파일 받기를 시작했습니다.")
            server.sendSecure(["kind": "file_transfer_ready", "eventId": id, "success": true,
                               "nextIndex": transfer.nextIndex, "size": receivedBytes])
        } catch {
            server.sendSecure(["kind": "file_transfer_ready", "eventId": id, "success": false,
                               "text": "Mac에 파일을 저장할 공간이 부족하거나 파일을 만들 수 없습니다."])
            recordDiagnostic("전송", "받는 파일의 임시 저장 공간을 준비하지 못했습니다.")
        }
    }

    private func updateIncomingTransferProgress(_ transfer: ResumableIncomingTransfer, bytes: Int64, status: String, detail: String) {
        incomingTransferProgress.removeAll { $0.id == transfer.id }
        incomingTransferProgress.insert(PhoneBridgeTransferProgress(id: transfer.id, name: transfer.name,
            direction: "휴대폰 → Mac", totalBytes: transfer.size, transferredBytes: bytes, status: status, detail: detail), at: 0)
        incomingTransferProgress = Array(incomingTransferProgress.prefix(20))
    }

    private func receiveResumableFileChunk(_ event: PhoneEvent) {
        guard let id = event.eventId, var transfer = resumableIncomingTransfers[id],
              let index = event.transferIndex, event.transferCount == transfer.count,
              let payload = event.payload,
              let bytes = Data(base64Encoded: payload), bytes.count <= 24 * 1_024,
              index >= 0, index < transfer.count else { return }
        if transfer.completed == true {
            server.sendSecure(["kind": "file_chunk_ack", "eventId": id, "transferIndex": index,
                               "nextIndex": transfer.count, "size": transfer.size])
            server.sendSecure(["kind": "file_received", "eventId": id, "title": transfer.name,
                               "success": true, "size": transfer.size])
            return
        }
        if index != transfer.nextIndex {
            let receivedBytes = min(transfer.size, Int64(transfer.nextIndex * 24 * 1_024))
            server.sendSecure(["kind": "file_chunk_ack", "eventId": id, "transferIndex": index,
                               "nextIndex": transfer.nextIndex, "size": receivedBytes])
            return
        }
        let expectedBytes = min(Int64(24 * 1_024), transfer.size - Int64(index * 24 * 1_024))
        guard Int64(bytes.count) == expectedBytes else {
            server.sendSecure(["kind": "file_chunk_ack", "eventId": id, "success": false,
                               "text": "받은 파일 조각의 크기가 올바르지 않습니다."])
            return
        }
        do {
            let partURL = URL(fileURLWithPath: transfer.partPath)
            let file = try FileHandle(forWritingTo: partURL)
            try file.seek(toOffset: UInt64(index * 24 * 1_024))
            try file.write(contentsOf: bytes)
            try file.close()
            transfer.nextIndex += 1
            resumableIncomingTransfers[id] = transfer
            let urls = try incomingTransferURLs(id: id)
            try saveIncomingTransferManifest(transfer, to: urls.manifest)
            let receivedBytes = min(transfer.size, Int64(transfer.nextIndex * 24 * 1_024))
            updateIncomingTransferProgress(transfer, bytes: receivedBytes, status: "전송 중", detail: "파일을 안전하게 저장하고 있습니다.")
            server.sendSecure(["kind": "file_chunk_ack", "eventId": id, "transferIndex": index,
                               "nextIndex": transfer.nextIndex, "size": receivedBytes])
            guard transfer.nextIndex == transfer.count else { return }
            let data = try Data(contentsOf: partURL, options: .mappedIfSafe)
            receivedFiles.insert(ReceivedFile(id: id, name: transfer.name, contentType: transfer.contentType,
                                              data: data, receivedAt: Date()), at: 0)
            var retainedBytes = 0
            receivedFiles = receivedFiles.filter { file in
                guard retainedBytes + file.data.count <= 128 * 1_024 * 1_024 else { return false }
                retainedBytes += file.data.count
                return true
            }
            transfer.completed = true
            try saveIncomingTransferManifest(transfer, to: urls.manifest)
            resumableIncomingTransfers[id] = transfer
            updateIncomingTransferProgress(transfer, bytes: transfer.size, status: "완료", detail: "Mac에 안전하게 저장했습니다.")
            actionMessage = "휴대폰에서 \(transfer.name)을(를) 받았습니다."
            cleanTransferStorage()
            server.sendSecure(["kind": "file_received", "eventId": id, "title": transfer.name,
                               "success": true, "size": transfer.size])
            recordDiagnostic("전송", "휴대폰에서 받은 파일을 저장했습니다.")
        } catch {
            server.sendSecure(["kind": "file_chunk_ack", "eventId": id, "success": false,
                               "text": "Mac에 파일을 저장하지 못했습니다. 저장 공간을 확인하세요."])
            updateIncomingTransferProgress(transfer, bytes: Int64(transfer.nextIndex * 24 * 1_024), status: "실패", detail: "Mac에 파일을 저장하지 못했습니다.")
            recordDiagnostic("전송", "받는 파일을 저장하지 못했습니다.")
        }
    }

    private func cancelResumableIncomingTransfer(_ id: String, notifyPeer: Bool) {
        guard !id.isEmpty else { return }
        if let completed = resumableIncomingTransfers[id], completed.completed == true {
            if notifyPeer {
                server.sendSecure(["kind": "file_received", "eventId": id, "title": completed.name,
                                   "success": true, "size": completed.size])
            }
            return
        }
        if let transfer = resumableIncomingTransfers.removeValue(forKey: id),
           let urls = try? incomingTransferURLs(id: id) {
            try? FileManager.default.removeItem(at: urls.part)
            try? FileManager.default.removeItem(at: urls.manifest)
            updateIncomingTransferProgress(transfer, bytes: Int64(transfer.nextIndex * 24 * 1_024), status: "취소됨", detail: "전송을 취소했습니다.")
        }
        if notifyPeer { server.sendSecure(["kind": "file_cancelled", "eventId": id, "success": true]) }
        recordDiagnostic("전송", "받는 파일 전송을 취소했습니다.")
    }

    private func receiveFileChunk(_ event: PhoneEvent) {
        guard let transferId = event.eventId, let index = event.transferIndex,
              let count = event.transferCount, let payload = event.payload,
              let chunk = Data(base64Encoded: payload), count > 0, count <= 5_000, chunk.count <= 24 * 1_024,
              index >= 0, index < count else { return }
        var transfer = incomingTransfers[transferId] ?? IncomingTransfer(
            name: event.title ?? "PhoneBridge-file",
            contentType: event.source ?? "application/octet-stream",
            count: count
        )
        if incomingTransfers[transferId] == nil && incomingTransfers.count >= 4 { return }
        guard transfer.count == count else { incomingTransfers.removeValue(forKey: transferId); return }
        let previousChunk = transfer.chunks.updateValue(chunk, forKey: index)
        transfer.receivedBytes += chunk.count - (previousChunk?.count ?? 0)
        guard transfer.receivedBytes <= 100 * 1_024 * 1_024 else {
            incomingTransfers.removeValue(forKey: transferId)
            return
        }
        let totalPending = incomingTransfers.filter { $0.key != transferId }.values.reduce(0) { $0 + $1.receivedBytes } + transfer.receivedBytes
        guard totalPending <= 128 * 1_024 * 1_024 else {
            incomingTransfers.removeValue(forKey: transferId)
            return
        }
        incomingTransfers[transferId] = transfer
        incomingTransferProgress.removeAll { $0.id == transferId }
        incomingTransferProgress.insert(PhoneBridgeTransferProgress(
            id: transferId, name: transfer.name, direction: "휴대폰 → Mac", totalBytes: 0,
            transferredBytes: Int64(transfer.receivedBytes), status: "전송 중",
            detail: "파일 조각 \(transfer.chunks.count)/\(count)을 받았습니다."
        ), at: 0)
        incomingTransferProgress = Array(incomingTransferProgress.prefix(20))
        guard transfer.chunks.count == count else { return }
        let data = (0..<count).reduce(into: Data()) { result, part in
            if let bytes = transfer.chunks[part] { result.append(bytes) }
        }
        receivedFiles.insert(ReceivedFile(id: transferId, name: transfer.name, contentType: transfer.contentType, data: data, receivedAt: Date()), at: 0)
        var retainedBytes = 0
        receivedFiles = receivedFiles.filter { file in
            guard retainedBytes + file.data.count <= 128 * 1_024 * 1_024 else { return false }
            retainedBytes += file.data.count
            return true
        }
        incomingTransfers.removeValue(forKey: transferId)
        incomingTransferProgress.removeAll { $0.id == transferId }
        incomingTransferProgress.insert(PhoneBridgeTransferProgress(
            id: transferId, name: transfer.name, direction: "휴대폰 → Mac", totalBytes: Int64(data.count),
            transferredBytes: Int64(data.count), status: "완료", detail: "Mac에 안전하게 저장했습니다."
        ), at: 0)
        incomingTransferProgress = Array(incomingTransferProgress.prefix(20))
        actionMessage = "휴대폰에서 \(transfer.name)을(를) 받았습니다."
        if let assetId = galleryTransferToAsset.removeValue(forKey: transferId) {
            galleryDownloadingAssetIDs.remove(assetId)
            if activeGalleryDownload?.transferID == transferId { activeGalleryDownload = nil }
            if activeGalleryDownloadAssetID == assetId { activeGalleryDownloadAssetID = nil }
            galleryStatus = "사진을 받았습니다. 받은 항목에서 저장할 수 있습니다."
            startNextGalleryDownload()
        }
    }

    private func showMacNotification(_ event: PhoneEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title ?? event.source ?? "휴대폰 알림"
        content.body = event.text ?? "PhoneBridge에서 알림을 확인하세요."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

private enum TransferError: LocalizedError {
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: "파일은 100MB 이하만 전송할 수 있습니다."
        }
    }
}

private enum PairKeyStore {
    private static let service = "com.phonebridge.mac.pairing"
    private static let account = "android-device"

    static func load() -> PairedDevice? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(PairedDevice.self, from: data)
    }

    static func save(name: String, secret: Data) {
        guard let data = try? JSONEncoder().encode(PairedDevice(name: name, secret: secret)) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private enum SecureRandom {
    static func bytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

private enum NetworkAddress {
    static func localIPv4() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var addresses: [(String, String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if result == 0 {
                let interface = String(cString: item.pointee.ifa_name)
                addresses.append((interface, String(cString: host)))
            }
        }
        return addresses.sorted { lhs, rhs in
            let lhsPreferred = lhs.0 == "en0" || lhs.0.hasPrefix("en")
            let rhsPreferred = rhs.0 == "en0" || rhs.0.hasPrefix("en")
            return lhsPreferred && !rhsPreferred
        }.first?.1
    }
}

private enum QRCodeRenderer {
    static func make(from data: Data) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

// Mutable connection and pairing state is confined to `queue`; file sends enter
// the same queue through `sendSecure`, so callers may safely hand off the server.
private final class MacLinkServer: @unchecked Sendable {
    static let port: UInt16 = 51534
    private let queue = DispatchQueue(label: "com.phonebridge.mac.network")
    private var listener: NWListener?
    private var pendingSecret: Data?
    private var pendingSecretExpiresAt: Date?
    private var paired = PairKeyStore.load()
    private var activeConnection: NWConnection?
    private var activeSessionKey: SymmetricKey?
    private var listenerRestartTask: DispatchWorkItem?
    private var listenerRestartDelay: TimeInterval = 1
    var onStatus: ((String, Bool) -> Void)?
    var onPaired: ((String) -> Void)?
    var onEvent: ((PhoneEvent) -> Void)?
    var onCapabilities: ((Set<String>) -> Void)?

    func start() {
        queue.async { self.startListener() }
    }

    func setPendingSecret(_ secret: Data, expiresAt: Date) {
        queue.async {
            self.pendingSecret = secret
            self.pendingSecretExpiresAt = expiresAt
        }
    }

    func clearPairing() {
        queue.async {
            self.paired = nil
            self.pendingSecret = nil
            self.pendingSecretExpiresAt = nil
            self.activeConnection?.cancel()
            self.activeConnection = nil
            self.activeSessionKey = nil
        }
    }

    func sendSecure(_ object: [String: Any]) {
        queue.async {
            guard let connection = self.activeConnection, let key = self.activeSessionKey,
                  let clear = try? JSONSerialization.data(withJSONObject: object) else { return }
            let nonceData = SecureRandom.bytes(count: 12)
            guard let nonce = try? AES.GCM.Nonce(data: nonceData),
                  let box = try? AES.GCM.seal(clear, using: key, nonce: nonce),
                  let combined = box.combined else { return }
            self.send([
                "type": "secure",
                "nonce": nonceData.base64EncodedString(),
                "ciphertext": combined.base64EncodedString()
            ], over: connection)
        }
    }

    func sendFile(name: String, contentType: String, data: Data, transferId: String) {
        guard data.count <= 100 * 1_024 * 1_024 else { return }
        let chunkSize = 24 * 1_024
        let count = max(1, Int(ceil(Double(data.count) / Double(chunkSize))))
        for index in 0..<count {
            let lower = min(index * chunkSize, data.count)
            let upper = min(lower + chunkSize, data.count)
            let chunk = data.subdata(in: lower..<upper)
            sendSecure([
                "kind": "file_chunk",
                "eventId": transferId,
                "title": name,
                "source": contentType,
                "transferIndex": index,
                "transferCount": count,
                "payload": chunk.base64EncodedString()
            ])
        }
    }

    func expirePendingSecret() {
        queue.async {
            self.pendingSecret = nil
            self.pendingSecretExpiresAt = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed(let error):
                self.connectionEnded(connection, status: "휴대폰 연결이 끊겼습니다 · 다시 연결을 기다리는 중")
                NSLog("PhoneBridge connection failed: %@", error.localizedDescription)
            case .cancelled:
                self.connectionEnded(connection, status: "휴대폰 연결이 끊겼습니다 · 다시 연결을 기다리는 중")
            default:
                break
            }
        }
        connection.start(queue: queue)
        let challenge = SecureRandom.bytes(count: 32)
        let challengeText = challenge.base64EncodedString()
        send(["type": "challenge", "nonce": challengeText], over: connection)
        receiveLine(from: connection, buffer: Data()) { [weak self] data, remainder in
            guard let self, let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "auth",
                  let name = object["name"] as? String,
                  let proofText = object["proof"] as? String,
                  let receivedProof = Data(base64Encoded: proofText) else {
                connection.cancel()
                return
            }
            let capabilities = Set((object["capabilities"] as? [String]) ?? [])
            self.onCapabilities?(capabilities)
            let unexpiredPending = self.pendingSecretExpiresAt.map { $0 > Date() } == true ? self.pendingSecret : nil
            let key = unexpiredPending ?? self.paired?.secret
            guard let key else { connection.cancel(); return }
            let expected = Self.hmac(key: key, text: "auth|\(challengeText)|\(name)")
            guard Self.constantTimeEqual(expected, receivedProof) else {
                connection.cancel()
                return
            }
            let wasUnpaired = self.paired == nil
            if wasUnpaired {
                self.paired = PairedDevice(name: name, secret: key)
                PairKeyStore.save(name: name, secret: key)
                self.pendingSecret = nil
                self.pendingSecretExpiresAt = nil
                DispatchQueue.main.async { self.onPaired?(name) }
            }
            let responseProof = Self.hmac(key: key, text: "welcome|\(challengeText)|\(name)")
            self.send([
                "type": "welcome",
                "proof": responseProof.base64EncodedString(),
                "capabilities": ["heartbeat-v1", "transfer-control-v1"]
            ], over: connection)
            if let previous = self.activeConnection, previous !== connection {
                previous.cancel()
            }
            self.activeConnection = connection
            let sessionKey = Self.sessionKey(secret: key, challenge: challenge)
            self.activeSessionKey = sessionKey
            self.onStatus?("\(name) 연결됨", true)
            self.readSecureEvents(from: connection, buffer: remainder, key: sessionKey, deviceName: name)
        }
    }

    private func readSecureEvents(from connection: NWConnection, buffer: Data, key: SymmetricKey, deviceName: String) {
        receiveLine(from: connection, buffer: buffer) { [weak self] data, remainder in
            guard let self, let data,
                  let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  wrapper["type"] as? String == "secure",
                  let nonceText = wrapper["nonce"] as? String,
                  let nonceData = Data(base64Encoded: nonceText),
                  let combined = Data(base64Encoded: wrapper["ciphertext"] as? String ?? ""),
                  combined.count >= 16 else {
                self?.connectionEnded(connection, status: "휴대폰 메시지를 읽지 못했습니다 · 다시 연결을 기다리는 중")
                return
            }
            do {
                let nonce = try AES.GCM.Nonce(data: nonceData)
                let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: combined.dropLast(16), tag: combined.suffix(16))
                let clear = try AES.GCM.open(box, using: key)
                let event = try JSONDecoder().decode(PhoneEvent.self, from: clear)
                if event.kind == "heartbeat_ping" {
                    self.sendSecure(["kind": "heartbeat_pong", "timestamp": Date().timeIntervalSince1970])
                } else if event.kind != "heartbeat_pong" {
                    DispatchQueue.main.async { self.onEvent?(event) }
                }
                self.readSecureEvents(from: connection, buffer: remainder, key: key, deviceName: deviceName)
            } catch {
                self.connectionEnded(connection, status: "암호화된 메시지를 확인하지 못했습니다 · 다시 연결을 기다리는 중")
            }
        }
    }

    private func connectionEnded(_ connection: NWConnection, status: String) {
        connection.cancel()
        guard activeConnection === connection else { return }
        activeConnection = nil
        activeSessionKey = nil
        onStatus?(status, false)
    }

    private func startListener() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.service = NWListener.Service(name: "PhoneBridge-Mac", type: "_phonebridge._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listenerRestartDelay = 1
                    self.listenerRestartTask?.cancel()
                    self.listenerRestartTask = nil
                    if self.activeConnection == nil {
                        self.onStatus?("같은 Wi‑Fi에 있는 Android 휴대폰을 찾는 중", false)
                    }
                case .failed(let error):
                    self.listener = nil
                    if self.activeConnection == nil {
                        self.onStatus?("로컬 연결을 복구하는 중…", false)
                    }
                    NSLog("PhoneBridge listener failed: %@", error.localizedDescription)
                    self.scheduleListenerRestart()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            listener = nil
            onStatus?("로컬 연결을 복구하는 중…", false)
            NSLog("PhoneBridge listener could not start: %@", error.localizedDescription)
            scheduleListenerRestart()
        }
    }

    private func scheduleListenerRestart() {
        guard listenerRestartTask == nil else { return }
        let delay = listenerRestartDelay
        listenerRestartDelay = min(listenerRestartDelay * 2, 30)
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.listenerRestartTask = nil
            self.startListener()
        }
        listenerRestartTask = task
        queue.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func receiveLine(from connection: NWConnection, buffer: Data, completion: @escaping (Data?, Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            guard error == nil else { completion(nil, Data()); return }
            var next = buffer
            if let data { next.append(data) }
            if let newline = next.firstIndex(of: 10) {
                let remainder = Data(next[next.index(after: newline)...])
                completion(Data(next[..<newline]), remainder)
                return
            }
            if complete { completion(nil, Data()); return }
            self.receiveLine(from: connection, buffer: next, completion: completion)
        }
    }

    private func send(_ object: [String: Any], over connection: NWConnection) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private static func hmac(key: Data, text: String) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key))
        return Data(code)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    private static func sessionKey(secret: Data, challenge: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: challenge,
            info: Data("PhoneBridge/aes-gcm/v1".utf8),
            outputByteCount: 32
        )
    }
}
