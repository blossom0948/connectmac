import SwiftUI
import AppKit

@main
struct PhoneBridgeMacApp: App {
    @StateObject private var model = PhoneBridgeModel()

    var body: some Scene {
        WindowGroup("PhoneBridge", id: "main") {
            PhoneBridgeRootView()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 700)
        }
        .defaultSize(width: 1200, height: 780)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("PhoneBridge", systemImage: "iphone.gen3.radiowaves.left.and.right") {
            MenuBarCommands()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarCommands: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.deviceName ?? "PhoneBridge")
        Text(model.isConnected ? "휴대폰 연결됨" : "같은 Wi‑Fi에서 연결 대기 중")
        Divider()
        Button("PhoneBridge 열기") { openWindow(id: "main") }
        Button("알림 보기") {
            model.selectedSection = "알림"
            openWindow(id: "main")
        }
        Button("휴대폰 찾기") { model.findPhone() }
            .disabled(!model.isConnected)
        Divider()
        Button("PhoneBridge 종료") { NSApp.terminate(nil) }
    }
}
