import Foundation
import Observation
import os
import XSideCore

/// One app row: an app installed on one device.
struct AppEntry: Identifiable, Equatable {
    let record: AppRecord
    let installation: Installation
    var id: JobKey { JobKey(recordID: record.id, deviceID: installation.deviceID) }
    var job: RefreshJob { RefreshJob(recordID: record.id, deviceID: installation.deviceID) }
}

struct JobKey: Hashable {
    let recordID: UUID
    let deviceID: String
}

/// A device card and the apps installed on it. `device` is nil when the device is known only from
/// past installations (devicectl doesn't list it right now).
struct DeviceGroup: Identifiable {
    let id: String
    let device: Device?
    let name: String
    let kind: DeviceKind
    let apps: [AppEntry]
    var wifiRefresh = true
    /// Reachable only over Wi-Fi while Wi-Fi refresh is off: due apps need a USB cable.
    var needsUSB = false
    var canRemove = true
}

@MainActor @Observable
final class AppModel {
    private static let logger = Log("model")

    private(set) var environment: Result<SigningEnvironment, XSideError>? {
        didSet {
            if case .success(let env)? = environment {
                LogStore.shared.register(env.teamID, as: "team")
                LogStore.shared.registerIdentity(name: env.identityName, sha1: env.identitySHA1)
                Self.logger.notice("environment OK: \(env.developerDir.path), team \(env.teamID)")
            } else if case .failure(let error)? = environment {
                Self.logger.notice("environment problem: \(error.key)")
            }
        }
    }
    /// Signed out of Xcode AND no signing certificate either: both are reported (two banners).
    private(set) var certificateMissingToo = false

    /// Every current environment problem, in fixing order (one popover banner each).
    var environmentProblems: [XSideError] {
        guard let environmentError else { return [] }
        return certificateMissingToo ? [environmentError, .noSigningIdentity] : [environmentError]
    }
    private(set) var isProbing = false
    /// The probe running now, awaited by callers that need its result.
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    /// Who is signed in to Xcode: the Apple ID e-mail from the certificate, else the Personal
    /// Team's name (Xcode's preferences hold no e-mail). Read once per probe, not per render.
    private(set) var accountName: String? {
        didSet { LogStore.shared.register(accountName, as: "account") }
    }
    /// "Create the certificate" is running (an Xcode build, up to a minute).
    private(set) var isCreatingCertificate = false
    /// Why the last "Create the certificate" left no certificate, nil otherwise.
    private(set) var certificateCreationError: String?
    private(set) var devices: [Device] = [] {
        didSet {
            for device in devices {
                LogStore.shared.register(device.id, as: "device")
                LogStore.shared.register(device.udid, as: "udid")
                LogStore.shared.register(device.name, as: "device-name")
            }
            if devices.map(\.logLine) != oldValue.map(\.logLine) {
                Self.logger.notice("devices: \(devices.isEmpty ? "none" : devices.map(\.logLine).joined(separator: "; "))")
            }
        }
    }
    private(set) var records: [AppRecord] = [] {
        didSet {
            for record in records {
                LogStore.shared.register(record.teamID, as: "team")
                for installation in record.installations { LogStore.shared.register(installation.deviceID, as: "device") }
            }
        }
    }
    private(set) var appIDsRemaining: Int?
    /// Current step of each running install/refresh, per app row.
    private(set) var jobs: [JobKey: JobStage] = [:]
    private(set) var pairing: Set<String> = []
    private(set) var pairErrors: [String: String] = [:]

    /// The `.ipa` shown in the install window. Setting it requests an install of that file: it
    /// starts a new flow, or is queued while an install is running.
    var pendingIPA: URL? {
        get { install?.ipa }
        set { if let newValue { request(newValue) } }
    }
    private(set) var install: InstallFlow? {
        // A flow ended or was replaced: its extracted icon is no longer shown anywhere.
        didSet {
            if oldValue !== install {
                oldValue?.removeAppIcon()
                dropKeptEmptyRecords()
            }
        }
    }
    /// Where the icons pulled out of `.ipa` files go (one per flow, deleted with it).
    private static let iconsDir = FileManager.default.temporaryDirectory.appendingPathComponent(
        LibraryLocation.folderName(bundleID: Bundle.main.bundleIdentifier).lowercased() + "-icons")

    let library: AppLibrary
    /// Runs every tool with `DEVELOPER_DIR` set to the Xcode in use (see `resolveXcode`).
    private let runner: ProcessRunner
    /// Without the override: what `xcode-select -p` itself points to.
    private let plainRunner = ProcessRunner()
    /// The developer directory passed as `DEVELOPER_DIR`, nil to inherit XSide's environment.
    private let developerDirOverride = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let paths: Paths
    /// One for the app's lifetime: its per-device ordering and its provisioning lock only hold
    /// within one instance. The signing environment is passed per job.
    private let pipeline: SideloadPipeline
    /// Last environment that probed OK.
    private var lastGoodEnv: SigningEnvironment?
    private var listingDevices = false
    private let prefsStore: DevicePrefsStore
    /// Per-device settings (Wi-Fi refresh), persisted in `devices.json`.
    private(set) var devicePrefs = DevicePrefs()
    /// Devices being removed right now: no job may start on them.
    private(set) var removingDevices: Set<String> = []

    // MARK: Background engine hooks

    /// Something the due evaluation depends on changed (device list, signing environment).
    var onNeedsEvaluation: (() -> Void)?
    /// A device was removed from XSide: forget what is kept per (app, device).
    var onDeviceRemoved: ((_ deviceID: String) -> Void)?
    /// An installation is gone (uninstalled, removed from the list) or paused: forget what is kept
    /// for it (reminder, notification state).
    var onInstallationRemoved: ((_ job: RefreshJob) -> Void)?
    /// A paused installation is refreshed again: its reminder comes back, and it may be due now.
    var onRefreshResumed: ((_ job: RefreshJob) -> Void)?
    /// Every pipeline run that ends (install, manual or automatic refresh), with its error if it failed.
    var onJobFinished: ((_ job: RefreshJob, _ error: (any Error)?, _ automatic: Bool,
                               _ wasRefresh: Bool) -> Void)?
    /// True while the menu-bar popover is on screen (drives the device polling rate).
    private(set) var isPopoverOpen = false

    init() {
        let developerDirOverride = developerDirOverride
        runner = ProcessRunner(environment: {
            developerDirOverride.withLock { $0 }.map { ["DEVELOPER_DIR": $0] } ?? [:]
        })
        paths = Paths()
        library = AppLibrary(root: paths.root)
        prefsStore = DevicePrefsStore(libraryRoot: paths.root)
        devicePrefs = prefsStore.load()
        // Icons pulled out of earlier sessions' `.ipa` files.
        try? FileManager.default.removeItem(at: Self.iconsDir)
        // Leftovers of jobs interrupted by a quit or a crash (extracted apps, template builds).
        // No job can be running yet.
        try? FileManager.default.removeItem(at: paths.work)
        pipeline = SideloadPipeline(
            library: library,
            provisioner: Provisioner(runner: runner, templateDir: paths.template, workDir: paths.provisioningWork,
                                     cacheDirs: paths.xcodeProfileDirs),
            resigner: Resigner(runner: runner), installer: Installer(runner: runner),
            workRoot: paths.jobsWork, now: { Date() }, macIsBeta: XcodeLauncher.macIsBeta)
        Task { await start() }
    }

    // MARK: - Startup

