import Foundation
import Observation
import Sparkle
import XSideCore

/// XSide's self-updates through Sparkle: the feed (`SUFeedURL`) is `appcast.xml` on the
/// repository's main branch, each update is signed with the EdDSA key whose public half is
/// `SUPublicEDKey` (see scripts/release.sh). Off when the bundle has no feed (debug app, `swift run`).
@MainActor @Observable
final class Updater {
    private static let log = Log("updates")

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    private(set) var canCheck = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        self.controller = controller
        // KVO calls back on the main thread (Sparkle's updater lives there).
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let can = change.newValue ?? false
            Task { @MainActor in self?.canCheck = can }
        }
        Self.log.notice("updater started, automatic checks \(controller.updater.automaticallyChecksForUpdates)")
    }

    var isAvailable: Bool { controller != nil }

    /// Daily background checks (Sparkle shows the update when one is found).
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    func checkNow() {
        Self.log.notice("checking for updates")
        controller?.checkForUpdates(nil)
    }
}
