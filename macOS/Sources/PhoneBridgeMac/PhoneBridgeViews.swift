import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

private let sections = ["개요", "알림", "메시지", "통화", "사진", "갤러리", "파일", "미디어", "폰 화면", "클립보드", "설정"]

struct PhoneBridgeRootView: View {
    @EnvironmentObject private var model: PhoneBridgeModel

    var body: some View {
        ZStack {
            PhoneBridgeAmbientBackdrop()
            HStack(alignment: .top, spacing: 14) {
                sidebar
                VStack(spacing: 12) {
                    AppControlBar()
                    Group {
                        switch model.selectedSection {
                        case "개요": OverviewView()
                        case "알림": EventListView(title: "알림", filter: "notification")
                        case "메시지": MessagesView()
                        case "통화": CallsView()
                        case "사진": FileTransferView(photosOnly: true)
                        case "갤러리": PhoneGalleryView()
                        case "파일": FileTransferView(photosOnly: false)
                        case "미디어": MediaControlsView()
                        case "폰 화면": ScreenIntegrationView()
                        case "클립보드": ClipboardView()
                        default: SettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 0)
                    .animation(.spring(response: 0.24, dampingFraction: 0.88), value: model.selectedSection)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(14)
        }
        .frame(minWidth: 1080, minHeight: 700)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("PhoneBridge").font(.headline)
                    Text("휴대폰 연동").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 17)
            .padding(.top, 14)
            .padding(.bottom, 18)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SidebarGroup(title: "휴대폰", items: Array(sections.prefix(4)))
                    SidebarGroup(title: "공유", items: Array(sections.dropFirst(4).dropLast()))
                    SidebarGroup(title: "앱", items: ["설정"])
                }
                .padding(.horizontal, 9)
            }
            .frame(maxHeight: .infinity)

            Divider().padding(.horizontal, 12).padding(.top, 9)
            HStack(spacing: 10) {
                Circle().fill(model.isConnected ? Color.green : Color.orange).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.deviceName ?? "연결된 휴대폰 없음").font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(model.isConnected ? "연결됨 · 같은 Wi‑Fi" : "같은 Wi‑Fi에서 대기 중")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
        }
        .frame(width: 222)
        .padding(8)
        .frame(maxHeight: .infinity)
        .phoneBridgeGlassSurface(cornerRadius: 25)
    }
}

private struct SidebarGroup: View {
    let title: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 3)
            ForEach(items, id: \.self) { item in
                SidebarNavigationRow(title: item, icon: icon(for: item))
            }
        }
    }

    private func icon(for section: String) -> String {
        switch section {
        case "개요": "square.grid.2x2.fill"
        case "알림": "bell"
        case "메시지": "message"
        case "통화": "phone"
        case "사진": "photo.on.rectangle.angled"
        case "갤러리": "photo.stack"
        case "파일": "folder"
        case "미디어": "playpause.fill"
        case "폰 화면": "macbook.and.iphone"
        case "클립보드": "doc.on.clipboard"
        default: "gearshape"
        }
    }
}