    private func start() async {
        await reloadRecords()
        refreshDevices()
        await probeEnvironment()
    }

    // MARK: Welcome journey

    /// Step shown by the welcome window. Saved so a journey left halfway resumes where it stopped.
    var journeyStep: JourneyStep = JourneyStep.saved() {
        didSet { UserDefaults.standard.set(journeyStep.id, forKey: JourneyStep.savedStepKey) }
    }

    /// True until the journey is finished and the environment is OK: the popover then only offers setup.
    var setupIncomplete: Bool {
        !UserDefaults.standard.bool(forKey: JourneyStep.completedKey) || environmentFailed
    }

    /// An .ipa received during setup (drop, Open With, Services), opened once setup is done.
    var queuedIPA: URL?

    /// The first blocking step the environment fails (Xcode, the account, then the certificate),
    /// nil when it is OK or not probed yet.
    var firstBlockingStep: JourneyStep? {
        guard case .failure(let error)? = environment else { return nil }
        switch error {
        case .xcodeMissing: return .xcode
        case .noSigningIdentity: return .certificate
        default: return .account
        }
    }

    /// True once `step` lets the user continue (always for non-blocking steps).
    func isJourneyStepDone(_ step: JourneyStep) -> Bool {
        guard step.isBlocking else { return true }
        guard environment != nil else { return false }
        return firstBlockingStep.map { $0 > step } ?? true
    }

    /// Where the journey (re)opens: the saved step, never past a failing blocking step. A finished
    /// journey only reopens for a failing step (or from the start).
    func prepareJourney() {
        if UserDefaults.standard.bool(forKey: JourneyStep.completedKey) {
            journeyStep = firstBlockingStep ?? .language
        } else {
            capJourneyAtBlockingStep()
        }
    }

    func capJourneyAtBlockingStep() {
        if let blocking = firstBlockingStep, journeyStep > blocking { journeyStep = blocking }
    }

    // MARK: Environment poller

    /// One poller for every setup surface: it runs only while the environment fails AND the
    /// popover is open or the welcome window is visible, and re-probes every 5 s.
    private(set) var isOnboardingWindowOpen = false
    @ObservationIgnored private var onboardingPoller: Task<Void, Never>?

    func onboardingWindowVisibilityChanged(_ visible: Bool) {
        guard visible != isOnboardingWindowOpen else { return }
        isOnboardingWindowOpen = visible
        updateOnboardingPoller()
    }

