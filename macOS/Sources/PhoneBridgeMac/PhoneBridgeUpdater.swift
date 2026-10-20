import Combine
import Foundation
import Sparkle

@MainActor
final class PhoneBridgeUpdater: ObservableObject {
    private let updateObserver: PhoneBridgeSparkleObserver
    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var availableUpdateVersion: String?
    private var availabilityTimer: Timer?

    init() {
        let observer = PhoneBridgeSparkleObserver()
        updateObserver = observer
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: observer,
            userDriverDelegate: nil
        )
        observer.onUpdateFound = { [weak self] version in
            self?.availableUpdateVersion = version
        }
        observer.onNoUpdate = { [weak self] in
            self?.availableUpdateVersion = nil
        }
        refreshAvailability()
        availabilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAvailability() }
        }
        if controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
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

@MainActor
private final class PhoneBridgeSparkleObserver: NSObject, SPUUpdaterDelegate {
    var onUpdateFound: ((String) -> Void)?
    var onNoUpdate: (() -> Void)?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onUpdateFound?(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        onNoUpdate?()
    }
}