private struct SidebarNavigationRow: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var local = PhoneBridgeViewState()
    let title: String
    let icon: String

    private var badgeCount: Int {
        let kind: String
        switch title {
        case "알림": kind = "notification"
        case "메시지": kind = "message"
        case "통화": kind = "call_notification"
        default: return 0
        }
        return model.events.filter { $0.kind == kind }.count
    }

    var body: some View {
        let selected = model.selectedSection == title
        Button {
            model.selectSection(title)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .frame(width: 19)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if badgeCount > 0 {
                    Text(badgeCount > 99 ? "99+" : "\(badgeCount)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.primary.opacity(selected ? 0.06 : 0.045), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.13) : (local.isHovered ? Color.primary.opacity(0.045) : .clear))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(local.isHovered && !reduceMotion ? 1.012 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.76), value: local.isHovered)
        .onHover { local.isHovered = $0 }
        .accessibilityLabel(badgeCount > 0 ? "\(title), \(badgeCount)개" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AppControlBar: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    @EnvironmentObject private var updater: PhoneBridgeUpdater

    var body: some View {
        HStack(spacing: 10) {
            Label(model.isConnected ? (model.deviceName ?? "휴대폰 연결됨") : "연결 대기 중", systemImage: model.isConnected ? "checkmark.circle.fill" : "wifi.slash")
                .font(.caption.weight(.medium))
                .foregroundStyle(model.isConnected ? .green : .secondary)
                .help(model.status)
            Spacer(minLength: 8)
            if let version = updater.availableUpdateVersion {
                Button { updater.checkForUpdates() } label: {
                    Label("v\(version) 업데이트", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .phoneBridgeHover()
                .help("새 버전이 있습니다. 업데이트 정보를 열어요.")
                .accessibilityIdentifier("available-update")
            }
            Button {
                model.findPhone()
            } label: {
                Label("휴대폰 찾기", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.plain)
            .phoneBridgeHover()
            .disabled(!model.isConnected)
            .help("연결된 Android 휴대폰에서 알림음을 재생합니다")
            Button {
                model.selectSection("설정")
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .phoneBridgeHover()
            .help("PhoneBridge 설정")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .phoneBridgeGlassSurface(cornerRadius: 17)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var model: PhoneBridgeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Mac에서 휴대폰을 함께 사용하세요").font(.system(size: 27, weight: .bold, design: .rounded))
                        Text("알림, 메시지, 통화와 파일을 한곳에서 확인하세요.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    OverviewControlRail()
                }

                HStack(spacing: 16) {
                    DeviceCard()
                    PairingCard()
                }
                .frame(height: 230)

                HStack(alignment: .top, spacing: 18) {
                    RecentActivityCard()
                        .frame(maxWidth: .infinity)
                        .frame(height: 230)
                    QuickActionsCard()
                        .frame(width: 340, height: 230)
                }
            }
            .padding(24)
            .frame(maxWidth: 1060, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct OverviewControlRail: View {
    @EnvironmentObject private var model: PhoneBridgeModel

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        model.findPhone()
                    } label: {
                        Label("휴대폰 찾기", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.plain)
                    .phoneBridgeHover()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(.blue).interactive(), in: Capsule())
                    .disabled(!model.isConnected)

                    Button {
                        model.selectSection("폰 화면")
                    } label: {
                        Label("폰 화면", systemImage: "macbook.and.iphone")
                    }
                    .buttonStyle(.plain)
                    .phoneBridgeHover()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
            }
        } else {
            HStack(spacing: 12) {
                Button {
                    model.findPhone()
                } label: {
                    Label("휴대폰 찾기", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isConnected)
                Button {
                    model.selectSection("폰 화면")
                } label: {
                    Label("폰 화면", systemImage: "macbook.and.iphone")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct DeviceCard: View {
    @EnvironmentObject private var model: PhoneBridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("기기", systemImage: "iphone").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                if model.isConnected { Label("연결됨", systemImage: "checkmark.circle.fill").font(.caption.weight(.medium)).foregroundStyle(.green) }
            }
            Spacer()
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 49, weight: .ultraLight))
                    .foregroundStyle(.blue.gradient)
                    .frame(width: 86, height: 102)
                    .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 22))
                VStack(alignment: .leading, spacing: 9) {
                    Text(model.deviceName ?? "휴대폰 연결 안 됨").font(.title2.weight(.semibold))
                    Text(model.status).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    if let battery = model.battery {
                        Label("배터리 \(battery)%", systemImage: "battery.75percent")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            Spacer()
            HStack(spacing: 8) {
                Label(model.callState, systemImage: "phone.fill").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("같은 Wi‑Fi").font(.caption).foregroundStyle(.secondary)
                Button("휴대폰 찾기") { model.findPhone() }
                    .buttonStyle(.bordered).phoneBridgeHover().disabled(!model.isConnected)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 230, maxHeight: 230)
        .phoneBridgeSurface(cornerRadius: 22)
    }
}

private struct PairingCard: View {
    @EnvironmentObject private var model: PhoneBridgeModel

    var body: some View {
        VStack(spacing: 10) {
            if let image = model.pairingImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .padding(6)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                Text("QR 코드로 연결").font(.headline)
                Text("Android에서 PhoneBridge를 열고 이 코드를 스캔하세요.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("QR 코드는 5분 뒤 만료됩니다.").font(.caption2).foregroundStyle(.tertiary)
                Button("코드 새로 만들기") { model.createPairingCode() }.buttonStyle(.link).phoneBridgeHover()
            } else if model.isPaired {
                Image(systemName: model.isConnected ? "checkmark.seal.fill" : "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 44)).foregroundStyle(model.isConnected ? .green : .blue)
                Text(model.isConnected ? "휴대폰 페어링 완료" : "휴대폰 연결 대기 중")
                    .font(.headline)
                Text("같은 Wi‑Fi에 있으면 Android 앱이 자동으로 다시 연결합니다.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("기기 연결 해제…") { model.showUnpairConfirmation = true }
                    .buttonStyle(.link).phoneBridgeHover().tint(.red)
                    .confirmationDialog("Android 휴대폰 연결을 해제할까요?", isPresented: $model.showUnpairConfirmation, titleVisibility: .visible) {
                        Button("연결 해제", role: .destructive) { model.unpair() }
                        Button("취소", role: .cancel) { }
                    } message: {
                        Text("이 Mac에 저장된 페어링 키가 삭제됩니다.")
                    }
            } else {
                if let error = model.pairingError {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 38))
                        .foregroundStyle(.orange)
                    Text("새 페어링 코드가 필요합니다").font(.headline)
                    Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    ProgressView()
                    Text("로컬 연결 준비 중…").font(.caption).foregroundStyle(.secondary)
                }
                Button("새 QR 코드 만들기") { model.createPairingCode() }
                    .buttonStyle(.link)
                    .phoneBridgeHover()
            }
        }
        .padding(14)
        .frame(width: 248, height: 230)
        .phoneBridgeSurface(cornerRadius: 22)
    }
}

private struct RecentActivityCard: View {
    @EnvironmentObject private var model: PhoneBridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("최근 활동").font(.headline)
                Spacer()
                Button("모두 보기") { model.selectSection("알림") }.buttonStyle(.link).phoneBridgeHover()
            }
            if model.events.isEmpty {
                EmptyStateView(title: "새 활동이 없습니다", icon: "bell", detail: "페어링한 휴대폰의 알림이 여기에 표시됩니다.")
                    .frame(height: 125)
            } else {
                ForEach(model.events.prefix(3)) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: event.kind == "call_state" ? "phone.fill" : "bell.fill")
                            .foregroundStyle(.blue)
                            .frame(width: 30, height: 30)
                            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title ?? event.source ?? event.kind.capitalized).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(event.text ?? event.callState ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(18)
        .phoneBridgeSurface()
    }
}

private struct QuickActionsCard: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("빠른 실행").font(.headline)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                QuickAction(title: "알림", detail: "휴대폰 알림 확인", icon: "bell", action: { model.selectSection("알림") })
                QuickAction(title: "메시지", detail: "SMS와 대화", icon: "message", action: { model.selectSection("메시지") })
                QuickAction(title: "통화", detail: "전화 상태 확인", icon: "phone", action: { model.selectSection("통화") })
                QuickAction(title: "사진", detail: "휴대폰으로 보내기", icon: "photo", action: { model.selectSection("사진") })
                QuickAction(title: "미디어", detail: "재생 제어", icon: "playpause", action: { model.selectSection("미디어") })
                QuickAction(title: "클립보드", detail: "텍스트 복사", icon: "doc.on.clipboard", action: { model.selectSection("클립보드") })
            }
        }
        .padding(18)
        .phoneBridgeSurface()
    }
}

private struct QuickAction: View {
    let title: String
    let detail: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(.blue).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(.blue.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .phoneBridgeHover()
    }
}

private struct EventListView: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    @StateObject private var local = PhoneBridgeViewState()
    let title: String
    let filter: String
    private var filtered: [PhoneEvent] {
        model.events.filter { event in
            guard event.kind == filter else { return false }
            guard !local.query.isEmpty else { return true }
            return [event.title, event.text, event.source].compactMap { $0 }
                .joined(separator: " ").localizedCaseInsensitiveContains(local.query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Android에서 받은 최근 알림 · 최근 100개를 보관")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.events.contains(where: { $0.kind == filter }) {
                    Button { local.confirmClear = true } label: { Label("지우기", systemImage: "trash") }
                        .buttonStyle(.bordered).phoneBridgeHover()
                    Button { model.exportEvents() } label: { Label("내보내기", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered).phoneBridgeHover()
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("알림 검색", text: $local.query).textFieldStyle(.plain)
                if !local.query.isEmpty {
                    Button { local.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).phoneBridgeHover().help("검색 지우기")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            if filtered.isEmpty {
                EmptyStateView(
                    title: local.query.isEmpty ? "알림이 없습니다" : "검색 결과가 없습니다",
                    icon: local.query.isEmpty ? "bell.slash" : "magnifyingglass",
                    detail: local.query.isEmpty ? "연결되면 휴대폰의 새 알림이 여기에 표시됩니다." : "다른 단어로 검색해 보세요."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(filtered) { event in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label(event.title ?? event.source ?? "알림", systemImage: "bell.fill")
                                        .font(.headline).lineLimit(1)
                                    Spacer()
                                    Text(event.source ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    if event.eventId != nil {
                                        Button { model.dismissPhoneNotification(event) } label: {
                                            Image(systemName: "xmark.circle")
                                        }
                                        .buttonStyle(.plain).phoneBridgeHover()
                                        .help("Android 휴대폰에서 이 알림 지우기")
                                        .disabled(!model.isConnected)
                                    }
                                }
                                Text(event.text ?? "").font(.body).foregroundStyle(.secondary).textSelection(.enabled)
                                if let timestamp = event.timestamp {
                                    Text(Date(timeIntervalSince1970: timestamp).formatted(date: .omitted, time: .shortened))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .phoneBridgeSurface(cornerRadius: 15)
                        }
                    }
                }
            }
        }
        .padding(28)
        .confirmationDialog("알림 기록을 지울까요?", isPresented: $local.confirmClear, titleVisibility: .visible) {
            Button("최근 활동 모두 지우기", role: .destructive) { model.clearEvents() }
            Button("취소", role: .cancel) { }
        } message: {
            Text("Mac 메모리에 보관 중인 알림·메시지·통화 기록이 모두 지워집니다.")
        }
    }
}

private struct MessagesView: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    @StateObject private var local = PhoneBridgeViewState()
    private var messages: [PhoneEvent] {
        model.events.filter { event in
            guard event.kind == "message" else { return false }
            guard !local.query.isEmpty else { return true }
            return [event.title, event.text, event.source].compactMap { $0 }
                .joined(separator: " ").localizedCaseInsensitiveContains(local.query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                pageHeading("메시지", subtitle: "알림 답장 또는 Android 기본 메시지 앱에서 새 문자 작성")
                Spacer()
                Button { local.showingComposer = true } label: { Label("새 메시지", systemImage: "square.and.pencil") }
                    .buttonStyle(.borderedProminent).phoneBridgeHover()
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("대화 알림 검색", text: $local.query).textFieldStyle(.plain)
                if !local.query.isEmpty {
                    Button { local.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).phoneBridgeHover().help("검색 지우기")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            if messages.isEmpty {
                EmptyStateView(
                    title: local.query.isEmpty ? "메시지 알림이 없습니다" : "검색 결과가 없습니다",
                    icon: local.query.isEmpty ? "message" : "magnifyingglass",
                    detail: local.query.isEmpty ? "알림 접근을 허용하면 휴대폰에 도착한 메시지 알림을 볼 수 있습니다." : "다른 단어로 검색해 보세요."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { event in
                            MessageCard(event: event)
                        }
                    }
                }
            }
            if let message = model.actionMessage {
                Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .sheet(isPresented: $local.showingComposer) {
            NewMessageSheet()
                .environmentObject(model)
        }
    }
}

private struct NewMessageSheet: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var local = PhoneBridgeViewState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("새 메시지", systemImage: "message.fill")
                .font(.title2.weight(.semibold))
            Text("받는 사람의 전화번호와 내용을 입력하세요.").foregroundStyle(.secondary)
            TextField("전화번호", text: $local.recipient)
                .textFieldStyle(.roundedBorder)
            Text("메시지 내용").font(.subheadline.weight(.medium))
            TextEditor(text: $local.bodyText)
                .font(.body)
                .frame(minHeight: 110, maxHeight: 170)
                .padding(5)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1))
            Label("휴대폰 기본 메시지 앱이 열립니다. 내용을 확인한 뒤 그 앱에서 전송하세요.", systemImage: "arrow.up.forward.app")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.buttonStyle(.bordered).phoneBridgeHover()
                Button("휴대폰에서 작성") {
                    model.composeSMS(to: local.recipient, body: local.bodyText)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).phoneBridgeHover()
                .disabled(!model.isConnected || local.recipient.isEmpty || local.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 470)
    }
}

private struct MessageCard: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    let event: PhoneEvent
    @StateObject private var replyModel = ReplyDraftModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "message.fill").foregroundStyle(.blue)
                Text(event.title ?? "메시지 알림").font(.headline)
                Spacer()
                Text(event.source ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if event.eventId != nil {
                    Button { model.dismissPhoneNotification(event) } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain).phoneBridgeHover()
                    .help("Android 휴대폰에서 이 알림 지우기")
                    .disabled(!model.isConnected)
                }
            }
            Text(event.text ?? "").font(.body).foregroundStyle(.secondary).textSelection(.enabled)
            if event.canReply == true {
                HStack(spacing: 8) {
                    TextField("빠른 답장", text: $replyModel.text)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button("보내기", action: send)
                        .buttonStyle(.borderedProminent)
                        .phoneBridgeHover()
                        .disabled(replyModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.isConnected)
                }
            } else {
                Label("이 알림은 빠른 답장 버튼을 제공하지 않습니다", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .phoneBridgeSurface(cornerRadius: 16)
    }

    private func send() {
        model.sendReply(to: event, text: replyModel.text)
        replyModel.text = ""
    }
}

private final class ReplyDraftModel: ObservableObject {
    @Published var text = ""
}

private struct FileTransferView: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    @StateObject private var local = PhoneBridgeViewState()
    let photosOnly: Bool
    private var files: [ReceivedFile] {
        photosOnly ? model.receivedFiles.filter { $0.contentType.hasPrefix("image/") } : model.receivedFiles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeading(photosOnly ? "사진" : "파일", subtitle: "기기 간 암호화된 로컬 Wi‑Fi 전송")
            HStack(spacing: 12) {
                Button {
                    model.selectAndSendFile(photosOnly: photosOnly)
                } label: {
                    Label(photosOnly ? "사진 선택 후 휴대폰으로 보내기" : "파일 선택 후 휴대폰으로 보내기", systemImage: photosOnly ? "photo.badge.arrow.down" : "arrow.up.doc")
                }
                .buttonStyle(.borderedProminent)
                .phoneBridgeHover()
                .disabled(!model.isConnected)
                if !model.isConnected {
                    Text("전송하려면 휴대폰을 연결하세요.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = model.actionMessage {
                Label(message, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            Text("받은 항목").font(.headline).padding(.top, 4)
            if files.isEmpty {
                EmptyStateView(title: photosOnly ? "받은 사진이 없습니다" : "받은 파일이 없습니다", icon: photosOnly ? "photo" : "folder", detail: "Android 앱에서 사진이나 파일을 선택해 보내거나, Mac에서 휴대폰으로 전송하세요.")
            } else {
                List(files) { file in
                    HStack(spacing: 12) {
                        Image(systemName: file.contentType.hasPrefix("image/") ? "photo" : "doc")
                            .foregroundStyle(.blue).frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file)) · \(file.receivedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("저장…") { model.saveReceivedFile(file) }.buttonStyle(.bordered).phoneBridgeHover()
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .padding(28)
        .overlay {
            if local.isDropTargeted {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $local.isDropTargeted) { providers in
            guard model.isConnected else { return false }
            let providers = providers.filter { $0.canLoadObject(ofClass: URL.self) }
            guard !providers.isEmpty else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    guard let url = object else { return }
                    DispatchQueue.main.async { model.sendFiles([url]) }
                }
            }
            return true
        }
    }
}

private struct PhoneGalleryView: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top) {
                pageHeading("휴대폰 갤러리", subtitle: "Android에서 허용한 사진을 둘러보고 원본을 Mac으로 받습니다.")
                Spacer()
                Button { model.requestGallery() } label: {
                    Label("새로 고침", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .phoneBridgeHover()
                .disabled(!model.isConnected || model.galleryIsLoading)
            }
            Label(model.galleryStatus, systemImage: model.galleryIsLoading ? "arrow.triangle.2.circlepath" : "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.galleryItems.isEmpty && !model.galleryIsLoading {
                EmptyStateView(
                    title: "휴대폰 사진을 불러오세요",
                    icon: "photo.stack",
                    detail: model.isConnected ? "Android 앱에서 사진 라이브러리 권한을 허용한 다음 새로 고침을 누르세요. Android 14 이상에서는 선택한 사진만 공유할 수 있습니다." : "갤러리를 열려면 Android 휴대폰을 연결하세요."
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(model.galleryItems) { item in
                            Button { model.downloadGalleryItem(item) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    Group {
                                        if let image = item.thumbnail {
                                            Image(nsImage: image)
                                                .resizable()
                                                .scaledToFill()
                                        } else {
                                            ZStack {
                                                Color.secondary.opacity(0.08)
                                                Image(systemName: "photo")
                                                    .font(.system(size: 28))
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                    .frame(height: 116)
                                    .frame(maxWidth: .infinity)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    Text(item.name)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(8)
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .phoneBridgeHover()
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.quaternary, lineWidth: 1))
                            .help("클릭하면 원본 사진을 휴대폰에서 받습니다")
                        }
                    }
                    .padding(.vertical, 2)
                }
                if model.galleryHasMore {
                    Button("사진 더 불러오기") { model.requestGallery(offset: model.galleryItems.count) }
                        .buttonStyle(.bordered)
                        .disabled(model.galleryIsLoading)
                }
            }
            let receivedPhotos = model.receivedFiles.filter { $0.contentType.hasPrefix("image/") }
            if !receivedPhotos.isEmpty {
                Text("Mac으로 받은 사진").font(.headline)
                ForEach(receivedPhotos.prefix(4)) { file in
                    HStack {
                        Label(file.name, systemImage: "photo")
                            .lineLimit(1)
                        Spacer()
                        Button("저장…") { model.saveReceivedFile(file) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(28)
        .onAppear { if model.galleryItems.isEmpty { model.requestGallery() } }
    }
}

private struct MediaControlsView: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeading("미디어", subtitle: "알림 접근을 허용한 뒤 Android에서 재생 중인 앱을 제어합니다.")
            VStack(spacing: 16) {
                Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(.blue.gradient)
                Text("휴대폰 미디어 제어").font(.title3.weight(.semibold))
                HStack(spacing: 14) {
                    Button { model.controlMedia("previous") } label: { Image(systemName: "backward.fill") }
                        .help("이전 곡").buttonStyle(.bordered).phoneBridgeHover()
                    Button { model.controlMedia("play_pause") } label: { Image(systemName: "playpause.fill") }
                        .help("재생 또는 일시 정지").buttonStyle(.borderedProminent).phoneBridgeHover()
                    Button { model.controlMedia("next") } label: { Image(systemName: "forward.fill") }
                        .help("다음 곡").buttonStyle(.bordered).phoneBridgeHover()
                }
                if let message = model.actionMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity).padding(26).phoneBridgeSurface()
            Text("Android의 알림 접근 서비스가 활성화되어 있어야 하며, 앱이 미디어 세션 제어를 제공해야 합니다.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28)
    }
}

private struct ScreenIntegrationView: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeading("폰 화면", subtitle: "플랫폼에서 지원하는 화면 연결을 실행합니다.")
            VStack(alignment: .leading, spacing: 12) {
                Label("iPhone", systemImage: "iphone.gen3").font(.headline)
                Text("iPhone 화면과 알림은 Apple의 iPhone 미러링 및 연속성 기능으로 연결됩니다. PhoneBridge는 iPhone의 개인 알림이나 메시지를 직접 읽지 않습니다.")
                    .foregroundStyle(.secondary)
                Button("iPhone 미러링 열기") {
                    let appURL = URL(fileURLWithPath: "/System/Applications/iPhone Mirroring.app")
                    NSWorkspace.shared.open(appURL)
                }
                .buttonStyle(.bordered).phoneBridgeHover()
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).phoneBridgeSurface()

            VStack(alignment: .leading, spacing: 12) {
                Label("Android", systemImage: "smartphone").font(.headline)
                Text("Android에서 화면 공유를 승인하면 미리보기가 나타납니다. 접근성 원격 터치를 켜면 Mac에서 탭과 스와이프, 뒤로·홈 동작을 보낼 수 있습니다.")
                    .foregroundStyle(.secondary)
                Text(model.deviceName ?? "Android 휴대폰이 연결되면 상태가 여기에 표시됩니다.")
                    .font(.caption).foregroundStyle(.tertiary)
                if let frame = model.screenFrame {
                    PhoneScreenControlSurface(image: frame) { start, end in
                        if hypot(end.x - start.x, end.y - start.y) > 0.035 {
                            model.controlPhoneScreen(action: "swipe", x: start, end: end)
                        } else {
                            model.controlPhoneScreen(action: "tap", x: end)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 430)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    HStack(spacing: 9) {
                        Button { model.controlPhoneScreen(action: "back") } label: { Label("뒤로", systemImage: "chevron.backward") }
                        Button { model.controlPhoneScreen(action: "home") } label: { Label("홈", systemImage: "house") }
                        Button { model.controlPhoneScreen(action: "recents") } label: { Label("최근 앱", systemImage: "square.on.square") }
                        Spacer()
                        Button("화면 공유 중지") { model.stopScreenMirror() }
                    }
                    .buttonStyle(.bordered)
                    .phoneBridgeHover()
                    if !model.remoteControlEnabled {
                        Label("Mac에서 조작하려면 Android 앱의 ‘Mac에서 화면 조작’ 설정에서 PhoneBridge 원격 터치를 켜세요.", systemImage: "hand.tap")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.isConnected {
                    Label("화면 공유를 시작하려면 Android 앱에서 동의를 완료하세요.", systemImage: "rectangle.on.rectangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Android 시스템 화면 공유 확인과 접근성 설정은 각각 사용자가 직접 승인합니다. 접근성 서비스는 화면 내용을 읽지 않고 Mac에서 보낸 터치 입력만 실행합니다.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).phoneBridgeSurface()
            Spacer()
        }
        .padding(28)
    }
}

private struct PhoneScreenControlSurface: View {
    let image: NSImage
    let onGesture: (CGPoint, CGPoint) -> Void

    var body: some View {
        GeometryReader { geometry in
            let bounds = geometry.size
            let imageSize = image.size
            let scale = min(bounds.width / max(imageSize.width, 1), bounds.height / max(imageSize.height, 1))
            let renderedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let origin = CGPoint(x: (bounds.width - renderedSize.width) / 2, y: (bounds.height - renderedSize.height) / 2)
            let normalizedPoint: (CGPoint) -> CGPoint? = { point in
                guard point.x >= origin.x, point.y >= origin.y,
                      point.x <= origin.x + renderedSize.width,
                      point.y <= origin.y + renderedSize.height else { return nil }
                return CGPoint(
                    x: (point.x - origin.x) / max(renderedSize.width, 1),
                    y: (point.y - origin.y) / max(renderedSize.height, 1),
                )
            }
            ZStack {
                Color.black.opacity(0.92)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: renderedSize.width, height: renderedSize.height)
                    .position(x: bounds.width / 2, y: bounds.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onEnded { value in
                    guard let start = normalizedPoint(value.startLocation),
                          let end = normalizedPoint(value.location) else { return }
                    onGesture(start, end)
                })
        }
        .accessibilityLabel("Android 휴대폰 화면. 탭하거나 드래그해 조작")
    }
}

private struct ClipboardView: View {
    @EnvironmentObject private var model: PhoneBridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeading("클립보드", subtitle: "필요할 때 직접 눌러 텍스트를 기기 간에 복사합니다.")

            VStack(alignment: .leading, spacing: 14) {
                Label("Mac → Android", systemImage: "arrow.up.right")
                    .font(.headline)
                Text("현재 Mac 클립보드의 텍스트를 연결된 휴대폰 클립보드에 복사합니다. 파일과 이미지는 이 화면에서 전송하지 않습니다.")
                    .foregroundStyle(.secondary)
                Button {
                    model.sendMacClipboardToPhone()
                } label: {
                    Label("Mac 클립보드 보내기", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)
                .phoneBridgeHover()
                .disabled(!model.isConnected)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .phoneBridgeSurface()

            VStack(alignment: .leading, spacing: 14) {
                Label("Android → Mac", systemImage: "arrow.down.left")
                    .font(.headline)
                Text("Android 앱에서 ‘Mac으로 복사’를 누르면 텍스트가 아래에 도착합니다. 그때 복사 버튼을 눌러야 Mac 클립보드가 바뀝니다.")
                    .foregroundStyle(.secondary)
                if let text = model.phoneClipboardText {
                    ScrollView {
                        Text(text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button {
                        model.copyPhoneClipboardToMac()
                    } label: {
                        Label("Mac 클립보드에 복사", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .phoneBridgeHover()
                } else {
                    Label("아직 받은 텍스트가 없습니다", systemImage: "clipboard")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .phoneBridgeSurface()

            if let message = model.actionMessage {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("클립보드는 자동 감시하지 않습니다. 민감한 텍스트가 예상치 않게 복사되는 일을 막기 위해 각 전송은 사용자가 직접 시작합니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: 880, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

private func pageHeading(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
        Text(subtitle).foregroundStyle(.secondary)
    }
}

private struct CallsView: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    @StateObject private var local = PhoneBridgeViewState()
    private var calls: [PhoneEvent] { model.events.filter { $0.kind == "call_notification" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center) {
                pageHeading("통화", subtitle: "최근 통화 알림과 휴대폰 전화 걸기")
                Spacer()
                Button { local.showingDialer = true } label: { Label("전화 걸기", systemImage: "phone.arrow.up.right") }
                    .buttonStyle(.borderedProminent).phoneBridgeHover()
            }
            HStack(spacing: 16) {
                Image(systemName: "phone.connection.fill").font(.system(size: 32)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.callState).font(.title3.weight(.semibold))
                    Text("PhoneBridge가 연결되어 있을 때 통화 상태를 표시합니다.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .phoneBridgeSurface(cornerRadius: 16)
            if let message = model.actionMessage { Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
            Text("최근 전화 알림").font(.headline)
            if calls.isEmpty {
                EmptyStateView(title: "전화 알림이 없습니다", icon: "phone", detail: "전화 앱 알림 접근을 허용하면 발신자 정보와 제공되는 응답 동작을 표시합니다.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(calls) { event in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(event.title ?? "전화").font(.headline)
                                    Spacer()
                                    Text(event.source ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(event.text ?? "").font(.subheadline).foregroundStyle(.secondary)
                                HStack {
                                    ForEach(event.actions ?? []) { action in
                                        Button(action.title) { model.sendCallAction(event: event, actionId: action.id) }
                                            .buttonStyle(.borderedProminent).phoneBridgeHover()
                                    }
                                }
                            }
                            .padding(15).frame(maxWidth: .infinity, alignment: .leading).phoneBridgeSurface(cornerRadius: 15)
                        }
                    }
                }
            }
            Text("응답 버튼은 Android 전화 알림이 제공할 때만 사용할 수 있습니다. 통화 음성 라우팅은 제공하지 않습니다.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(30)
        .sheet(isPresented: $local.showingDialer) {
            DialerSheet()
                .environmentObject(model)
        }
    }
}

private struct DialerSheet: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var local = PhoneBridgeViewState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("전화 걸기", systemImage: "phone.arrow.up.right")
                .font(.title2.weight(.semibold))
            Text("전화번호를 휴대폰 다이얼러로 보냅니다.").foregroundStyle(.secondary)
                TextField("전화번호", text: $local.number)
                .textFieldStyle(.roundedBorder)
                .onSubmit(dial)
            Label("휴대폰에서 번호를 확인한 뒤 직접 통화를 시작하세요. 긴급 전화는 이 앱으로 걸 수 없습니다.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.buttonStyle(.bordered).phoneBridgeHover()
                Button("휴대폰 다이얼러 열기", action: dial)
                    .buttonStyle(.borderedProminent).phoneBridgeHover()
                    .disabled(!model.isConnected || local.number.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 450)
    }

    private func dial() {
        model.openPhoneDialer(number: local.number)
        dismiss()
    }
}

private struct EmptyStateView: View {
    let title: String
    let icon: String
    let detail: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 25)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    @EnvironmentObject private var updater: PhoneBridgeUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("설정").font(.system(size: 28, weight: .bold, design: .rounded))
            GroupBox("권한") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Mac에서 PhoneBridge가 알림을 표시하도록 허용할 수 있습니다.").foregroundStyle(.secondary)
                    Button("macOS 알림 허용") { model.requestMacNotifications() }.buttonStyle(.bordered).phoneBridgeHover()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            GroupBox("연결") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.isConnected ? "연결됨" : "연결 안 됨", systemImage: model.isConnected ? "checkmark.circle.fill" : "wifi.slash")
                    Text("로컬 주소: \(model.localAddress.isEmpty ? "페어링할 때 표시" : model.localAddress)")
                    Text("서비스: _phonebridge._tcp · 포트 51534")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            }
            GroupBox("앱 업데이트") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("현재 버전 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "알 수 없음")")
                    if let version = updater.availableUpdateVersion {
                        Text("v\(version) 업데이트를 자동으로 확인했습니다. 가능한 경우 백그라운드에서 준비하고, 앱을 종료할 때 적용합니다.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("업데이트를 자동으로 확인합니다. 새 버전은 백그라운드에서 준비되며, 여기에서 진행 상태를 확인할 수 있습니다.")
                            .foregroundStyle(.secondary)
                    }
                    Button("업데이트 확인…") { updater.checkForUpdates() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!updater.canCheckForUpdates)
                        .phoneBridgeHover()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            Spacer()
        }
        .padding(30)
    }
}

private extension View {
    func phoneBridgeSurface(cornerRadius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay(shape.stroke(.quaternary, lineWidth: 1))
    }

    @ViewBuilder
    func phoneBridgeGlassSurface(cornerRadius: CGFloat = 22) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.08), lineWidth: 0.7))
                .shadow(color: .black.opacity(0.07), radius: 18, x: 0, y: 8)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.08), lineWidth: 0.7))
                .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 7)
        }
    }

    func phoneBridgeHover() -> some View {
        modifier(PhoneBridgeHoverModifier())
    }
}

private struct PhoneBridgeHoverModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var local = PhoneBridgeViewState()

    func body(content: Content) -> some View {
        content
            .scaleEffect(local.isHovered && !reduceMotion ? 1.025 : 1)
            .offset(y: local.isHovered && !reduceMotion ? -1 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.72), value: local.isHovered)
            .onHover { local.isHovered = $0 }
    }
}

private final class PhoneBridgeViewState: ObservableObject {
    @Published var isHovered = false
    @Published var isDropTargeted = false
    @Published var query = ""
    @Published var confirmClear = false
    @Published var showingComposer = false
    @Published var showingDialer = false
    @Published var recipient = ""
    @Published var bodyText = ""
    @Published var number = ""
}

private struct PhoneBridgeAmbientBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(
                    colors: [.blue.opacity(0.11), .clear],
                    center: UnitPoint(x: 0.86, y: 0.08),
                    startRadius: 16,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.86
                )
                RadialGradient(
                    colors: [.purple.opacity(0.07), .clear],
                    center: UnitPoint(x: 0.02, y: 0.56),
                    startRadius: 8,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.72
                )
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }
}
