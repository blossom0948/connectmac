import Combine
import Foundation
import Sparkle

@MainActor
final class PhoneBridgeUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false
    private var availabilityTimer: Timer?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        refreshAvailability()
        availabilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAvailability() }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
        refreshAvailability()
    }

    private func refreshAvailability() {
        let available = controller.updater.canCheckForUpdates
        if canCheckForUpdates != available {
            canCheckForUpdates = available
        }
    }
}
