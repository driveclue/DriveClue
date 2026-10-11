import Foundation
import Sparkle

/// Owns Sparkle, which checks for updates in the background and presents the
/// update prompt (release notes, Skip / Remind Me Later / Install Update).
/// The controller must stay alive for the whole app run, so it lives here
/// instead of in SwiftUI state, which is re-created on every render.
enum UpdateController {
    static let shared = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    static func checkNow() {
        shared.updater.checkForUpdates()
    }
}
