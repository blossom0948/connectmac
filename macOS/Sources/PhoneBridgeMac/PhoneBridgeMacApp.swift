import SwiftUI
import AppKit

@main
struct PhoneBridgeMacApp: App {
    @StateObject private var model = PhoneBridgeModel()
    @StateObject private var updater = PhoneBridgeUpdater()

    var body: some Scene {
        WindowGroup("PhoneBridge", id: "main") {
            PhoneBridgeRootView()
                .environmentObject(model)
                .environmentObject(updater)
                .frame(minWidth: 1080, minHeight: 700)
        }
        .defaultSize(width: 1200, height: 780)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("PhoneBridge", systemImage: "iphone.gen3.radiowaves.left.and.right") {
            MenuBarCommands()
                .environmentObject(model)
                .environmentObject(updater)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarCommands: View {
    @EnvironmentObject private var model: PhoneBridgeModel
    @EnvironmentObject private var updater: PhoneBridgeUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.deviceName ?? "PhoneBridge")
        Text(model.isConnected ? "휴대폰 연결됨" : "같은 Wi‑Fi에서 연결 대기 중")
        if let version = updater.availableUpdateVersion {
            Text("v\(version) 업데이트 사용 가능")
            Button("업데이트 보기") {
                openWindow(id: "main")
                updater.checkForUpdates()
            }
        }
        Divider()
        Button("PhoneBridge 열기") { openWindow(id: "main") }
        Button("알림 보기") {
            model.selectSection("알림")
            openWindow(id: "main")
        }
        Button("휴대폰 찾기") { model.findPhone() }
            .disabled(!model.isConnected)
        Button("업데이트 확인…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        Divider()
        Button("PhoneBridge 종료") { NSApp.terminate(nil) }
    }
}
