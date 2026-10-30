import Foundation
import Observation
import XSideCore

/// State of the install window for one `.ipa`. Lives in `AppModel` (not in view `@State`) so it
/// survives the `.id(language)` re-render.
@MainActor @Observable
final class InstallFlow {
    enum Phase: Equatable {
        case inspecting
        /// The file can't be installed at all (encrypted, not an app…).
        case rejected(String)
        /// Ready for input; `error` is the localized message of the last failed attempt.
        case editing(error: String?)
        /// Stage of the device being installed (`runs` has every device's status).
        case running(JobStage)
        /// Every targeted device ran: one success, or several devices (results in `runs`). A single
        /// device that failed goes back to `editing` instead.
        case finished
    }

    let ipa: URL
    var info: AppInfo?
    /// The app's own icon pulled out of the IPA (PNG in the temporary directory), if found.
    var appIcon: URL?
    /// Library record already imported from the same bundle id (second import of the same app).
    var existing: AppRecord?
    var phase: Phase = .inspecting
    /// Devices checked in the picker, in the order they were checked (the install order).
    var deviceIDs: [String] = []
    /// The user changed the selection: device list refreshes keep it instead of the default.
    var selectionEdited = false
    /// Last stage reported by the running install, to place a failure.
    var lastStage: JobStage = .preparing
    /// Where the last attempt failed, with the localized message.
    var failure: StepFailure?
    /// The run ends with the Wi-Fi check (first install over USB with Wi-Fi refresh on). Single
    /// device only: with several, the checks come after every install and aren't a step of each.
    var wifiStepPlanned = false
    var draft = OptionsDraft()

    init(ipa: URL) { self.ipa = ipa }

    /// Devices of the last run, in install order.
    var runs: [DeviceRun] = []
    /// Options of the last run, reused by "Retry failed".
    var runOptions = InstallOptions()
    /// Record this `.ipa` was imported into during this flow: later devices install it as is.
    var importedRecordID: UUID?

    /// First-install guides due after this flow's successes, one per device.
    var guides: [FirstInstallGuide] = []
    /// Devices whose guide has been displayed.
    var shownGuides: Set<String> = []
    /// True once every first-install guide of this flow has been displayed.
    var guideSeen: Bool { guides.allSatisfy { shownGuides.contains($0.deviceID) } }

    /// The Wi-Fi reachability step, while the user hasn't finished or skipped it.
    var wifiCheck: WifiCheck?
    /// Device of the current Wi-Fi check.
    var wifiDeviceID: String?
    /// Devices whose Wi-Fi check comes after the current one.
    var wifiQueue: [String] = []

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Running, or finished with a Wi-Fi check or a guide the user hasn't seen yet: must not be replaced.
    var isBusy: Bool {
        if isRunning || wifiCheck != nil { return true }
        if case .finished = phase { return !guideSeen }
        return false
    }

    /// Several devices in the last run: the window lists them one row each.
    var isMultiDevice: Bool { runs.count > 1 }

    var failedDeviceIDs: [String] { runs.filter(\.isFailed).map(\.deviceID) }

    func toggle(_ deviceID: String) {
        selectionEdited = true
        if let i = deviceIDs.firstIndex(of: deviceID) {
            deviceIDs.remove(at: i)
        } else {
            deviceIDs.append(deviceID)
        }
    }

    func setStatus(_ status: DeviceRun.Status, for deviceID: String) {
        guard let i = runs.firstIndex(where: { $0.deviceID == deviceID }) else { return }
        runs[i].status = status
    }

    /// Starts the next queued Wi-Fi check, or ends the step when none is left.
    func nextWifiCheck() {
        if wifiQueue.isEmpty {
            wifiCheck = nil
            wifiDeviceID = nil
        } else {
            wifiDeviceID = wifiQueue.removeFirst()
            wifiCheck = WifiCheck(startedAt: Date())
        }
    }

    /// Deletes the extracted icon file (the flow is over).
    func removeAppIcon() {
        if let appIcon { try? FileManager.default.removeItem(at: appIcon) }
        appIcon = nil
    }

    /// Ends the current Wi-Fi check and the queued ones (the window closed).
    func skipAllWifiChecks() {
        wifiQueue = []
        nextWifiCheck()
    }
}

/// One device of an install run and where it stands.
struct DeviceRun: Identifiable, Equatable {
    enum Status: Equatable {
        case waiting
        case running(JobStage)
        case succeeded
        case failed(StepFailure)
    }

    let deviceID: String
    let name: String
    var status: Status = .waiting
    /// The device answered over Wi-Fi after its first install (or was installed over Wi-Fi).
    var wifiVerified = false

    var id: String { deviceID }

    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }
}

/// What the first-install guide must say for a device.
struct FirstInstallGuide: Equatable {
    let deviceID: String
    let accountName: String
    let needsDeveloperMode: Bool
}

/// Text-field friendly mirror of `InstallOptions` (empty string = not customized).
struct OptionsDraft: Equatable {
    var name = ""
    var bundleID = ""
    var version = ""
    /// Absolute path of a newly chosen image, or the library-relative path of the remembered one.
    var iconPath: String?
    var fileSharing = false
    var iPadFullScreen = false
    var proMotion = false
    var minOS = ""

    init() {}

    init(_ o: InstallOptions) {
        name = o.displayName ?? ""
        bundleID = o.customBundleID ?? ""
        version = o.version ?? ""
        iconPath = o.iconPath
        fileSharing = o.fileSharing
        iPadFullScreen = o.iPadFullScreen
        proMotion = o.proMotion
        minOS = o.minimumOSVersion ?? ""
    }

    var options: InstallOptions {
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return InstallOptions(displayName: clean(name), customBundleID: clean(bundleID), version: clean(version),
                              iconPath: iconPath, fileSharing: fileSharing, iPadFullScreen: iPadFullScreen,
                              proMotion: proMotion, minimumOSVersion: clean(minOS))
    }
}

/// A failed install attempt: the stage it stopped at and the localized message.
struct StepFailure: Equatable {
    let stage: JobStage
    let message: String
}
