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
    /// The XSide module in the app (step ③): the values every checked device gets. Prefilled from the app's
    /// last-used values, else the Mac defaults; only the values count (see `InAppSettings.adopting`).
    var inApp = AppModel.inAppDefaults(at: Date())
    /// The step ③ fields the user changed: the only ones a device that has the app adopts.
    var inAppTouched: Set<InAppField> = []
    /// Devices getting iPhone Duo compatibility (step ②), prefilled with those that have it.
    var duoDevices: Set<String> = []

    /// Applies a step ③ change, remembering which fields it touched.
    func editInApp(_ change: (InAppSettings) -> InAppSettings) {
        let edited = change(inApp)
        inAppTouched.formUnion(edited.fields(differingFrom: inApp))
        inApp = edited
    }
    /// The step shown while editing: 0 devices, 1 install options, 2 the XSide module in the app.
    var step = 0
    /// Steps ①②③ with Next/Back. False for an app already installed when "Revoir les options à
    /// chaque installation" is off: step ① then lists every option, with Edit, and Install.
    var reviewsSteps = true

    init(ipa: URL) { self.ipa = ipa }

    /// Steps of the install window, in order.
    static let stepCount = 3

    /// Shows step `index`; from the summary, editing turns the steps on.
    func go(to index: Int) {
        reviewsSteps = true
        step = min(max(index, 0), Self.stepCount - 1)
    }

    /// The app gets no XSide features: its own choice, else the Mac's default.
    var withoutXSideFeatures: Bool {
        draft.withoutXSideFeatures ?? AppModel.withoutXSideFeaturesByDefault
    }

    /// Devices of the last run, in install order.
    var runs: [DeviceRun] = []
    /// Options of the last run, reused by "Retry failed".
    var runOptions = InstallOptions()
    /// XSide-in-app settings of the last run, reused by "Retry failed".
    var runInApp: InAppDraft?
    /// Devices of the last run getting iPhone Duo compatibility, reused by "Retry failed".
    var runDuo: Set<String> = []
    /// The app has old 32-bit code to remove: its step is listed from the start.
    var runLegacy32 = false
    /// The last run installs the app without XSide's features (the progress says so).
    var runWithoutXSideFeatures: Bool {
        runOptions.resolvedWithoutXSideFeatures(default: AppModel.withoutXSideFeaturesByDefault)
    }
    /// The steps the last run passes over: the module step when the app goes without XSide's
    /// features (shown as skipped, not ticked: device feedback round 2, M4).
    var skippedRunSteps: Set<ProgressStep> { runWithoutXSideFeatures ? [.welcome] : [] }

    /// The steps of the last run on one device (nil: the only or first one): the iPhone Duo step
    /// when the option is on there. Wi-Fi verification is planned or not, never added later.
    func runSteps(for deviceID: String? = nil) -> [ProgressStep] {
        let id = deviceID ?? runs.first?.deviceID
        return ProgressStep.list(includingWifiCheck: wifiStepPlanned, includingDuo: id.map(runDuo.contains) ?? false,
                                 includingLegacy32: runLegacy32)
    }

    /// `skippedRunSteps`, and the Duo step on a device where it added nothing.
    func skippedSteps(for deviceID: String? = nil) -> Set<ProgressStep> {
        guard let outcome = duoOutcome(for: deviceID), outcome != .added else { return skippedRunSteps }
        return skippedRunSteps.union([.duo])
    }

    func duoOutcome(for deviceID: String? = nil) -> DuoOutcome? {
        let id = deviceID ?? runs.first?.deviceID
        return runs.first { $0.deviceID == id }?.duoOutcome
    }
    /// Record this `.ipa` was imported into during this flow: later devices install it as is.
    var importedRecordID: UUID?

    /// The running install, cancelled by "Cancel install".
    @ObservationIgnored var runTask: Task<Void, Never>?
    /// The user cancelled the current (or last) run: its remaining devices don't start.
    var cancelRequested = false
    /// The last run was cancelled: the window says so instead of showing an error.
    var wasCancelled = false

    /// Devices whose trust guide is due if the install succeeds, judged when the run started.
    var trustDue: Set<String> = []
    /// For this install: open the app on the device after it, and the Trust page when needed.
    /// Prefilled from Settings > General (the defaults).
    var openAppAfter = AppModel.setting(AppModel.openAppAfterInstallKey)
    var openTrustPage = AppModel.setting(AppModel.openTrustSettingsKey)
    /// Devices getting their very first XSide install in this run (Wi-Fi check after it).
    var firstInstalls: Set<String> = []
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

    /// Devices "Retry failed" runs again: failed or cancelled.
    var retryableDeviceIDs: [String] {
        runs.filter { $0.isFailed || $0.status == .cancelled }.map(\.deviceID)
    }

    var succeededCount: Int { runs.filter { $0.status == .succeeded }.count }

    /// The device being installed, with its stage.
    var currentRun: (index: Int, run: DeviceRun, stage: JobStage)? {
        for (i, run) in runs.enumerated() {
            if case .running(let stage) = run.status { return (i, run, stage) }
        }
        return nil
    }

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
        /// Stopped by "Cancel install" (while running, or before it started).
        case cancelled
    }

    let deviceID: String
    let name: String
    var status: Status = .waiting
    /// The device answered over Wi-Fi after its first install (or was installed over Wi-Fi).
    var wifiVerified = false
    /// iPhone Duo compatibility was asked for but the app was installed without it.
    var duoMissing = false
    /// How the iPhone Duo step went in this run, once known (nil: not asked, or not there yet).
    var duoOutcome: DuoOutcome?

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
    /// XSide opened the trust page on the device itself (it said it doesn't trust the developer).
    var openedOnDevice = false
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
    var shareKeychain = false
    var minOS = ""
    /// The app's own choice (nil: the Mac's default), see `InstallOptions.withoutXSideFeatures`.
    var withoutXSideFeatures: Bool?

    init() {}

    init(_ o: InstallOptions) {
        name = o.displayName ?? ""
        bundleID = o.customBundleID ?? ""
        version = o.version ?? ""
        iconPath = o.iconPath
        fileSharing = o.fileSharing
        iPadFullScreen = o.iPadFullScreen
        proMotion = o.proMotion
        shareKeychain = o.shareKeychain
        minOS = o.minimumOSVersion ?? ""
        withoutXSideFeatures = o.withoutXSideFeatures
    }

    var options: InstallOptions {
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return InstallOptions(displayName: clean(name), customBundleID: clean(bundleID), version: clean(version),
                               iconPath: iconPath, fileSharing: fileSharing, iPadFullScreen: iPadFullScreen,
                               proMotion: proMotion, minimumOSVersion: clean(minOS), shareKeychain: shareKeychain,
                               withoutXSideFeatures: withoutXSideFeatures)
    }
}

/// A failed install attempt: the stage it stopped at and the localized message.
struct StepFailure: Equatable {
    let stage: JobStage
    let message: String
}