    private func updateOnboardingPoller() {
        let shouldRun = environmentFailed && (isPopoverOpen || isOnboardingWindowOpen)
        if shouldRun, onboardingPoller == nil {
            Self.logger.notice("onboarding poller started")
            onboardingPoller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let self else { return }
                    await self.probeEnvironment()
                }
            }
        } else if !shouldRun, let poller = onboardingPoller {
            Self.logger.notice("onboarding poller stopped")
            poller.cancel()
            onboardingPoller = nil
        }
    }

    var environmentFailed: Bool { environmentError != nil }
    var environmentError: XSideError? { if case .failure(let error)? = environment { error } else { nil } }

    /// The Xcode XSide uses (to open it, show its version): the one probed OK, else the one
    /// chosen for the tools, else the last that probed OK.
    var lastKnownDeveloperDir: URL? {
        signingEnvironment?.developerDir
            ?? activeDeveloperDir.flatMap { XcodeLocator.hasXcodebuild($0) ? $0 : nil }
            ?? lastGoodEnv?.developerDir
    }

    /// Lets Xcode create the signing certificate (see `Provisioner.createCertificate`), then
    /// re-probes: the steps turn ✅ by themselves when it worked.
    func createCertificate() {
        guard !isCreatingCertificate else { return }
        guard let teamID = EnvironmentProbe.personalTeamID(EnvironmentProbe.savedXcodeTeams()) else {
            certificateCreationError = L("error.xcodeNotSignedIn")
            return
        }
        isCreatingCertificate = true
        certificateCreationError = nil
        Task {
            let provisioner = Provisioner(runner: runner, templateDir: paths.template,
                                          workDir: paths.provisioningWork, cacheDirs: [])
            let failure: (any Error)?
            Self.logger.notice("creating a certificate for team \(teamID)")
            do { failure = try await provisioner.createCertificate(teamID: teamID) } catch { failure = error }
            if let failure { Self.logger.error("certificate creation: \(failure)") }
            // A probe started before the certificate existed would report it missing: wait for it.
            await probeEnvironmentAfresh()
            isCreatingCertificate = false
            if case .failure(.noSigningIdentity)? = environment {
                certificateCreationError = failure.map(localizedMessage) ?? L("error.generic")
            }
        }
    }

    func recheckEnvironment() {
        Task { await probeEnvironment() }
    }

    /// Probes the environment, or joins the probe already running (its result is just as fresh).
    private func probeEnvironment() async {
        if let probeTask { await probeTask.value; return }
        // Cleared by the task itself (on the main actor, before anyone awaiting it resumes), so a
        // caller woken by its end never mistakes it for one still running.
        let task = Task {
            await runProbe()
            probeTask = nil
        }
        probeTask = task
        await task.value
    }

    /// Waits for the probe already running, if any, then probes again: the result reflects what
    /// changed since that probe started (a certificate just created).
    private func probeEnvironmentAfresh() async {
        if let probeTask { await probeTask.value }
        await probeEnvironment()
    }

    private func runProbe() async {
        isProbing = true
        defer { isProbing = false }
        #if DEBUG
        // Debug-only: XSIDE_FAKE_ENV_FILE names a file holding xcodeMissing / xcodeNotSignedIn /
        // signedOutNoCertificate / noSigningIdentity / ok [developer dir] / checking, re-read at
        // each probe, to exercise the welcome journey.
        if Self.fakeEnvironmentText == "checking" {
            environment = nil
            environmentChanged()
            return
        }
        if let fake = Self.fakeEnvironment() {
            environment = fake
            certificateMissingToo = Self.fakeEnvironmentText == "signedOutNoCertificate"
            environmentChanged()
            updateOnboardingPoller()
            onNeedsEvaluation?()
            return
        }
        #endif
        await resolveXcode()
        let probe = EnvironmentProbe(runner: runner)
        let result = await probe.detect()
        if case .failure(.xcodeNotSignedIn) = result {
            if case .failure(.noSigningIdentity) = await probe.signingIdentity() {
                certificateMissingToo = true
            } else {
                certificateMissingToo = false
            }
        } else {
            certificateMissingToo = false
        }
        environment = result
        environmentChanged()
        updateOnboardingPoller()
        if case .success(let env) = result { lastGoodEnv = env }
        // Reading the profiles spawns one `security` per profile: not at every probe (popover
        // open, 5-min tick), only for a new environment or a stale count. Jobs update it too.
        if case .success(let env) = result {
            if env != appIDCounterEnv || appIDCounterDate.map({ Date().timeIntervalSince($0) >= Self.appIDCounterMaxAge }) ?? true {
                await updateAppIDCounter()
            }
        } else {
            await updateAppIDCounter()
        }
        onNeedsEvaluation?()
    }

    /// Per-probe state the views read on every render, so no file or preferences I/O there.
    private func environmentChanged() {
        defer { updateAttention() }
        if case .success? = environment { certificateCreationError = nil }
        if let identity = signingEnvironment?.identityName, let appleID = EnvironmentProbe.appleID(fromIdentityName: identity) {
            accountName = appleID
        } else {
            accountName = EnvironmentProbe.personalTeamName(EnvironmentProbe.savedXcodeTeams())
        }
        if XcodeLauncher.macIsBeta, let env = signingEnvironment,
           let xcode = XcodeCompat.xcodeVersion(developerDir: env.developerDir) {
            macBetaWithReleaseXcode = !xcode.isBeta
        } else {
            macBetaWithReleaseXcode = false
        }
    }

    #if DEBUG
    private static var fakeEnvironmentText: String? {
        guard let path = ProcessInfo.processInfo.environment["XSIDE_FAKE_ENV_FILE"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fakeEnvironment() -> Result<SigningEnvironment, XSideError>? {
        guard let text = fakeEnvironmentText else { return nil }
        if text.hasPrefix("ok ") {
            let dir = URL(fileURLWithPath: String(text.dropFirst(3)))
            return .success(SigningEnvironment(developerDir: dir, identitySHA1: "0", identityName: "Fake", teamID: "FAKE"))
        }
        switch text {
        case "xcodeMissing": return .failure(.xcodeMissing)
        case "xcodeNotSignedIn", "signedOutNoCertificate": return .failure(.xcodeNotSignedIn)
        case "noSigningIdentity": return .failure(.noSigningIdentity)
        case "ok":
            let dir = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer")
            return .success(SigningEnvironment(developerDir: dir, identitySHA1: "0", identityName: "Fake", teamID: "FAKE"))
        default: return nil
        }
    }
    #endif

    var signingEnvironment: SigningEnvironment? { try? environment?.get() }

    // MARK: Xcode selection

    /// The Xcode apps found in /Applications and ~/Applications, newest first (one scan per probe).
    private(set) var xcodes: [XcodeInstall] = []
    /// What "Automatic" picks right now (nil when there is no Xcode at all).
    private(set) var automaticDeveloperDir: URL?
    /// The developer directory the tools run with now (`DEVELOPER_DIR`).
    private(set) var activeDeveloperDir: URL?

    /// "Automatic" or an Xcode picked in Settings. Changing it probes again with that Xcode.
    var xcodeSelection: XcodeSelection {
        get {
            access(keyPath: \.xcodeSelection)
            return XcodeSelection(rawValue: UserDefaults.standard.string(forKey: XcodeSelection.storageKey))
        }
        set {
            withMutation(keyPath: \.xcodeSelection) {
                UserDefaults.standard.set(newValue.rawValue, forKey: XcodeSelection.storageKey)
            }
            Task { await probeEnvironmentAfresh() }
        }
    }

    /// Picks the developer directory every tool runs with: the Xcode chosen in Settings, else the
    /// automatic choice (see `XcodeLocator.automatic`). Command Line Tools alone are left as is.
    private func resolveXcode() async {
        let installs = await Task.detached { XcodeLocator.find() }.value
        // A picked Xcode that was deleted: back to Automatic, so picking it again later works.
        if case .path(let path) = xcodeSelection, !XcodeLocator.hasXcodebuild(URL(fileURLWithPath: path)) {
            Self.logger.notice("picked Xcode gone (\(path)): back to automatic")
            withMutation(keyPath: \.xcodeSelection) {
                UserDefaults.standard.set(XcodeSelection.automatic.rawValue, forKey: XcodeSelection.storageKey)
            }
        }
        var selected: XcodeLocator.Selected?
        if let result = try? await plainRunner.run("/usr/bin/xcode-select", ["-p"], cwd: nil), result.status == 0 {
            let path = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                let dir = URL(fileURLWithPath: path, isDirectory: true)
                selected = XcodeLocator.Selected(developerDir: dir, isXcode: XcodeLocator.hasXcodebuild(dir),
                                                 isBeta: XcodeCompat.xcodeVersion(developerDir: dir)?.isBeta ?? false)
            }
        }
        if installs != xcodes { xcodes = installs }
        // On a macOS beta, a beta Xcode is switched to only once it's usable (license accepted).
        var unready: Set<String> = []
        for beta in XcodeLocator.betasToCheck(selected: selected, installs: installs, macIsBeta: XcodeLauncher.macIsBeta) {
            if await isReady(beta) { break }
            unready.insert(beta.developerDir.path)
        }
        let automatic = XcodeLocator.automatic(selected: selected, installs: installs,
                                               macIsBeta: XcodeLauncher.macIsBeta, unready: unready)
        if automatic?.path != automaticDeveloperDir?.path { automaticDeveloperDir = automatic }
        let pickedBeta = automatic.map { dir in installs.contains { $0.isBeta && $0.developerDir.path == dir.path } } ?? false
        let notReady = pickedBeta ? nil : installs.first { unready.contains($0.developerDir.path) }
        if notReady != unreadyBetaXcode { unreadyBetaXcode = notReady }
        let resolved = XcodeLocator.resolve(xcodeSelection, selected: selected, installs: installs,
                                            macIsBeta: XcodeLauncher.macIsBeta, unready: unready,
                                            hasXcodebuild: XcodeLocator.hasXcodebuild)
        let current = developerDirOverride.withLock { $0 }
        guard current != resolved?.path else { return }
        // A job running now keeps its own Xcode, but the next probe must match what jobs will
        // use: the switch waits until no job runs, then probes again (see `release`).
        if !claims.isEmpty, current != nil {
            Self.logger.notice("developer dir change deferred: jobs running")
            xcodeSwitchPending = true
            return
        }
        developerDirOverride.withLock { $0 = resolved?.path }
        activeDeveloperDir = resolved
        Self.logger.notice("developer dir: \(resolved?.path ?? "inherited")")
    }

    /// A beta Xcode found but not usable yet (never opened, license not accepted), shown in
    /// Settings and the journey; nil otherwise.
    private(set) var unreadyBetaXcode: XcodeInstall?
    /// A new developer dir was resolved while jobs were running: applied once they're done.
    @ObservationIgnored private var xcodeSwitchPending = false
    /// Xcode apps (path and build) whose first launch is done: checked once.
    @ObservationIgnored private var readyXcodes: Set<String> = []

    /// `xcodebuild -checkFirstLaunchStatus` with that Xcode: exit 0 once its license is accepted
    /// and its first launch done.
    private func isReady(_ xcode: XcodeInstall) async -> Bool {
        let key = "\(xcode.developerDir.path)#\(xcode.build)"
        if readyXcodes.contains(key) { return true }
        let check = XcodeLocator.firstLaunchCheck(xcode.developerDir)
        let result = try? await CommandEnvironment.withDeveloperDir(xcode.developerDir) {
            try await plainRunner.run(check.executable, check.arguments, cwd: nil, timeout: .seconds(30))
        }
        guard result?.status == 0 else { return false }
        readyXcodes.insert(key)
        return true
    }

    /// macOS beta with a release Xcode, which may stop working on it: warned, never blocking.
    /// Computed once per probe.
    private(set) var macBetaWithReleaseXcode = false
    /// Jobs can run: the signing environment probed OK.
    var isPipelineReady: Bool { signingEnvironment != nil }

    // MARK: - Devices

    /// The popover window was shown or hidden (see `WindowVisibilityReader`).
    func popoverVisibilityChanged(_ visible: Bool) {
        guard visible != isPopoverOpen else { return }
        isPopoverOpen = visible
        updateOnboardingPoller()
        if visible {
            refreshDevices()
            recheckEnvironment()
            Task { await reloadRecords() }
        }
    }

    func refreshDevices() {
        Task { await listDevices() }
    }

    /// Lists devices now. Returns at once when a listing is already running (that one reports the change).
    func listDevices() async {
        guard !listingDevices else { return }
        listingDevices = true
        defer { listingDevices = false }
        do {
            var listed = try await DeviceService(runner: runner).list().filter { $0.kind != .other }
            #if DEBUG
            // Debug-only: XSIDE_FAKE_NO_DEVICES=1 shows the "no device yet" screens.
            if ProcessInfo.processInfo.environment["XSIDE_FAKE_NO_DEVICES"] == "1" { listed = [] }
            #endif
            let changed = listed != devices
            devices = listed
            rememberNames(devices)
            autoselectDevice()
            if changed { onNeedsEvaluation?() }
        } catch {
            Self.logger.error("device list failed: \(String(describing: error))")
        }
    }

    var unpairedDevices: [Device] { devices.filter { !$0.isPaired } }
    var pairedDevices: [Device] { devices.filter(\.isPaired) }

    func pair(_ device: Device) {
        guard !pairing.contains(device.id) else { return }
        pairing.insert(device.id)
        pairErrors[device.id] = nil
        Task {
            defer { pairing.remove(device.id) }
            do {
                try await DeviceService(runner: runner).pair(device.id)
            } catch {
                Self.logger.error("pairing \(device.id) failed: \(error)")
                pairErrors[device.id] = localizedMessage(error)
            }
            refreshDevices()
        }
    }

    /// Paired devices with their apps, then devices only known from past installations.
    var deviceGroups: [DeviceGroup] {
        let entries = records.flatMap { r in r.installations.map { AppEntry(record: r, installation: $0) } }
        var groups = pairedDevices.map { d in
            DeviceGroup(id: d.id, device: d, name: d.name, kind: d.kind,
                        apps: entries.filter { $0.installation.deviceID == d.id },
                        wifiRefresh: devicePrefs.wifiRefresh(for: d.id),
                        needsUSB: devicePrefs.isWifiBlocked(d), canRemove: canRemoveDevice(d.id))
        }
        let known = Set(groups.map(\.id))
        var orphanIDs: [String] = []
        for e in entries where !known.contains(e.installation.deviceID) && !orphanIDs.contains(e.installation.deviceID) {
            orphanIDs.append(e.installation.deviceID)
        }
        let names = cachedNames
        for id in orphanIDs {
            groups.append(DeviceGroup(id: id, device: nil, name: names[id] ?? L("popover.unknownDevice"),
                                      kind: .iPhone, apps: entries.filter { $0.installation.deviceID == id },
                                      wifiRefresh: devicePrefs.wifiRefresh(for: id), canRemove: canRemoveDevice(id)))
        }
        return groups
    }

    private static let namesKey = "deviceNames"
    var cachedNames: [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
    }
    private func rememberNames(_ list: [Device]) {
        var names = cachedNames
        for d in list where d.isPaired { names[d.id] = d.name }
        UserDefaults.standard.set(names, forKey: Self.namesKey)
    }

    // MARK: Per-device settings

    func setWifiRefresh(_ on: Bool, for deviceID: String) {
        var updated = devicePrefs
        updated.setWifiRefresh(on, for: deviceID)
        savePrefs(updated)
        onNeedsEvaluation?()
    }

    private func savePrefs(_ prefs: DevicePrefs) {
        devicePrefs = prefs
        do { try prefsStore.save(prefs) } catch {
            Self.logger.error("saving devices.json failed: \(String(describing: error))")
        }
    }

    /// False while an install or refresh targets the device.
    func canRemoveDevice(_ deviceID: String) -> Bool {
        !removingDevices.contains(deviceID) && !jobs.keys.contains { $0.deviceID == deviceID }
            && !(install?.isRunning == true && install?.runs.contains { $0.deviceID == deviceID } == true)
    }

    /// Stops managing a device: forgets its installations (apps without any installation left are
    /// deleted), settings, remembered name and notification state. Nothing is uninstalled from
    /// the device. If it is still paired it simply shows again, without apps.
    func removeDevice(_ deviceID: String) async {
        guard canRemoveDevice(deviceID) else { return }
        // Set before the first await: no refresh or install can start on it meanwhile.
        removingDevices.insert(deviceID)
        defer { removingDevices.remove(deviceID) }
        Self.logger.notice("removing device \(deviceID)")
        // Records a job is installing on another device must survive even if this device held
        // their last installation.
        var busyRecords = Set(claims.keys.map(\.recordID))
        if let flow = install, flow.isRunning {
            if let id = flow.importedRecordID ?? flow.existing?.id { busyRecords.insert(id) }
        }
        do {
            try await library.removeDevice(deviceID, keeping: busyRecords)
        } catch {
            Self.logger.error("removing device failed: \(String(describing: error))")
            return
        }
        var prefs = devicePrefs
        prefs.forget(deviceID)
        savePrefs(prefs)
        var names = cachedNames
        names[deviceID] = nil
        UserDefaults.standard.set(names, forKey: Self.namesKey)
        UserDefaults.standard.removeObject(forKey: Self.guideKey(deviceID))
        await reloadRecords()
        // After the reload: what it forgets (reminders) is rebuilt from the records left.
        onDeviceRemoved?(deviceID)
        // Kept for a job on another device; deleted once nothing uses them if that job didn't install.
        keptEmptyRecords.formUnion(records.filter { busyRecords.contains($0.id) && $0.installations.isEmpty }.map(\.id))
        dropKeptEmptyRecords()
        await updateAppIDCounter()
    }

    /// Records `removeDevice` left without installations because a job was using them, and the
    /// import of a cancelled first install (`dropCancelledImport`).
    @ObservationIgnored private var keptEmptyRecords: Set<UUID> = []

    /// Deletes the kept records no job claims and no install window refers to, if they still have
    /// no installation. Any other first import (also without installations) is never in the set.
    private func dropKeptEmptyRecords() {
        guard !keptEmptyRecords.isEmpty else { return }
        let inUse: (UUID) -> Bool = { [unowned self] id in
            claims.keys.contains { $0.recordID == id } || install?.importedRecordID == id || install?.existing?.id == id
        }
        let idle = keptEmptyRecords.filter { !inUse($0) }
        guard !idle.isEmpty else { return }
        keptEmptyRecords.subtract(idle)
        Task {
            // Checked again right before each removal: a job may have claimed it meanwhile.
            for id in idle where !inUse(id) { _ = try? await library.removeIfEmpty(id) }
            await reloadRecords()
        }
    }

    // MARK: - Library

    func reloadRecords() async {
        records = await library.records()
        updateAttention()
    }

    // MARK: Attention (menu-bar badge)

    enum Attention { case warning, critical }

    /// Drawn as a dot on the menu-bar icon: something needs a look even with the popover closed.
    private(set) var attention: Attention?
    /// The library warning was acknowledged in the popover (for this launch; Settings keeps it).
    private(set) var libraryIssueDismissed = false

    /// Critical: an app expired, or the environment broke after setup. Warning: an app close to
    /// expiry whose last attempt failed, or the library couldn't be fully read.
    func updateAttention() {
        let now = Date()
        let setupDone = UserDefaults.standard.bool(forKey: JourneyStep.completedKey)
        let expired = ExpiryWatch.hasExpired(records, now: now)
        let updated: Attention?
        // A failed check of the setup (a system tool erred) says nothing is missing: a warning.
        let broken = setupDone && environmentFailed && environmentError?.isSetupCheckFailure != true
        let checkFailed = setupDone && environmentError?.isSetupCheckFailure == true
        if expired || broken {
            updated = .critical
        } else if ExpiryWatch.needsAttention(records, now: now, threshold: BackgroundEngine.threshold)
                    || (library.loadIssue != nil && !libraryIssueDismissed) || checkFailed {
            updated = .warning
        } else {
            updated = nil
        }
        if updated != attention { attention = updated }
    }

    func dismissLibraryIssue() {
        libraryIssueDismissed = true
        updateAttention()
    }

    /// Quitting now would leave a valid app without its refresh (see `ExpiryWatch`).
    var quitStopsRefreshes: Bool { ExpiryWatch.quitStopsRefreshes(records, now: Date()) }

    /// Environment and date of the last App ID count, to skip recounting at every probe.
    @ObservationIgnored private var appIDCounterEnv: SigningEnvironment?
    @ObservationIgnored private var appIDCounterDate: Date?
    private static let appIDCounterMaxAge: TimeInterval = 30 * 60

    private func updateAppIDCounter() async {
        guard case .success(let env) = environment else {
            appIDsRemaining = nil
            appIDCounterEnv = nil
            return
        }
        appIDCounterEnv = env
        appIDCounterDate = Date()
        let profiles = await ProfileReader(runner: runner).scan(paths.xcodeProfileDirs)
        let firstUse = AppIDCounter.firstUses(await library.records())
        appIDsRemaining = AppIDCounter.remaining(profiles, teamID: env.teamID, now: Date(), firstUse: firstUse)
    }

    /// Resolves an icon path from `InstallOptions` (library-relative once saved, absolute when just chosen).
    func iconURL(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : library.root.appendingPathComponent(path)
    }

    // MARK: - Install

    /// Inspect → import (or update the existing record) → save options → sign and install.
    /// `options == nil` keeps the options remembered for this app.
    /// `importedInto`: the record this `.ipa` was already imported into (an earlier device of the
    /// same run). Nothing is imported again and `options` is ignored (saved by that import).
    /// `imported` reports the record once imported with its options, even if the install then fails.
    @discardableResult
    func importAndInstall(_ ipa: URL, on device: Device, options: InstallOptions? = nil,
                          importedInto recordID: UUID? = nil,
                          imported: @MainActor (UUID) -> Void = { _ in },
                          progress: @escaping @MainActor @Sendable (JobStage) -> Void = { _ in }) async throws -> AppRecord {
        guard let env = try environment?.get() else { throw XSideError.xcodeMissing }
        guard !removingDevices.contains(device.id) else { throw XSideError.deviceUnavailable }
        let record: AppRecord
        if let recordID {
            guard let known = records.first(where: { $0.id == recordID }) else { throw XSideError.recordNotFound }
            record = known
        } else {
            let info: AppInfo
            if let flow = install, flow.ipa == ipa, let known = flow.info {
                info = known
            } else {
                info = try await IPAImporter.inspect(ipa: ipa, runner: runner)
            }
            record = try await library.importIPA(ipa, info: info, teamID: env.teamID)
        }
        // Claimed with no await since the import, so a refresh can't start in between.
        let key = JobKey(recordID: record.id, deviceID: device.id)
        claim(key)
        defer { release(key) }
        if recordID == nil {
            if let options { try await library.setOptions(options, for: record.id) }
            imported(record.id) // options saved too: later devices install this record as is
        }
        await reloadRecords()
        // Preparation is over: until the pipeline reports its first step the job may be queued
        // (provisioning lock, or another job on the same device).
        if jobs[key] == .preparing { jobs[key] = .waiting }
        progress(jobs[key] ?? .waiting) // never replaces a real step another holder already reported
        try await run(key: key, device: device, progress: progress)
        return records.first { $0.id == record.id } ?? record
    }

    /// Starts a refresh of one row unless it is already running. Returns false when nothing started.
    @discardableResult
    func refreshNow(_ job: RefreshJob, automatic: Bool = false) -> Bool {
        let key = JobKey(recordID: job.recordID, deviceID: job.deviceID)
        guard signingEnvironment != nil, jobs[key] == nil, !removingDevices.contains(job.deviceID),
              !isPaused(job), let device = devices.first(where: { $0.id == job.deviceID }) else { return false }
        claim(key) // before the task starts, so the row can't be claimed twice
        Task {
            defer { release(key) }
            try? await run(key: key, device: device, refresh: true, automatic: automatic)
        }
        return true
    }

    /// Records a failed attempt on an unreachable device without running the pipeline: the row
    /// shows the unreachable hint and the 30-min retry delay applies. Expiry is kept. False when
    /// nothing was recorded (row busy, installation or device removed meanwhile).
    @discardableResult
    func recordUnreachable(_ job: RefreshJob, at date: Date) async -> Bool {
        guard !busyJobs.contains(job), !removingDevices.contains(job.deviceID),
              let record = records.first(where: { $0.id == job.recordID }),
              var installation = record.installations.first(where: { $0.deviceID == job.deviceID }) else { return false }
        installation.lastAttempt = date
        installation.lastErrorKey = XSideError.deviceUnavailable.key
        let recorded: Bool
        do {
            // Never brings back an installation removed meanwhile (device removed from XSide).
            try await library.upsert(installation, for: job.recordID, requireExisting: true)
            recorded = true
        } catch {
            Self.logger.error("recording unreachable failed: \(String(describing: error))")
            recorded = false
        }
        await reloadRecords()
        return recorded
    }

    // MARK: - Uninstall / stop refreshing

    /// Rows being uninstalled from their device right now (their row says so).
    private(set) var uninstalling: Set<JobKey> = []

    /// The user stopped refreshing that installation (see `stopRefreshing`).
    private func isPaused(_ job: RefreshJob) -> Bool {
        records.first { $0.id == job.recordID }?.installations
            .first { $0.deviceID == job.deviceID }?.refreshPaused == true
    }

    /// Uninstall, stop/resume refreshing and "remove from the list" are offered while no job runs on the row.
    func canManage(_ entry: AppEntry) -> Bool {
        jobs[entry.id] == nil && !removingDevices.contains(entry.installation.deviceID)
    }

    /// Removes the app from its device, then stops managing it there (see `forgetInstallation`).
    /// Runs on the device's pipeline chain, after any job already queued there; the row stays
    /// claimed meanwhile, so no refresh can start on it. Throws `deviceUnavailable` at once when
    /// the device isn't reachable; on failure nothing is forgotten.
    func uninstall(_ entry: AppEntry) async throws {
        let key = entry.id
        guard canManage(entry) else { return }
        guard devices.contains(where: { $0.id == key.deviceID && $0.isAvailable }) else {
            throw XSideError.deviceUnavailable
        }
        claim(key) // before the first await
        uninstalling.insert(key)
        defer {
            uninstalling.remove(key)
            release(key) // after `installationRemoved`: an emptied record is deleted only then
        }
        let developerDir: @Sendable () async -> URL? = { [weak self] in await self?.lastKnownDeveloperDir }
        do {
            try await pipeline.uninstall(recordID: key.recordID, deviceID: key.deviceID, developerDir: developerDir)
        } catch XSideError.recordNotFound {
            // Removed meanwhile (device removed from XSide): nothing left to forget.
        }
        await installationRemoved(key)
    }

    /// Pauses the app's refreshes on that device without touching the device (it may be out of
    /// reach): the row stays, the app stays there until it expires. Its reminder and notification
    /// state go (see `onInstallationRemoved`).
    func stopRefreshing(_ entry: AppEntry) async {
        let key = entry.id
        guard canManage(entry) else { return }
        claim(key)
        defer { release(key) }
        do {
            guard try await library.setRefreshPaused(true, recordID: key.recordID, deviceID: key.deviceID) else {
                await reloadRecords()
                return
            }
        } catch XSideError.recordNotFound {
            return // removed meanwhile (device removed from XSide)
        } catch {
            Self.logger.error("stop refreshing failed: \(String(describing: error))")
            return
        }
        await reloadRecords()
        onInstallationRemoved?(RefreshJob(recordID: key.recordID, deviceID: key.deviceID))
    }

    /// Refreshes a paused installation again: its reminder is scheduled again and, if it's due,
    /// the engine refreshes it at once (the row is released first, so it can start).
    func resumeRefreshing(_ entry: AppEntry) async {
        let key = entry.id
        guard canManage(entry) else { return }
        claim(key)
        let resumed: Bool
        do {
            resumed = try await library.setRefreshPaused(false, recordID: key.recordID, deviceID: key.deviceID)
        } catch XSideError.recordNotFound {
            resumed = false
        } catch {
            Self.logger.error("resume refreshing failed: \(String(describing: error))")
            resumed = false
        }
        release(key)
        await reloadRecords()
        if resumed { onRefreshResumed?(RefreshJob(recordID: key.recordID, deviceID: key.deviceID)) }
    }

    /// Forgets the app on that device ("remove from the list") without touching the device: the
    /// app stays there until it expires. A record left without installation is deleted.
    func removeFromList(_ entry: AppEntry) async {
        let key = entry.id
        guard canManage(entry) else { return }
        claim(key)
        defer { release(key) }
        do {
            try await library.removeInstallation(recordID: key.recordID, deviceID: key.deviceID)
        } catch XSideError.recordNotFound {
        } catch {
            Self.logger.error("remove from list failed: \(String(describing: error))")
            return
        }
        await installationRemoved(key)
    }

    /// The installation left the library: its reminder and notification state go too, and a
    /// record left without any installation is deleted (with its files) once nothing uses it.
    private func installationRemoved(_ key: JobKey) async {
        await reloadRecords()
        onInstallationRemoved?(RefreshJob(recordID: key.recordID, deviceID: key.deviceID))
        if records.first(where: { $0.id == key.recordID })?.installations.isEmpty == true {
            keptEmptyRecords.insert(key.recordID) // dropped by `release`, unless still in use
        }
        await updateAppIDCounter()
    }

    /// Rows with an install or refresh running.
    var busyJobs: Set<RefreshJob> {
        Set(jobs.keys.map { RefreshJob(recordID: $0.recordID, deviceID: $0.deviceID) })
    }

    func canRefresh(_ entry: AppEntry) -> Bool {
        isPipelineReady && !entry.installation.refreshPaused && jobs[entry.id] == nil && !removingDevices.contains(entry.installation.deviceID)
            && devices.contains { $0.id == entry.installation.deviceID && $0.isAvailable }
    }

    /// Row job ownership is counted: the row's state clears only when the last holder releases it.
    private var claims: [JobKey: Int] = [:]

    /// Held while any row is claimed: no idle sleep, no App Nap in the middle of a job.
    @ObservationIgnored private var jobActivity: (any NSObjectProtocol)?

    private func claim(_ key: JobKey, stage: JobStage = .waiting) {
        claims[key, default: 0] += 1
        if jobs[key] == nil { jobs[key] = stage }
        if jobActivity == nil {
            jobActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Installing or refreshing an app")
        }
    }

    private func release(_ key: JobKey) {
        let left = (claims[key] ?? 1) - 1
        claims[key] = left > 0 ? left : nil
        if left <= 0 { jobs[key] = nil }
        if claims.isEmpty, let activity = jobActivity {
            ProcessInfo.processInfo.endActivity(activity)
            jobActivity = nil
        }
        if left <= 0 { dropKeptEmptyRecords() }
        if claims.isEmpty, xcodeSwitchPending {
            xcodeSwitchPending = false
            recheckEnvironment()
        }
    }

    /// The environment as probed now: a queued job asks for it when it actually starts.
    private func currentEnvironment() throws -> SigningEnvironment {
        guard let environment else { throw XSideError.xcodeMissing }
        return try environment.get()
    }

    /// The caller must hold a claim on `key`. `refresh`: see `SideloadPipeline.install`.
    private func run(key: JobKey, device: Device, refresh: Bool = false,
                     automatic: Bool = false,
                     progress: @escaping @MainActor @Sendable (JobStage) -> Void = { _ in }) async throws {
        let job = RefreshJob(recordID: key.recordID, deviceID: key.deviceID)
        // A refresh renews an existing installation; a first install is shown by the install window.
        let wasRefresh = records.first { $0.id == key.recordID }?
            .installations.contains { $0.deviceID == key.deviceID } ?? false
        do {
            let environment: @Sendable () async throws -> SigningEnvironment = { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.currentEnvironment()
            }
            _ = try await pipeline.install(recordID: key.recordID, device: device, environment: environment,
                                           refresh: refresh) { step in
                await MainActor.run {
                    self.jobs[key] = .step(step)
                    progress(.step(step))
                }
            }
        } catch {
            await reloadRecords()
            onJobFinished?(job, error, automatic, wasRefresh)
            throw error
        }
        await reloadRecords()
        onJobFinished?(job, nil, automatic, wasRefresh)
        await updateAppIDCounter()
    }

    // MARK: - Install window flow

    /// Requested `.ipa` files waiting for the current install to finish (oldest first).
    private(set) var queuedIPAs: [URL] = []
    /// Set by the menu-bar label (which has `openWindow`): shows and activates the install window.
    var showInstallWindow: (() -> Void)?
    private(set) var isInstallWindowOpen = false

    /// A request (Finder, drop, button). While an install runs, or its guide is still unseen, the
    /// request is queued, never dropped; otherwise it replaces a flow that hasn't started.
    private func request(_ url: URL) {
        if let current = install, current.isBusy {
            if current.ipa != url && !queuedIPAs.contains(url) { queuedIPAs.append(url) }
            return
        }
        beginFlow(url)
    }

    private func beginFlow(_ url: URL) {
        let flow = InstallFlow(ipa: url)
        install = flow
        autoselectDevice()
        Task {
            do {
                let icon = Self.iconsDir.appendingPathComponent("\(UUID().uuidString).png")
                // The icon is decoded by a child process (this same executable, see `EntryPoint`).
                let helper = Bundle.main.executableURL
                let info = try await IPAImporter.inspect(ipa: url, runner: runner,
                                                         iconDestination: helper == nil ? nil : icon, iconHelper: helper)
                guard install === flow else {
                    try? FileManager.default.removeItem(at: icon) // replaced meanwhile
                    return
                }
                flow.info = info
                flow.appIcon = FileManager.default.fileExists(atPath: icon.path) ? icon : nil
                let existing = records.first { $0.originalBundleID == info.bundleID }
                flow.existing = existing
                flow.draft = OptionsDraft(existing?.options ?? InstallOptions())
                flow.phase = .editing(error: nil)
                autoselectDevice() // the default now depends on where the app is installed
            } catch {
                guard install === flow else { return }
                flow.phase = .rejected(localizedMessage(error))
            }
        }
        refreshDevices()
    }

    /// Starts the next queued request, if any.
    private func advanceQueue() -> Bool {
        guard !queuedIPAs.isEmpty else { return false }
        beginFlow(queuedIPAs.removeFirst())
        return true
    }

    /// Identifier the app is signed with when no custom one is set.
    func defaultBundleID(for flow: InstallFlow) -> String? {
        guard let info = flow.info else { return nil }
        if let existing = flow.existing {
            return BundleIdentifier.defaultSigned(original: existing.originalBundleID, teamID: existing.teamID)
        }
        guard case .success(let env) = environment else { return info.bundleID }
        return BundleIdentifier.defaultSigned(original: info.bundleID, teamID: env.teamID)
    }

    /// True when the draft identifier would register a new App ID.
    func usesNewAppID(_ flow: InstallFlow) -> Bool {
        let custom = flow.draft.bundleID.trimmingCharacters(in: .whitespaces)
        guard !custom.isEmpty else { return false }
        return custom != flow.existing?.signedBundleID
    }

    /// Default targets (see `InstallTargets`), or the user's choice minus the devices gone.
    private func autoselectDevice() {
        guard let flow = install, !flow.isRunning else { return }
        let available = pairedDevices.filter(\.isAvailable).map(\.id)
        let installedOn = Set(flow.existing?.installations.map(\.deviceID) ?? [])
        let selection = InstallTargets.reconcile(flow.deviceIDs, edited: flow.selectionEdited,
                                                 available: available, installedOn: installedOn)
        if selection != flow.deviceIDs { flow.deviceIDs = selection }
    }

    /// Installs on the checked devices, one after another.
    func startInstall() {
        guard let flow = install, !flow.isRunning else { return }
        let targets = flow.deviceIDs.filter { id in
            !removingDevices.contains(id) && devices.contains { $0.id == id && $0.isAvailable }
        }
        guard !targets.isEmpty else { return }
        if let custom = flow.draft.options.customBundleID, !BundleIdentifier.isValid(custom) {
            flow.failure = nil
            flow.phase = .editing(error: XSideError.invalidBundleID(custom).localizedMessage)
            return
        }
        flow.runs = targets.map { id in DeviceRun(deviceID: id, name: devices.first { $0.id == id }?.name ?? id) }
        flow.runOptions = flow.draft.options
        // A new run imports again (the options may have changed); only its later devices reuse it.
        flow.importedRecordID = nil
        flow.guides = []
        flow.shownGuides = []
        flow.failure = nil
        // The Wi-Fi check follows a first install over USB (see `guideIfFirstInstall`, below).
        if targets.count == 1, let device = devices.first(where: { $0.id == targets[0] }) {
            flow.wifiStepPlanned = guideIfFirstInstall(on: device) != nil
                && devicePrefs.wifiRefresh(for: device.id) && device.transport == .usb
        } else {
            flow.wifiStepPlanned = false
        }
        runInstall(flow, on: targets)
    }

    /// "Retry failed": runs again the devices that failed or were cancelled, with the same options.
    func retryFailedInstalls() {
        guard let flow = install, !flow.isRunning, flow.wifiCheck == nil else { return }
        let targets = flow.retryableDeviceIDs
        guard !targets.isEmpty else { return }
        for id in targets { flow.setStatus(.waiting, for: id) }
        runInstall(flow, on: targets)
    }

    /// Installs `targets` (already in `flow.runs`) in order. The first import of the `.ipa` is
    /// reused by the next devices. Each device's failure is kept on its row and the run goes on.
    /// The run's task is kept on the flow for "Cancel install" (`cancelInstall`).
    private func runInstall(_ flow: InstallFlow, on targets: [String]) {
        flow.phase = .running(.preparing)
        flow.cancelRequested = false
        flow.wasCancelled = false
        // Re-install of a known app: claim each device's row now, before any await. Each claim is
        // released when that device is done.
        let recordID = flow.importedRecordID ?? flow.existing?.id
        if let recordID {
            for id in targets { claim(JobKey(recordID: recordID, deviceID: id), stage: id == targets[0] ? .preparing : .waiting) }
        }
        flow.runTask = Task {
            for id in targets {
                if flow.cancelRequested {
                    flow.setStatus(.cancelled, for: id) // never started
                } else {
                    await installOne(flow, on: id)
                }
                if let recordID { release(JobKey(recordID: recordID, deviceID: id)) }
            }
            flow.runTask = nil
            flow.wasCancelled = flow.runs.contains { $0.status == .cancelled }
            if flow.wasCancelled { dropCancelledImport(flow) }
            if !flow.isMultiDevice, case .failed(let failure)? = flow.runs.first?.status {
                flow.failure = failure
                flow.phase = .editing(error: failure.message)
            } else if !flow.isMultiDevice, flow.wasCancelled {
                flow.phase = .editing(error: nil) // the window says "Install cancelled."
            } else {
                flow.phase = .finished
                flow.nextWifiCheck() // the checks collected during the run, one at a time
            }
            flowFinished(flow)
        }
    }

    /// One device of a run. A first install queues its guide and, over USB with Wi-Fi refresh on,
    /// its Wi-Fi check.
    private func installOne(_ flow: InstallFlow, on deviceID: String) async {
        flow.lastStage = .preparing
        flow.phase = .running(.preparing)
        flow.setStatus(.running(.preparing), for: deviceID)
        // Looked up now: the device may have gone (or changed transport) during the earlier ones.
        guard !removingDevices.contains(deviceID),
              let device = devices.first(where: { $0.id == deviceID && $0.isAvailable }) else {
            flow.setStatus(.failed(StepFailure(stage: .preparing, message: localizedMessage(XSideError.deviceUnavailable))),
                           for: deviceID)
            return
        }
        do {
            try await importAndInstall(flow.ipa, on: device, options: flow.runOptions,
                                       importedInto: flow.importedRecordID,
                                       imported: { flow.importedRecordID = $0 },
                                       progress: { stage in
                                           flow.lastStage = stage
                                           flow.phase = .running(stage)
                                           flow.setStatus(.running(stage), for: deviceID)
                                       })
            flow.setStatus(.succeeded, for: deviceID)
            if let guide = guideIfFirstInstall(on: device) {
                flow.guides.append(guide)
                if devicePrefs.wifiRefresh(for: device.id) {
                    if device.transport == .usb {
                        flow.wifiQueue.append(device.id)
                    } else if let i = flow.runs.firstIndex(where: { $0.deviceID == deviceID }) {
                        flow.runs[i].wifiVerified = true // already installed over Wi-Fi
                    }
                }
            }
        } catch {
            // Cancelled: no error shown (the pipeline reports a step stopped by the cancellation as
            // such). Any other error, even after "Cancel install", stays a failure.
            if error is CancellationError {
                flow.setStatus(.cancelled, for: deviceID)
            } else {
                flow.setStatus(.failed(StepFailure(stage: flow.lastStage, message: localizedMessage(error))), for: deviceID)
            }
        }
    }

    /// "Cancel install": cancels the run's task. The device being installed stops at once (its
    /// pipeline job is cancelled, which kills the running tool's process group); the devices still
    /// waiting never start; those already installed stay installed. No confirmation.
    func cancelInstall() {
        guard let flow = install, flow.isRunning, !flow.cancelRequested else { return }
        flow.cancelRequested = true
        for run in flow.runs where run.status == .waiting { flow.setStatus(.cancelled, for: run.deviceID) }
        flow.runTask?.cancel()
    }

    /// A cancelled first install leaves no record behind: the one this run imported is deleted
    /// once nothing uses it, if no device got the app (see `dropKeptEmptyRecords`). A reinstall of
    /// a known app keeps its record and installations as they were.
    private func dropCancelledImport(_ flow: InstallFlow) {
        guard flow.existing == nil, flow.succeededCount == 0, let id = flow.importedRecordID else { return }
        flow.importedRecordID = nil // a new attempt imports again
        keptEmptyRecords.insert(id)
        dropKeptEmptyRecords()
    }

    /// The window may have been closed during the job: bring it back when there is something to
    /// see (an error, a Wi-Fi check, a first-install guide, or the next queued file).
    private func flowFinished(_ flow: InstallFlow) {
        guard install === flow, !isInstallWindowOpen else { return }
        // A run cancelled from the popover has nothing more to say either.
        if flow.phase == .finished || flow.wasCancelled,
           flow.failedDeviceIDs.isEmpty, flow.guideSeen, flow.wifiCheck == nil {
            if !advanceQueue() { install = nil; return }
        }
        showInstallWindow?()
    }

    /// The guide is due after the first successful install on a device. It is marked as shown only
    /// when it is actually displayed (`guideDisplayed`).
    private func guideIfFirstInstall(on device: Device) -> FirstInstallGuide? {
        guard !UserDefaults.standard.bool(forKey: Self.guideKey(device.id)) else { return nil }
        let account = (try? environment?.get())?.identityName ?? "Apple Development"
        return FirstInstallGuide(deviceID: device.id, accountName: account,
                                 needsDeveloperMode: device.developerModeEnabled == false)
    }

    // MARK: Wi-Fi check

    /// Polls the device list once and feeds the check; called every ~3 s by the visible step.
    func pollWifiCheck(_ flow: InstallFlow) async {
        await listDevices()
        evaluateWifiCheck(flow)
    }

    func evaluateWifiCheck(_ flow: InstallFlow) {
        guard install === flow, var check = flow.wifiCheck, let id = flow.wifiDeviceID else { return }
        check.observe(devices.first { $0.id == id }, at: Date())
        if check.status == .ok {
            if let i = flow.runs.firstIndex(where: { $0.deviceID == id }) { flow.runs[i].wifiVerified = true }
            flow.nextWifiCheck()
        } else {
            flow.wifiCheck = check
        }
    }

    /// "Retry": a new 60 s window.
    func retryWifiCheck(_ flow: InstallFlow) {
        guard install === flow, flow.wifiCheck != nil else { return }
        flow.wifiCheck = WifiCheck(startedAt: Date())
        evaluateWifiCheck(flow)
    }

    /// "Skip": this device's step ends, settings untouched; the next device's check follows.
    func skipWifiCheck(_ flow: InstallFlow) {
        guard install === flow else { return }
        flow.nextWifiCheck()
    }

    /// "I'll refresh over USB": Wi-Fi refresh off for this device, its step ends.
    func chooseUSBRefresh(_ flow: InstallFlow) {
        guard install === flow else { return }
        if let id = flow.wifiDeviceID { setWifiRefresh(false, for: id) }
        flow.nextWifiCheck()
    }

    func guideDisplayed(_ guide: FirstInstallGuide) {
        UserDefaults.standard.set(true, forKey: Self.guideKey(guide.deviceID))
        if let flow = install, flow.guides.contains(guide) { flow.shownGuides.insert(guide.deviceID) }
    }

    private static func guideKey(_ deviceID: String) -> String { "guideShown.\(deviceID)" }

    /// "Done" / "Cancel": moves to the next queued file. Returns false when the window can close.
    func dismissFlow() -> Bool {
        guard install?.isRunning != true, install?.wifiCheck == nil else { return true }
        if advanceQueue() { return true }
        install = nil
        return false
    }

    func installWindowAppeared() { isInstallWindowOpen = true }

    /// Closed with the window button. A running install keeps going (its row shows progress) and
    /// reopens the window when it ends if needed; queued files are never dropped.
    /// After the run, closing ends the flow: the Wi-Fi steps are skipped, and guides still waiting
    /// behind them are dropped without being marked as shown (the device's next install shows
    /// its guide), instead of keeping a busy flow with no window.
    func installWindowDisappeared() {
        isInstallWindowOpen = false
        install?.skipAllWifiChecks() // closing the window skips the Wi-Fi steps
        if let flow = install, !flow.isRunning { flow.guides.removeAll { !flow.shownGuides.contains($0.deviceID) } }
        guard install?.isBusy != true else { return }
        if advanceQueue() {
            showInstallWindow?()
        } else {
            install = nil
        }
    }
}

