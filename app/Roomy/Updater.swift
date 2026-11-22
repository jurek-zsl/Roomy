import Sparkle
import SwiftUI

/// Sparkle: checks the appcast of the latest GitHub release, verifies the
/// update's signature against SUPublicEDKey, and installs it when you agree.
@MainActor
final class Updater {
    let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    lazy var updates = Updates(
        automaticallyChecks: controller.updater.automaticallyChecksForUpdates,
        setAutomatic: { [controller] in controller.updater.automaticallyChecksForUpdates = $0 },
        checkNow: { [controller] in controller.checkForUpdates(nil) })
}

/// "Check for Updates…" in the Roomy menu.
struct CheckForUpdatesCommand: View {
    let updates: Updates
    var body: some View {
        Button("Check for Updates…") { updates.check() }
    }
}
