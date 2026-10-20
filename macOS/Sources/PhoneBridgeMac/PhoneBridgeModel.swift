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
    let payload: String?
    let actions: [PhoneEventAction]?
    let success: Bool?
    let size: Int64?
    let pageOffset: Int?
    let hasMore: Bool?

    var id: String { eventId ?? "\(kind)-\(timestamp ?? 0)-\(title ?? "")" }

    enum CodingKeys: String, CodingKey {
        case eventId, kind, title, text, source, battery, callState, timestamp
        case canReply, transferIndex, transferCount, payload, actions, success, size, pageOffset, hasMore
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
    case completed
    case failed

    var title: String {
        switch self {
        case .queued: "대기 중"
        case .preparing: "준비 중"
        case .sending: "전송 중"
        case .completed: "휴대폰에 저장됨"
        case .failed: "전송 실패"
        }
    }
}

struct OutgoingTransfer: Identifiable {
    let id: String
    let name: String
    let sourceURL: URL
    var size: Int64
    var status: OutgoingTransferStatus
    var detail: String
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
    private var galleryDownloadQueue: [PhoneGalleryItem] = []
    private var activeGalleryDownload: (transferID: String, item: PhoneGalleryItem)?
    private var galleryTransferToAsset: [String: String] = [:]
    private var activeOutgoingTransferID: String?

    init() {
        let paired = PairKeyStore.load()
        isPaired = paired != nil
        deviceName = paired?.name
        localAddress = NetworkAddress.localIPv4() ?? ""
        server.onStatus = { [weak self] status, connected in
            Task { @MainActor in
                self?.status = status
                self?.isConnected = connected
                if !connected {
                    self?.screenFrame = nil
                    self?.galleryIsLoading = false
                    self?.incomingTransfers.removeAll()
                    if let active = self?.activeGalleryDownload {
                        self?.galleryDownloadQueue.insert(active.item, at: 0)
                        self?.activeGalleryDownload = nil
                        self?.activeGalleryDownloadAssetID = nil
                        self?.galleryTransferToAsset.removeAll()
                        self?.galleryStatus = "연결이 끊겨 사진 전송을 대기 중입니다. 다시 연결되면 이어집니다."
                    }
                    if let transferID = self?.activeOutgoingTransferID {
                        self?.updateOutgoingTransfer(transferID, status: .failed, detail: "연결이 끊겨 완료 여부를 확인하지 못했습니다.")
                        self?.activeOutgoingTransferID = nil
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
        server.start()
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
        server.sendSecure(["kind": "gallery_list", "offset": offset, "limit": 40])
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
                size: 0, status: .queued, detail: "전송 차례를 기다립니다.")
        }
        outgoingTransfers.insert(contentsOf: newTransfers, at: 0)
        actionMessage = "파일 \(newTransfers.count)개를 전송 대기열에 추가했습니다."
        startNextOutgoingTransfer()
    }

    func retryFileTransfer(_ id: String) {
        guard let transfer = outgoingTransfers.first(where: { $0.id == id }), transfer.status == .failed else { return }
        sendFiles([transfer.sourceURL])
    }

    private func startNextOutgoingTransfer() {
        guard isConnected, activeOutgoingTransferID == nil,
              let index = outgoingTransfers.firstIndex(where: { $0.status == .queued }) else { return }
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
                    self.server.sendFile(
                        name: transfer.name,
                        contentType: UTType(filenameExtension: transfer.sourceURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                        data: data,
                        transferId: transfer.id,
                    )
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(300))
                        guard let self, self.activeOutgoingTransferID == transfer.id else { return }
                        self.updateOutgoingTransfer(transfer.id, status: .failed, detail: "휴대폰 응답이 없습니다. 연결을 확인하고 다시 시도하세요.")
                        self.activeOutgoingTransferID = nil
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

    private func updateOutgoingTransfer(_ id: String, status: OutgoingTransferStatus, size: Int64? = nil, detail: String) {
        guard let index = outgoingTransfers.firstIndex(where: { $0.id == id }) else { return }
        outgoingTransfers[index].status = status
        outgoingTransfers[index].detail = detail
        if let size { outgoingTransfers[index].size = size }
        var keptHistory = 0
        outgoingTransfers = outgoingTransfers.filter { transfer in
            switch transfer.status {
            case .queued, .preparing, .sending:
                return true
            case .completed, .failed:
                guard keptHistory < 30 else { return false }
                keptHistory += 1
                return true
            }
        }
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
        if event.kind == "file_chunk" {
            receiveFileChunk(event)
            return
        }
        if event.kind == "file_received" {
            guard let transferID = event.eventId ?? activeOutgoingTransferID,
                  outgoingTransfers.contains(where: { $0.id == transferID }) else {
                actionMessage = event.success == false ? (event.text ?? "휴대폰에 파일을 저장하지 못했습니다.") : "Android 휴대폰에 \(event.title ?? "파일")을(를) 저장했습니다."
                return
            }
            if event.success != false {
                updateOutgoingTransfer(transferID, status: .completed, detail: "휴대폰에 안전하게 저장했습니다.")
                actionMessage = "Android 휴대폰에 \(event.title ?? "파일")을(를) 저장했습니다."
            } else {
                updateOutgoingTransfer(transferID, status: .failed, detail: event.text ?? "휴대폰에 저장하지 못했습니다.")
                actionMessage = event.text ?? "휴대폰에 파일을 저장하지 못했습니다."
            }
            if activeOutgoingTransferID == transferID { activeOutgoingTransferID = nil }
            startNextOutgoingTransfer()
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
                "capabilities": ["heartbeat-v1"]
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