/// Where XSide keeps its files. Nothing here is specific to a Mac or an account.
private struct Paths {
    let root: URL
    /// Scratch space of the jobs, emptied at launch.
    let work: URL
    let provisioningWork: URL
    let jobsWork: URL
    let template: URL
    let xcodeProfileDirs: [URL]

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent(LibraryLocation.folderName(bundleID: Bundle.main.bundleIdentifier),
                                              isDirectory: true)
        work = root.appendingPathComponent("work", isDirectory: true)
        provisioningWork = work.appendingPathComponent("provisioning", isDirectory: true)
        jobsWork = work.appendingPathComponent("jobs", isDirectory: true)
        template = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("ProvisioningTemplate", isDirectory: true)
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        xcodeProfileDirs = [
            library.appendingPathComponent("Developer/Xcode/UserData/Provisioning Profiles", isDirectory: true),
            library.appendingPathComponent("MobileDevice/Provisioning Profiles", isDirectory: true),
        ]
    }
}

// MARK: - Menu-bar activity

extension AppModel {
    /// What XSide is doing right now, for the animated menu-bar icon and its tooltip; nil when idle.
    /// "Refreshing YouTube on iPhone…", with "(+2)" when more jobs run.
    var activitySummary: String? {
        #if DEBUG
        // Debug-only: XSIDE_FAKE_BUSY=1 shows the animated icon without a real job.
        if ProcessInfo.processInfo.environment["XSIDE_FAKE_BUSY"] == "1" { return L("menuBar.working.generic") }
        #endif
        var items: [String] = []
        for key in jobs.keys.sorted(by: { $0.recordID.uuidString < $1.recordID.uuidString }) {
            let record = records.first { $0.id == key.recordID }
            let app = record.map { $0.options.displayName ?? $0.displayName } ?? "XSide"
            let device = devices.first { $0.id == key.deviceID }?.name ?? cachedNames[key.deviceID]
                ?? L("notification.refreshed.genericDevice")
            let installing = install.map { $0.isRunning && ($0.importedRecordID ?? $0.existing?.id) == key.recordID } ?? false
            if installing {
                items.append(L("menuBar.working.installOn", app, device))
            } else {
                items.append(L(uninstalling.contains(key) ? "menuBar.working.uninstall" : "menuBar.working.refresh",
                               app, device))
            }
        }
        if items.isEmpty, let flow = install, flow.isRunning {
            items.append(L("menuBar.working.install", flow.info?.name ?? flow.ipa.deletingPathExtension().lastPathComponent))
        }
        if items.isEmpty, isCreatingCertificate { items.append(L("menuBar.working.certificate")) }
        guard let first = items.first else { return nil }
        return items.count > 1 ? L("menuBar.working.more", first, items.count - 1) : first
    }
}
