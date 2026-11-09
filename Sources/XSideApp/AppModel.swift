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

struct JobKey: Hashable, Codable {
    let recordID: UUID
    let deviceID: String
}

/// Where XSide stands on an installation's crashes.
enum CrashCheck: Equatable {
    case checking
    case found(CrashFinding)
    /// No crash in the time looked at.
    case none
    /// The device's crash logs couldn't be read (the localized reason).
    case failed(String)
}

/// A crash, explained, with its log made fit to share.
struct CrashFinding: Equatable {
    let diagnosis: CrashDiagnosis
    /// Sanitized and redacted: ready for the window and the report archive.
    let log: String
    let fileName: String
    /// Found by the check after an install (the panel's row says so), not asked for.
    let afterInstall: Bool
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
    var notifies = true
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
                retryQueuedRefresh()
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
        didSet {
            LogStore.shared.register(accountName, as: "account")
            #if DEBUG
            if Self.isDemo, accountName != nil, accountName != Self.demoAccount { accountName = Self.demoAccount }
            #endif
        }
    }

    #if DEBUG
    /// Debug-only: XSIDE_DEMO=1 replaces personal details on screen (device names, account,
    /// certificate), for screenshots.
    static let isDemo = ProcessInfo.processInfo.environment["XSIDE_DEMO"] == "1"
    static let demoAccount = "you@icloud.com"
    /// The made-up apps of the demo mode: name, icon symbol and color, days left.
    static let demoApps: [(id: UUID, name: String, symbol: String, color: (Double, Double, Double), daysLeft: Double)] = [
        (UUID(uuidString: "D0D0D0D0-0000-0000-0000-000000000001")!, "Lumen", "camera.aperture", (1.0, 0.55, 0.2), 4.6),
        (UUID(uuidString: "D0D0D0D0-0000-0000-0000-000000000002")!, "Tempo", "music.note", (0.2, 0.75, 0.45), 1.4),
    ]
    #endif

    /// The signing certificate's name as shown (fictitious in the debug demo mode).
    var shownIdentityName: String? {
        #if DEBUG
        if Self.isDemo, signingEnvironment != nil { return "Apple Development: \(Self.demoAccount) (ABCDE12345)" }
        #endif
        return signingEnvironment?.identityName
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
    /// When each App ID used this week frees up, soonest first (estimate, like the count).
    private(set) var appIDReleases: [Date] = []
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
    /// The icon of each app (popover rows).
    let icons: AppIcons
    /// XSide's own updates (Sparkle).
    let updater = Updater()
    /// The row a notification was about: it glows for a few seconds once the panel shows it.
    private(set) var highlightedRow: JobKey?

    func highlight(_ key: JobKey) {
        highlightedRow = key
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.highlightedRow == key { self?.highlightedRow = nil }
        }
    }

    /// The page Settings shows: set before opening it (a signing problem opens on its fix).
    var settingsPane = SettingsPane.general
    /// The app Settings > Mes apps shows (set by the "…" menu of a row); nil: the first one.
    var settingsApp: JobKey?
    /// Runs every tool with `DEVELOPER_DIR` set to the Xcode in use (see `resolveXcode`).
    private let runner: ProcessRunner
    /// Without the override: what `xcode-select -p` itself points to.
    private let plainRunner = ProcessRunner()
    /// The developer directory passed as `DEVELOPER_DIR`, nil to inherit XSide's environment.
    private let developerDirOverride = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let paths: Paths
    /// Where the library lives (the `xside` tool's key is written there, see `CLIBridge.Key`).
    var libraryRoot: URL { paths.root }
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
    /// The panel just opened.
    var onPopoverShown: (() -> Void)?
    /// A device's notifications were turned on or off (its expiry reminders follow).
    var onDeviceNotificationsChanged: (() -> Void)?
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

    /// `startsServices`: false only for the debug snapshot harness (`SnapshotRenderer`): nothing is
    /// cleaned, loaded, probed or published.
    init(startsServices: Bool = true) {
        let developerDirOverride = developerDirOverride
        runner = ProcessRunner(environment: {
            developerDirOverride.withLock { $0 }.map { ["DEVELOPER_DIR": $0] } ?? [:]
        })
        paths = Paths()
        library = AppLibrary(root: paths.root)
        icons = AppIcons(library: library, runner: runner)
        prefsStore = DevicePrefsStore(libraryRoot: paths.root)
        devicePrefs = prefsStore.load()
        if startsServices {
            // Icons pulled out of earlier sessions' `.ipa` files.
            try? FileManager.default.removeItem(at: Self.iconsDir)
            // Leftovers of jobs interrupted by a quit or a crash (extracted apps, template builds).
            // No job can be running yet.
            try? FileManager.default.removeItem(at: paths.work)
        }
        pipeline = SideloadPipeline(
            library: library,
            provisioner: Provisioner(runner: runner, templateDir: paths.template, workDir: paths.provisioningWork,
                                     cacheDirs: paths.xcodeProfileDirs),
            resigner: Resigner(runner: runner,
                               welcomeDylib: Self.featuresOff ? nil : Bundle.main.url(forResource: "XSideWelcome", withExtension: "dylib"),
                               settingsSection: Self.featuresOff ? nil : Self.settingsSection,
                               welcome: { _ in AppModel.welcomePayload() },
                               textLanguage: { AppModel.textLanguage($0) }),
            installer: Installer(runner: runner),
            workRoot: paths.jobsWork, now: { Date() }, macIsBeta: XcodeLauncher.macIsBeta,
            inAppDefaults: { AppModel.inAppDefaults(at: $0) },
            withoutXSideFeaturesByDefault: { AppModel.withoutXSideFeaturesByDefault })
        // An update waits while an install or a refresh runs (`release` retries it after).
        updater.isBusy = { [unowned self] in !self.claims.isEmpty || self.install?.isRunning == true }
        if startsServices { Task { await start() } }
    }

    #if DEBUG
    /// Snapshot harness only (`SnapshotRenderer`): shows these apps and devices as if loaded, with
    /// the apps in `live` open on their device. Nothing is saved.
    func showSnapshot(records: [AppRecord], devices: [Device], live: Set<JobKey>, now: Date) {
        self.records = records
        self.devices = devices
        for key in live { channelSeen[key] = now }
        liveInstallations = live
        appIDsRemaining = 7
        appIDReleases = [now.addingTimeInterval(2 * 86_400), now.addingTimeInterval(4 * 86_400), now.addingTimeInterval(5 * 86_400)]
    }
    #endif

    /// Debug-only: XSIDE_NO_FEATURES=1 installs apps without anything XSide adds (no library, no
    /// Settings section), to tell an app's own behavior from XSide's.
    private static var featuresOff: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["XSIDE_NO_FEATURES"] == "1"
        #else
        return false
        #endif
    }

    /// The "Réglages XSide" section of the app's page in the iOS Settings app: plain text in the
    /// installation's language, translated by iOS in the languages the app already has. Written at each install and refresh, from the installation's
    /// own values (`facts`, given by the pipeline). The texts are the Mac's; the library rewrites
    /// them in the device's language at launch.
    nonisolated static func settingsSection(_ profile: ProvisioningProfile, _ facts: InstallationFacts?) -> SettingsSection {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(appLocale)
        let now = Date()
        let outcome = facts?.lastRefreshOutcome
        return SettingsSection.xside(
            validUntil: profile.expirationDate.formatted(style), refreshedOn: (facts?.signedAt ?? now).formatted(style),
            version: facts?.appVersion ?? "—",
            installedOn: (facts?.firstInstalledAt ?? now).formatted(style),
            connection: facts?.lastCheckIn.map { "✓ " + $0.formatted(style) } ?? "—",
            lastRefresh: outcome.map { ($0.succeeded ? "✓ " : "✕ ") + $0.at.formatted(style) } ?? "—",
            inApp: facts?.inApp ?? inAppDefaults(at: now), language: textLanguage(facts))
    }

    /// The language of the plain texts written into the app (see `InAppSettings.textLanguage`).
    nonisolated static func textLanguage(_ facts: InstallationFacts?) -> String {
        (facts?.inApp ?? inAppDefaults(at: Date())).textLanguage(macPreferences: Locale.preferredLanguages)
    }

    /// XSide-in-app settings of an installation that has none yet: the Mac defaults (Settings >
    /// Module XSide dans les apps), automatic refresh on.
    nonisolated static func inAppDefaults(at date: Date) -> InAppSettings {
        func f<V>(_ v: V) -> Field<V> { Field(value: v, changedAt: date, changedBy: .mac) }
        let language = UserDefaults.standard.string(forKey: inAppLanguageKey).flatMap(MessageLanguage.init) ?? .automatic
        return InAppSettings(showValidity: f(setting(inAppShowValidityKey)), alertLate: f(setting(inAppAlertLateKey)),
                             refreshCard: f(setting(inAppRefreshCardKey)), reminder: f(setting(deviceReminderKey)),
                             language: f(language), autoRefresh: f(true))
    }

    /// Writes the Mac defaults of new installs (Settings > Module XSide dans les apps). Automatic refresh
    /// isn't one: a new install is always refreshed.
    static func setInAppDefaults(_ s: InAppSettings) {
        let defaults = UserDefaults.standard
        defaults.set(s.showValidity.value, forKey: inAppShowValidityKey)
        defaults.set(s.alertLate.value, forKey: inAppAlertLateKey)
        defaults.set(s.refreshCard.value, forKey: inAppRefreshCardKey)
        defaults.set(s.reminder.value, forKey: deviceReminderKey)
        defaults.set(s.language.value.rawValue, forKey: inAppLanguageKey)
    }

    /// "Installer les apps sans les fonctionnalités XSide" (off by default): apps that made no
    /// choice of their own are signed as they came.
    nonisolated static var withoutXSideFeaturesByDefault: Bool {
        UserDefaults.standard.bool(forKey: installWithoutFeaturesKey)
    }

    // MARK: - Startup

    private func start() async {
        // Installations saved by an older XSide get their XSide-in-app settings (the Mac defaults).
        do { try await library.seedInAppSettings(reminder: Self.setting(Self.deviceReminderKey), at: Date()) } catch {
            Self.logger.error("seeding in-app settings failed: \(String(describing: error))")
        }
        await reloadRecords()
        refreshDevices()
        await probeEnvironment()
        startChannel()
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
    /// Xcode apps (path and build) found usable: checked once.
    @ObservationIgnored private var readyXcodes: Set<String> = []
    /// Xcode apps found not usable yet, and until when that answer holds: not checked again at
    /// every probe (each check is an xcodebuild run).
    @ObservationIgnored private var unreadyUntil: [String: Date] = [:]
    private static let unreadyRecheck: TimeInterval = 10 * 60

    /// That Xcode's license is accepted and its first launch done (`XcodeLocator.readinessChecks`).
    /// A "not yet" is kept 10 minutes, or until XSide comes forward (the user may have just
    /// opened Xcode to accept it).
    private func isReady(_ xcode: XcodeInstall) async -> Bool {
        let key = "\(xcode.developerDir.path)#\(xcode.build)"
        if readyXcodes.contains(key) { return true }
        if let until = unreadyUntil[key], until > Date() { return false }
        for check in XcodeLocator.readinessChecks(xcode.developerDir) {
            let result = try? await CommandEnvironment.withDeveloperDir(xcode.developerDir) {
                try await plainRunner.run(check.executable, check.arguments, cwd: nil, timeout: .seconds(30))
            }
            guard result?.status == 0 else {
                unreadyUntil[key] = Date().addingTimeInterval(Self.unreadyRecheck)
                return false
            }
        }
        unreadyUntil[key] = nil
        readyXcodes.insert(key)
        return true
    }

    /// XSide came forward: a "not ready" Xcode is checked again at the next probe.
    func forgetUnreadyXcodes() { unreadyUntil.removeAll() }

    /// macOS beta with a release Xcode, which may stop working on it: warned, never blocking.
    /// Computed once per probe.
    private(set) var macBetaWithReleaseXcode = false
    /// Jobs can run: the signing environment probed OK.
    var isPipelineReady: Bool { signingEnvironment != nil }

    // MARK: - Devices

    /// The popover was shown or hidden (see `StatusPopover`).
    func popoverVisibilityChanged(_ visible: Bool) {
        guard visible != isPopoverOpen else { return }
        isPopoverOpen = visible
        updateOnboardingPoller()
        if visible {
            refreshDevices()
            recheckEnvironment()
            onPopoverShown?()
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
            #if DEBUG
            // Debug-only: XSIDE_DEMO=1 names devices by their kind ("iPhone"), for screenshots.
            if Self.isDemo {
                listed = listed.map {
                    Device(id: $0.id, udid: $0.udid, name: $0.kind == .iPad ? "iPad" : "iPhone", model: $0.model, kind: $0.kind,
                           transport: $0.transport, isPaired: $0.isPaired, isAvailable: $0.isAvailable,
                           developerModeEnabled: $0.developerModeEnabled, osVersion: $0.osVersion,
                           productType: $0.productType, marketingName: $0.marketingName)
                }
            }
            #endif
            let changed = listed != devices
            devices = listed
            rememberNames(devices)
            autoselectDevice()
            if changed { onNeedsEvaluation?() }
            retryQueuedRefresh()
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
                unhide(device.id) // paired again on purpose: shown again
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
        // A removed device stays hidden while it has no app (it is still paired, so listed).
        let shown = pairedDevices.filter { d in
            !devicePrefs.isHidden(d.id) || entries.contains { $0.installation.deviceID == d.id }
        }
        var groups = shown.map { d in
            DeviceGroup(id: d.id, device: d, name: d.name, kind: d.kind,
                        apps: entries.filter { $0.installation.deviceID == d.id },
                        wifiRefresh: devicePrefs.wifiRefresh(for: d.id), notifies: devicePrefs.notifies(d.id),
                        needsUSB: devicePrefs.isWifiBlocked(d), canRemove: canRemoveDevice(d.id))
        }
        let known = Set(pairedDevices.map(\.id))
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
        #if DEBUG
        // Debug-only demo: two made-up apps on the first device, for screenshots. Display only:
        // the refresh engine reads the library, which doesn't have them.
        if Self.isDemo, let first = groups.indices.first {
            let device = groups[first].id
            let fake = Self.demoApps.map { app in
                AppEntry(record: AppRecord(id: app.id, displayName: app.name, originalBundleID: "com.example.\(app.name.lowercased())",
                                           signedBundleID: "com.example.\(app.name.lowercased())", ipaPath: "",
                                           options: InstallOptions(), installations: [], teamID: ""),
                         installation: Installation(deviceID: device, installedAt: Date(),
                                                    expiresAt: Date().addingTimeInterval(app.daysLeft * 86_400)))
            }
            let g = groups[first]
            groups[first] = DeviceGroup(id: g.id, device: g.device, name: g.name, kind: g.kind, apps: g.apps + fake,
                                        wifiRefresh: g.wifiRefresh, needsUSB: g.needsUSB, canRemove: g.canRemove)
        }
        #endif
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

    /// XSide's notifications about that device's apps, on or off.
    func setNotifies(_ on: Bool, for deviceID: String) {
        var updated = devicePrefs
        updated.setNotifies(on, for: deviceID)
        savePrefs(updated)
        onDeviceNotificationsChanged?()
    }

    /// Wi-Fi refresh for devices XSide doesn't know yet. Known ones (listed now, or holding an
    /// app) keep what they have.
    func setNewDevicesWifi(_ on: Bool) {
        let known = Set(devices.map(\.id) + records.flatMap { $0.installations.map(\.deviceID) })
        var updated = devicePrefs
        updated.setNewDevicesWifi(on, keeping: Array(known))
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
        // Still paired, it would show again at once: hidden until an app is installed on it.
        prefs.setHidden(true, deviceID)
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

    /// The library was read once: until then, "no app" isn't known to be true (just launched).
    private(set) var hasLoadedRecords = false

    func reloadRecords() async {
        records = await library.records()
        pushToWatches() // the Mac's changes reach the apps open in front at once (device feedback 4)
        hasLoadedRecords = true
        updateAttention()
        icons.backfill(records) // once per launch
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
        appIDReleases = AppIDCounter.releases(profiles, teamID: env.teamID, now: Date(), firstUse: firstUse)
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
                          inApp: InAppDraft? = nil, duoCompatibility: Bool? = nil,
                          importedInto recordID: UUID? = nil,
                          imported: @MainActor (UUID) -> Void = { _ in },
                          progress: @escaping @MainActor @Sendable (JobStage) -> Void = { _ in },
                          duoOutcome: @escaping @MainActor @Sendable (DuoOutcome) -> Void = { _ in }) async throws -> AppRecord {
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
            if let flow = install, flow.ipa == ipa, let icon = flow.appIcon { icons.keep(icon, for: record.id) }
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
        try await run(key: key, device: device, inApp: inApp, duoCompatibility: duoCompatibility, progress: progress,
                      duoOutcome: duoOutcome)
        return records.first { $0.id == record.id } ?? record
    }

    /// Starts a refresh of one row unless it is already running. Returns false when nothing started.
    @discardableResult
    func refreshNow(_ job: RefreshJob, automatic: Bool = false) -> Bool {
        startRefresh(job, automatic: automatic) != nil
    }

    /// `refreshNow`, returning the running job: its value is the error it failed with, nil on
    /// success. Nil when nothing started.
    private func startRefresh(_ job: RefreshJob, automatic: Bool) -> Task<(any Error)?, Never>? {
        let key = JobKey(recordID: job.recordID, deviceID: job.deviceID)
        guard signingEnvironment != nil, jobs[key] == nil, !removingDevices.contains(job.deviceID),
              !isPaused(job), let device = devices.first(where: { $0.id == job.deviceID }) else { return nil }
        claim(key) // before the task starts, so the row can't be claimed twice
        return Task {
            defer { release(key) }
            do {
                try await run(key: key, device: device, refresh: true, automatic: automatic)
                return nil
            } catch {
                return error
            }
        }
    }

    // MARK: - Local network channel (the apps talk to XSide)

    @ObservationIgnored private var channelServer: ChannelServer?
    /// Nonces of the requests accepted lately, so none can be replayed (one cache per installation).
    @ObservationIgnored private var channelNonces = ChannelNonces()
    /// The last authenticated request from each installation in this run (check-ins that change
    /// nothing aren't written to the library): says when the app is open on its device right now
    /// (device feedback 3, E3).
    private(set) var channelSeen: [JobKey: Date] = [:]
    /// The poll interval each app's last check-in stated (device feedback 5, G3: 45 s in Low
    /// Power Mode), so "open, live" lasts until its next poll. Absent: not said (15 s).
    @ObservationIgnored private var channelPollEvery: [JobKey: TimeInterval] = [:]
    /// The open watches (device feedback 4): while an app is in front, the Mac's changes to its
    /// installation are written to it at once (`pushToWatches`, after each library reload).
    @ObservationIgnored private let channelWatches = ChannelWatches<UUID>()
    /// Watches whose connection ended before they were registered (see `holdWatch`), each kept a
    /// minute (review D–G, minor 5).
    @ObservationIgnored private var endedWatchTokens = EndedWatchTokens<UUID>()
    /// The installations whose app is open on its device right now (`ReachabilityStatus.isLive`:
    /// a watch is open, or a check-in came within one poll interval and a margin). Observed by Settings > My apps, so the
    /// status line flips on its own when the app leaves the screen; re-evaluated on each watch
    /// change, each request and every 2 s (`channelTicker`).
    private(set) var liveInstallations: Set<JobKey> = []
    @ObservationIgnored private var channelTicker: Task<Void, Never>?
    private static let channelLogger = Log("channel")
    /// How long a refresh asked from the phone keeps its connection waiting for the outcome.
    private static let refreshOutcomeWait: Duration = .seconds(120)

    /// Publishes the channel on the local network while XSide runs (not in the debug mode that
    /// installs apps without XSide's features: they have nothing to talk with).
    private func startChannel() {
        guard channelServer == nil, !Self.featuresOff else { return }
        let server = ChannelServer { [weak self] line, send, hold in
            await self?.handleChannelLine(line, send: send, hold: hold)
        }
        channelServer = server
        server.start()
        // Keep-alives on the watches, and the "app open" status ending on its own.
        channelTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.channelWatches.keepAlive(now: Date())
                self.updateLiveInstallations()
            }
        }
    }

    func stopChannel() {
        channelServer?.stop()
        channelServer = nil
        channelTicker?.cancel()
        channelTicker = nil
    }

    /// Whether the app is open on that device now (see `liveInstallations`).
    func isLive(_ key: JobKey) -> Bool { liveInstallations.contains(key) }

    /// Held while an app keeps a watch open: no App Nap, so the 2 s ticker (keep-alives every 25 s,
    /// the phone gives up after 60 s of silence) isn't stretched while XSide has no window. Idle
    /// sleep stays allowed (review D–G, minor 6).
    @ObservationIgnored private var watchActivity: (any NSObjectProtocol)?

    private func updateWatchActivity() {
        let watching = !channelWatches.installationIDs.isEmpty
        if watching, watchActivity == nil {
            watchActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "An app keeps a live connection to XSide")
        } else if !watching, let activity = watchActivity {
            ProcessInfo.processInfo.endActivity(activity)
            watchActivity = nil
        }
    }

    /// `liveInstallations` from the watches and the last check-ins; assigned only when it changes.
    private func updateLiveInstallations(now: Date = Date()) {
        updateWatchActivity()
        var live: Set<JobKey> = []
        for record in records {
            for installation in record.installations {
                let key = JobKey(recordID: record.id, deviceID: installation.deviceID)
                let id = ChannelEnvelope.installationID(recordID: record.id, deviceID: installation.deviceID)
                let seen = [installation.lastCheckIn, channelSeen[key]].compactMap { $0 }.max()
                if ReachabilityStatus.isLive(watching: channelWatches.isWatched(id), lastSeen: seen, now: now,
                                             pollEvery: channelPollEvery[key]) {
                    live.insert(key)
                }
            }
        }
        if live != liveInstallations { liveInstallations = live }
    }

    /// Writes to each open watch what changed in its installation since its last line: a Mac edit,
    /// a pause or resume (from the panel, the CLI or its end), a refresh outcome. Runs after every
    /// library reload, in the same turn as the change it sees.
    private func pushToWatches() {
        let now = Date()
        for id in channelWatches.installationIDs {
            guard let found = Self.installation(channelID: id, in: records),
                  let state = ChannelWatchState(found.installation) else { continue }
            if channelWatches.update(id, to: state, now: now) {
                Self.channelLogger.notice("channel: live update written to the watch of \(found.recordID) on \(found.installation.deviceID)")
            }
        }
    }

    private static func installation(channelID: String, in records: [AppRecord]) -> (recordID: UUID, installation: Installation)? {
        for record in records {
            for installation in record.installations
            where ChannelEnvelope.installationID(recordID: record.id, deviceID: installation.deviceID) == channelID {
                return (record.id, installation)
            }
        }
        return nil
    }

    /// A watch whose `watch` request authenticated and whose check-in was stored: held open by the
    /// server if a slot is left, then its first line (`first`, the check-in's reply) and what changed
    /// meanwhile are written. False when the server refused it (answer it as a check-in).
    private func holdWatch(installationID: String, nonce: String, secret: Data, first: ChannelWatchState,
                           key: JobKey, hold: ChannelServer.Hold) async -> Bool {
        let token = UUID()
        let push = await hold(installationID) { [weak self] in
            Task { @MainActor in self?.watchEnded(token, key: key) }
        }
        guard let push else { return false }
        do {
            if let replaced = try channelWatches.open(token, installationID: installationID, nonce: nonce, secret: secret,
                                                      first: first, now: Date(), send: push) {
                endedWatchTokens.take(replaced)
            }
        } catch {
            Self.channelLogger.error("channel: watch not opened: \(String(describing: error))")
            return true // held: its connection closes at its lifetime, or when the phone gives up
        }
        // Its connection may have ended while this waited for the server.
        if endedWatchTokens.take(token) { channelWatches.close(token) }
        Self.channelLogger.notice("channel: watch open for \(key.recordID) on \(key.deviceID)")
        pushToWatches() // a change stored while the watch was being set up
        updateLiveInstallations()
        return true
    }

    private func watchEnded(_ token: UUID, key: JobKey) {
        if channelWatches.close(token) == nil {
            endedWatchTokens.insert(token) // not registered yet (see `holdWatch`), or already replaced
        } else {
            Self.channelLogger.notice("channel: watch closed for \(key.recordID) on \(key.deviceID)")
        }
        updateLiveInstallations()
    }

    /// One request from an app (see `ChannelHandler`): only the installation that signed it can be
    /// read or changed, and only its settings, pause and refresh.
    private func handleChannelLine(_ line: Data, send: @escaping ChannelServer.Send,
                                   hold: @escaping ChannelServer.Hold) async {
        guard let envelope = try? ChannelEnvelope.decode(line: line) else {
            Self.channelLogger.info("channel: malformed request ignored")
            return
        }
        let found = await library.installation(channelID: envelope.installationID)
        let now = Date()
        let received = ChannelHandler.receive(line: line, now: now, nonces: &channelNonces) { id in
            id == envelope.installationID ? found?.installation.channelSecret : nil
        }
        guard case let .request(installationID, nonce, request) = received, let found,
              let secret = found.installation.channelSecret else {
            Self.channelLogger.notice("channel: request rejected (unknown installation, bad signature, stale or replayed)")
            await send(ChannelHandler.rejectedLine)
            return
        }
        let job = RefreshJob(recordID: found.recordID, deviceID: found.installation.deviceID)
        let key = JobKey(recordID: found.recordID, deviceID: found.installation.deviceID)
        channelSeen[key] = now
        // Each check-in states the interval to its next poll (an older dylib's says nothing: 15 s);
        // a refresh or a watch keeps what the last check-in said.
        if case .checkIn = request { channelPollEvery[key] = request.pollEvery.map(TimeInterval.init) }
        updateLiveInstallations(now: now)
        let reply: (ChannelReply) async -> Void = { answer in
            do {
                await send(try ChannelHandler.replyLine(answer, installationID: installationID, requestNonce: nonce, secret: secret))
            } catch {
                Self.channelLogger.error("channel: reply not sealed: \(String(describing: error))")
            }
        }
        let (answer, update) = ChannelHandler.handle(request, installation: found.installation, now: now,
                                                     reminder: Self.setting(Self.deviceReminderKey))
        Self.channelLogger.notice("channel: \(Self.describe(request)) from \(job.deviceID) for \(found.recordID)")
        switch update {
        case .none:
            await reply(answer)
        case let .merged(settings, checkIn, outcome):
            // What this reply changes on the phone (device feedback 3, E2): a Mac edit shows here.
            if let sent = request.checkInReport?.settings, case let .settings(replied, _, _) = answer {
                let changed = ChannelHandler.fieldsChanged(for: sent, by: replied)
                Self.channelLogger.notice("channel: settings reply for \(found.recordID) on \(job.deviceID): changed fields \(changed.isEmpty ? "none" : changed.map { "\($0.rawValue)=\(Self.describe(replied, $0))" }.joined(separator: ", "))")
            }
            do {
                let change = try await library.applyCheckIn(settings, checkIn: checkIn, outcome: outcome,
                                                             recordID: job.recordID, deviceID: job.deviceID)
                await reloadRecords()
                if let paused = change { pauseChanged(job, paused: paused) }
            } catch {
                Self.channelLogger.error("channel: check-in not stored: \(String(describing: error))")
            }
            // A watch (only ever an authenticated one) stays open; refused, it is a plain check-in.
            if ChannelHandler.watchRequested(received) != nil, case let .settings(first, lastRefresh, pausedUntil) = answer,
               await holdWatch(installationID: installationID, nonce: nonce, secret: secret,
                               first: ChannelWatchState(settings: first, lastRefresh: lastRefresh, pausedUntil: pausedUntil),
                               key: key, hold: hold) {
                return
            }
            await reply(answer) // the phone's view is right either way
        case let .paused(paused, by):
            do {
                if try await library.setRefreshPaused(paused, recordID: job.recordID, deviceID: job.deviceID, by: by, at: now) {
                    await reloadRecords()
                    pauseChanged(job, paused: paused)
                }
            } catch {
                Self.channelLogger.error("channel: pause not stored: \(String(describing: error))")
            }
            await reply(answer)
        case .refreshRequested:
            // Checked again on the installation as stored now: paused since the handler's snapshot
            // says so (rather than "busy"), and another phone request may have started meanwhile.
            guard let fresh = await library.installation(channelID: installationID)?.installation else {
                await reply(.deviceUnreachable)
                return
            }
            switch refreshFromDevice(job, stored: fresh, now: Date()) {
            case .failure(let refusal):
                Self.channelLogger.notice("channel: refresh not started: \(Self.describe(refusal.reply))")
                await reply(refusal.reply)
            case .success(let task):
                do {
                    try await library.markDeviceRefreshRequest(at: Date(), recordID: job.recordID, deviceID: job.deviceID)
                } catch {
                    Self.channelLogger.error("channel: refresh request not recorded: \(String(describing: error))")
                }
                await reply(.accepted)
                if let outcome = await waitForOutcome(task) { await reply(outcome) }
            }
        }
    }

    private struct Refusal: Error { let reply: ChannelReply }

    /// A refresh asked from the phone: the normal manual refresh, or why it can't start.
    /// `stored`: the installation as the library holds it now.
    private func refreshFromDevice(_ job: RefreshJob, stored: Installation,
                                   now: Date) -> Result<Task<(any Error)?, Never>, Refusal> {
        let key = JobKey(recordID: job.recordID, deviceID: job.deviceID)
        if stored.refreshPaused || isPaused(job) {
            return .failure(Refusal(reply: .paused(by: stored.pausedBy ?? .mac)))
        }
        if jobs[key] != nil || ChannelHandler.phoneRefreshTooSoon(stored, now: now) {
            return .failure(Refusal(reply: .busy))
        }
        guard let device = devices.first(where: { $0.id == job.deviceID }), device.isAvailable,
              !removingDevices.contains(job.deviceID) else { return .failure(Refusal(reply: .deviceUnreachable)) }
        guard signingEnvironment != nil else {
            return .failure(Refusal(reply: .failed(reasonKey: environmentError?.key ?? XSideError.xcodeMissing.key)))
        }
        guard let task = startRefresh(job, automatic: false) else { return .failure(Refusal(reply: .busy)) }
        return .success(task)
    }

    /// The refresh's outcome line, or nil when it takes longer than the phone waits. A job stopped
    /// by the user fails with the reason key "cancelled".
    private func waitForOutcome(_ task: Task<(any Error)?, Never>) async -> ChannelReply? {
        final class Once {
            var continuation: CheckedContinuation<ChannelReply?, Never>?
            var timer: Task<Void, Never>?
            func resume(_ value: ChannelReply?) {
                timer?.cancel() // no 2-minute sleeper left behind once the outcome is in
                timer = nil
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            once.timer = Task { @MainActor in
                try? await Task.sleep(for: Self.refreshOutcomeWait)
                if !Task.isCancelled { once.resume(nil) }
            }
            Task { @MainActor in
                let error = await task.value
                once.resume(error.map(Self.outcomeReply) ?? .refreshed)
            }
        }
    }

    private static func outcomeReply(_ error: any Error) -> ChannelReply {
        if error is CancellationError { return .failed(reasonKey: "cancelled") }
        return .failed(reasonKey: (error as? XSideError)?.key ?? "unknown")
    }

    /// The pause changed from the phone: reminders and notification state follow, as from the panel.
    private func pauseChanged(_ job: RefreshJob, paused: Bool) {
        if paused { onInstallationRemoved?(job) } else { onRefreshResumed?(job) }
    }

    /// One setting's value and stamp, for the log ("false (mac 2026-11-08T17:27:03Z)").
    private static func describe(_ s: InAppSettings, _ field: InAppField) -> String {
        func d<V>(_ f: Field<V>) -> String { "\(f.value) (\(f.changedBy.rawValue) \(f.changedAt.formatted(.iso8601)))" }
        switch field {
        case .showValidity: return d(s.showValidity)
        case .alertLate: return d(s.alertLate)
        case .refreshCard: return d(s.refreshCard)
        case .reminder: return d(s.reminder)
        case .language: return d(s.language)
        case .autoRefresh: return d(s.autoRefresh)
        }
    }

    private static func describe(_ request: ChannelRequest) -> String {
        switch request {
        case .checkIn: request.pollEvery.map { "check-in (polls every \($0) s)" } ?? "check-in"
        case .watch: "watch"
        case .refresh: "refresh"
        case .setAutoRefresh(let on): "automatic refresh \(on ? "on" : "off")"
        }
    }

    private static func describe(_ reply: ChannelReply) -> String {
        switch reply {
        case .busy: "busy"
        case .deviceUnreachable: "device unreachable"
        case .failed(let key): "failed (\(key))"
        default: "\(reply)"
        }
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
    /// `until`: a pause of a while (the row's "Pause > 2 h / 1 jour", device feedback 3, E5), which
    /// ends by itself (`resumeEndedPauses`); nil until resumed.
    func stopRefreshing(_ entry: AppEntry, until: Date? = nil) async {
        let key = entry.id
        guard canManage(entry) else { return }
        claim(key)
        defer { release(key) }
        do {
            guard try await library.setRefreshPaused(true, recordID: key.recordID, deviceID: key.deviceID, until: until) else {
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

    /// The pauses of one app whose time is over end (checked at each evaluation of the engine):
    /// resumed as from the panel, reminders back, and due ones refreshed.
    func resumeEndedPauses() async {
        let resumed: [RefreshJob]
        // Not one XSide is working on (an uninstall): the next evaluation gets it (review D–G m10).
        let busy = Set(claims.keys.map { RefreshJob(recordID: $0.recordID, deviceID: $0.deviceID) })
        do { resumed = try await library.resumeEndedPauses(at: Date(), skipping: busy) } catch {
            Self.logger.error("ending pauses failed: \(String(describing: error))")
            return
        }
        guard !resumed.isEmpty else { return }
        Self.logger.notice("\(resumed.count) app pause(s) over: refreshing again")
        await reloadRecords()
        for job in resumed { onRefreshResumed?(job) }
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

    /// Reads the device's app list and forgets the XSide apps deleted from it (home screen), with
    /// their reminders, so no refresh puts them back. Rows with a job running are left alone.
    /// Returns what was forgotten, with the app names (for the notification). Nothing when the
    /// list can't be read.
    func forgetDeletedApps(on deviceID: String) async -> [(job: RefreshJob, appName: String)] {
        guard Self.setting(Self.forgetDeletedAppsKey), devices.contains(where: { $0.id == deviceID && $0.isAvailable }),
              !removingDevices.contains(deviceID) else { return [] }
        let queriedAt = Date()
        let installer = Installer(runner: runner)
        let listed: Set<String>?
        if let dir = lastKnownDeveloperDir {
            listed = await CommandEnvironment.withDeveloperDir(dir) { await installer.installedBundleIDs(deviceID: deviceID) }
        } else {
            listed = await installer.installedBundleIDs(deviceID: deviceID)
        }
        guard let listed, !removingDevices.contains(deviceID) else { return [] }
        let current = await library.records()
        var forgotten: [(job: RefreshJob, appName: String)] = []
        for job in PresenceCheck.missing(current, deviceID: deviceID, installed: listed, queriedAt: queriedAt) {
            let key = JobKey(recordID: job.recordID, deviceID: job.deviceID)
            guard jobs[key] == nil, claims[key] == nil,
                  let record = records.first(where: { $0.id == job.recordID }),
                  // Read again: an install may have finished during the earlier iterations' awaits.
                  let installation = record.installations.first(where: { $0.deviceID == deviceID }),
                  installation.installedAt < queriedAt else { continue }
            claim(key)
            defer { release(key) }
            do {
                guard try await library.removeInstallation(recordID: job.recordID, deviceID: job.deviceID) else { continue }
            } catch {
                Self.logger.error("forgetting a deleted app failed: \(String(describing: error))")
                continue
            }
            Self.logger.notice("\(record.originalBundleID) no longer on \(deviceID): forgotten there")
            forgotten.append((job, record.options.displayName ?? record.displayName))
            await installationRemoved(key)
        }
        return forgotten
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

    /// What the install in `flow` is likely to run into, on the devices it targets.
    func preflightWarnings(for flow: InstallFlow) -> [InstallPreflight.Warning] {
        guard let info = flow.info else { return [] }
        let existing = flow.existing
        let minOS = flow.draft.minOS.trimmingCharacters(in: .whitespaces)
        // A new App ID unless the record is known and keeps its bundle id (the field, or the default).
        let customID = flow.draft.bundleID.trimmingCharacters(in: .whitespaces)
        let signedID = customID.isEmpty ? defaultBundleID(for: flow) : customID
        let needsNewAppID = existing.map { signedID != $0.signedBundleID } ?? true
        let targets = flow.deviceIDs.compactMap { id -> InstallPreflight.Target? in
            guard let device = devices.first(where: { $0.id == id }) else { return nil }
            let others = records.filter { r in r.id != existing?.id && r.installations.contains { $0.deviceID == id } }
            return InstallPreflight.Target(
                deviceID: id, osVersion: device.osVersion,
                otherApps: others.map { $0.options.displayName ?? $0.displayName },
                // Under another bundle id, it's installed beside the old one: a slot of its own.
                hasThisApp: existing?.installations.contains {
                    $0.deviceID == id && ($0.signedBundleID ?? existing?.signedBundleID) == signedID
                } ?? false,
                developerModeEnabled: device.developerModeEnabled,
                // The same copy only (same bundle id): another one is a separate app.
                installedVersion: existing?.installations.first {
                    $0.deviceID == id && ($0.signedBundleID ?? existing?.signedBundleID) == signedID
                }.flatMap { $0.appVersion },
                isDuo: isDuo(device.id))
        }
        #if DEBUG
        // Debug-only: XSIDE_FAKE_PREFLIGHT=1 shows every warning, on the first selected device.
        if ProcessInfo.processInfo.environment["XSIDE_FAKE_PREFLIGHT"] == "1",
           let first = targets.max(by: { $0.otherApps.count < $1.otherApps.count }) {
            return [.iOSTooOld(deviceID: first.deviceID, required: "99.0", actual: first.osVersion ?? "?"),
                    .deviceFull(deviceID: first.deviceID, apps: first.otherApps),
                    .notMadeForDuo(deviceID: first.deviceID, optionPossible: true),
                    .notMadeForDuo(deviceID: first.deviceID, optionPossible: false),
                    .olderVersion(deviceID: first.deviceID, installing: "1.0", installed: "2.0"),
                    .noAppIDLeft]
        }
        #endif
        let version = flow.draft.version.trimmingCharacters(in: .whitespacesAndNewlines)
        return InstallPreflight.check(minimumOS: minOS.isEmpty ? info.minimumOSVersion : minOS, targets: targets,
                                      needsNewAppID: needsNewAppID, appIDsRemaining: appIDsRemaining,
                                      sdkVersion: info.sdkVersion, appVersion: version.isEmpty ? info.version : version,
                                      duo: info.duo)
    }

    /// The running step's progress per row, in whole percents, when its tool reports one.
    private(set) var stepPercent: [JobKey: Int] = [:]
    /// When the running step started, per row: the time spent shows where no percentage exists
    /// (the transfer to the device).
    private(set) var stepStarted: [JobKey: Date] = [:]

    /// When the running step of the install in `flow` started.
    func runStepStarted(_ flow: InstallFlow) -> Date? {
        guard flow.isRunning, let recordID = flow.importedRecordID ?? flow.existing?.id,
              let deviceID = flow.currentRun?.run.deviceID ?? flow.runs.first?.deviceID else { return nil }
        return stepStarted[JobKey(recordID: recordID, deviceID: deviceID)]
    }

    fileprivate func setStepPercent(_ percent: Int, for key: JobKey) {
        // Only unpacking (the welcome step) and signing report progress: a report arriving after
        // they ended (they hop to the main actor separately) must not show "100 %" on the transfer.
        guard jobs[key] == .step(.welcome) || jobs[key] == .step(.signing), stepPercent[key] != percent else { return }
        stepPercent[key] = percent
        updateDockBadge()
    }

    /// The current step's percentage of the install in `flow` (its device being installed now).
    func runPercent(_ flow: InstallFlow) -> Int? {
        guard flow.isRunning, let recordID = flow.importedRecordID ?? flow.existing?.id,
              let deviceID = flow.currentRun?.run.deviceID ?? flow.runs.first?.deviceID else { return nil }
        return stepPercent[JobKey(recordID: recordID, deviceID: deviceID)]
    }

    /// The Dock icon (when shown) carries the percentage of the install in the window, else of
    /// the only running job.
    private func updateDockBadge() {
        let percent = install?.isRunning == true ? install.flatMap(runPercent)
            : (stepPercent.count == 1 ? stepPercent.values.first : nil)
        onDockBadge?(percent.map { "\($0)%" })
    }

    /// Set by the app delegate: shows a label on the Dock icon (nil removes it).
    var onDockBadge: ((String?) -> Void)?

    /// Refreshes asked before XSide could run them (a notification's "Refresh now", or the
    /// command line tool, that launched it): tried again once the devices are listed and the
    /// environment checked.
    private var queuedRefreshes: [RefreshJob] = []

    /// Starts the refresh now, or as soon as it can start (XSide just launched). False when it
    /// was queued.
    @discardableResult
    func refreshWhenReady(_ job: RefreshJob) -> Bool {
        if refreshNow(job) { return true }
        if !queuedRefreshes.contains(job) { queuedRefreshes.append(job) }
        return false
    }

    private func retryQueuedRefresh() {
        guard !queuedRefreshes.isEmpty, signingEnvironment != nil, !devices.isEmpty else { return }
        let jobs = queuedRefreshes
        queuedRefreshes = []
        for job in jobs where !refreshNow(job) { Self.logger.notice("queued refresh couldn't start") }
    }

    /// A command line request (`xside refresh`, `pause`, `settings`…): the answer it prints.
    func handle(_ command: CLIBridge.Command) async -> (ok: Bool, message: String) {
        let names = cachedNames
        let entries = records.flatMap { r in r.installations.map { AppEntry(record: r, installation: $0) } }
        func appName(_ e: AppEntry) -> String { e.record.options.displayName ?? e.record.displayName }
        func deviceName(_ e: AppEntry) -> String {
            devices.first { $0.id == e.installation.deviceID }?.name ?? names[e.installation.deviceID] ?? e.installation.deviceID
        }
        func describe(_ e: AppEntry) -> String { "\(appName(e)) on \(deviceName(e))" }
        let targets: [AppEntry]
        switch command {
        case .pause(let seconds):
            let until = seconds.map { Date().addingTimeInterval(TimeInterval($0)) } ?? .distantFuture
            UserDefaults.standard.set(until.timeIntervalSince1970, forKey: BackgroundEngine.pausedUntilKey)
            onNeedsEvaluation?()
            Self.logger.notice("command line pause until \(until.formatted(.iso8601))")
            return (true, until == .distantFuture
                ? "Automatic refreshes paused until you resume them (xside resume). An app expiring within 12 hours is still refreshed."
                : "Automatic refreshes paused until \(until.formatted(date: .abbreviated, time: .shortened)). An app expiring within 12 hours is still refreshed.")
        case .resume:
            UserDefaults.standard.set(0.0, forKey: BackgroundEngine.pausedUntilKey)
            onNeedsEvaluation?()
            return (true, "Automatic refreshes resumed.")
        case .editSettings, .pauseApp, .resumeApp, .uninstall, .report, .crash:
            return await handleAppCommand(command, entries: entries, describe: describe)
        case .refreshAll:
            targets = entries.filter { !$0.installation.refreshPaused }
            guard !targets.isEmpty else { return (false, "No app to refresh (none installed, or all paused).") }
        case .refresh(let app, let device):
            var matches = entries.filter {
                appName($0).localizedCaseInsensitiveContains(app) || $0.record.originalBundleID.localizedCaseInsensitiveContains(app)
            }
            if let device {
                matches = matches.filter { deviceName($0).localizedCaseInsensitiveContains(device) || $0.installation.deviceID == device }
            }
            guard !matches.isEmpty else {
                // Not the list of installed apps: the answer is a distributed notification, which
                // any program of the session can hear (`xside status` reads the list locally).
                return (false, "No app matches \"\(app)\"\(device.map { " on \"\($0)\"" } ?? ""). See xside status.")
            }
            // Several different apps: say which, rather than guess.
            let distinct = Set(matches.map(\.record.id))
            if distinct.count > 1, !matches.contains(where: { appName($0).caseInsensitiveCompare(app) == .orderedSame }) {
                return (false, "\"\(app)\" matches several apps: " + matches.map(describe).joined(separator: ", ") + ". Be more precise.")
            }
            let exact = matches.filter { appName($0).caseInsensitiveCompare(app) == .orderedSame }
            targets = exact.isEmpty ? matches : exact
            if let paused = targets.first(where: \.installation.refreshPaused), targets.count == 1 {
                return (false, "\(describe(paused)) is paused: resume it from its … menu in XSide.")
            }
        }
        var started: [String] = [], queued: [String] = []
        for entry in targets where !entry.installation.refreshPaused {
            if jobs[entry.id] != nil {
                started.append(describe(entry) + " (already running)")
            } else if refreshWhenReady(entry.job) {
                started.append(describe(entry))
            } else {
                queued.append(describe(entry))
            }
        }
        Self.logger.notice("command line refresh: \(started.count) started, \(queued.count) queued")
        var lines: [String] = []
        if !started.isEmpty { lines.append("Refreshing: " + started.joined(separator: ", ")) }
        if !queued.isEmpty {
            lines.append("Queued, starts as soon as the device is reachable and XSide is ready: " + queued.joined(separator: ", "))
        }
        return (true, lines.joined(separator: "\n"))
    }

    /// The commands aimed at installations the tool found (device feedback 3, E7), done as the UI
    /// does them. Each target is checked again: the library may have changed since the tool read it.
    private func handleAppCommand(_ command: CLIBridge.Command, entries: [AppEntry],
                                  describe: (AppEntry) -> String) async -> (ok: Bool, message: String) {
        func targets(_ record: UUID, _ devices: [String]) -> [AppEntry] {
            entries.filter { $0.record.id == record && devices.contains($0.installation.deviceID) }
        }
        let gone = "That app is no longer installed there (see xside apps)."
        switch command {
        case .editSettings(let record, let devices, let changes):
            let found = targets(record, devices)
            guard !found.isEmpty else { return (false, gone) }
            var lines: [String] = []
            for entry in found {
                guard canManage(entry) else { lines.append("\(describe(entry)): busy, try again in a moment"); continue }
                let others = changes.filter { if case .autoRefresh = $0 { false } else { true } }
                if !others.isEmpty {
                    await editInApp(entry.id) { $0.applying(others, at: Date()) }
                }
                for change in changes {
                    guard case .autoRefresh(let on) = change else { continue }
                    if on { await resumeRefreshing(entry) } else { await stopRefreshing(entry) }
                }
                lines.append("\(describe(entry)): " + changes.map(\.text).joined(separator: ", ")
                             + " (reaches the app at once if it's open, otherwise at its next opening or refresh)")
            }
            Self.logger.notice("command line settings: \(changes.map(\.text).joined(separator: ", "))")
            return (true, lines.joined(separator: "\n"))
        case .pauseApp(let record, let devices, let seconds):
            let found = targets(record, devices)
            guard !found.isEmpty else { return (false, gone) }
            let until = seconds.map { Date().addingTimeInterval(TimeInterval($0)) }
            if let busy = found.first(where: { !canManage($0) }) { return (false, "\(describe(busy)) is busy, try again in a moment.") }
            func untilText(_ date: Date?) -> String {
                date.map { "until \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "until resumed"
            }
            // Already paused: `stopRefreshing` leaves it (and its end) as it was; say so (review D–G m1).
            let already = found.filter(\.installation.refreshPaused)
            let toPause = found.filter { !$0.installation.refreshPaused }
            for entry in toPause { await stopRefreshing(entry, until: until) }
            return (true, CLIBridge.pauseAppSummary(
                paused: toPause.map(describe),
                already: already.map { "\(describe($0)) (\(untilText($0.installation.pausedUntil)))" },
                when: until == nil ? "until resumed (xside resume <app>)" : untilText(until)))
        case .resumeApp(let record, let devices):
            let found = targets(record, devices)
            guard !found.isEmpty else { return (false, gone) }
            if let busy = found.first(where: { !canManage($0) }) { return (false, "\(describe(busy)) is busy, try again in a moment.") }
            for entry in found { await resumeRefreshing(entry) }
            return (true, "Refreshing again: " + found.map(describe).joined(separator: ", "))
        case .uninstall(let record, let devices):
            let found = targets(record, devices)
            guard !found.isEmpty else { return (false, gone) }
            var done: [String] = [], failed: [String] = []
            for entry in found {
                guard canManage(entry) else { failed.append("\(describe(entry)) (busy, try again in a moment)"); continue }
                do {
                    try await uninstall(entry)
                    done.append(describe(entry))
                } catch {
                    failed.append("\(describe(entry)) (\((error as? XSideError)?.key ?? String(describing: error)))")
                }
            }
            var lines: [String] = []
            if !done.isEmpty { lines.append("Uninstalled: " + done.joined(separator: ", ")) }
            if !failed.isEmpty { lines.append("Not uninstalled: " + failed.joined(separator: ", ")) }
            return (failed.isEmpty, lines.joined(separator: "\n"))
        case .report:
            guard let archive = await Diagnostics.writeReportArchive(model: self) else {
                return (false, "The report archive couldn't be written (see the logs).")
            }
            return (true, archive.path)
        case .crash(let record, let devices, let json):
            let found = targets(record, devices)
            guard !found.isEmpty else { return (false, gone) }
            var answers: [CrashAnswer] = []
            for entry in found {
                let check = await diagnoseCrash(entry.id)
                answers.append(CrashAnswer(entry: entry, device: describe(entry), check: check))
            }
            return Self.crashReply(answers, json: json)
        default:
            return (false, "unsupported")
        }
    }

    private func unhide(_ deviceID: String) {
        guard devicePrefs.isHidden(deviceID) else { return }
        var prefs = devicePrefs
        prefs.setHidden(false, deviceID)
        savePrefs(prefs)
    }

    /// Refreshes every app that can be now (reachable, not paused, not already running).
    func refreshAll() {
        let entries = deviceGroups.flatMap(\.apps).filter(canRefresh)
        Self.logger.notice("refresh all: \(entries.count) app(s)")
        for entry in entries { refreshNow(entry.job) }
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
        if left <= 0 {
            jobs[key] = nil
            stepPercent[key] = nil
            stepStarted[key] = nil
            updateDockBadge()
        }
        if claims.isEmpty, let activity = jobActivity {
            ProcessInfo.processInfo.endActivity(activity)
            jobActivity = nil
        }
        if left <= 0 { dropKeptEmptyRecords() }
        if claims.isEmpty { updater.installIfIdle() } // a downloaded update waited for this
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
                     automatic: Bool = false, inApp: InAppDraft? = nil, duoCompatibility: Bool? = nil,
                     progress: @escaping @MainActor @Sendable (JobStage) -> Void = { _ in },
                     duoOutcome: @escaping @MainActor @Sendable (DuoOutcome) -> Void = { _ in }) async throws {
        let job = RefreshJob(recordID: key.recordID, deviceID: key.deviceID)
        // A refresh renews an existing installation; a first install is shown by the install window.
        let wasRefresh = records.first { $0.id == key.recordID }?
            .installations.contains { $0.deviceID == key.deviceID } ?? false
        do {
            let environment: @Sendable () async throws -> SigningEnvironment = { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.currentEnvironment()
            }
            // How far the current step is, when its tool can tell (whole percents, on the main actor).
            let report: @Sendable (Double) -> Void = { [weak self] fraction in
                let percent = Int((fraction * 100).rounded(.down))
                Task { @MainActor in self?.setStepPercent(percent, for: key) }
            }
            _ = try await StepProgress.$report.withValue(report) {
                try await pipeline.install(recordID: key.recordID, device: device, environment: environment,
                                           refresh: refresh, inApp: inApp,
                                           duoCompatibility: duoCompatibility) { step in
                    await MainActor.run {
                        self.jobs[key] = .step(step)
                        self.stepPercent[key] = nil // a new step starts from nothing
                        self.stepStarted[key] = Date()
                        self.updateDockBadge()
                        progress(.step(step))
                    }
                } duoOutcome: { outcome in
                    await MainActor.run { duoOutcome(outcome) }
                }
            }
        } catch {
            await reloadRecords()
            onJobFinished?(job, error, automatic, wasRefresh)
            // Deleted from the device: the pipeline dropped the installation; its reminder and
            // notification state go too (after the notification above, which reads the record).
            if error as? XSideError == .appRemovedFromDevice { await installationRemoved(key) }
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
                flow.duoDevices = Set(existing?.installations.filter { $0.duoCompatibility == true }.map(\.deviceID) ?? [])
                // The app's last-used values; a reinstall refreshes it again (as before 1.1), so
                // automatic refresh starts on.
                if let used = existing.flatMap({ InAppSettings.lastUsed(in: $0.installations) }) {
                    flow.inApp = used.setting(\.autoRefresh, to: true, at: Date(), by: .mac)
                }
                let installed = existing?.installations.isEmpty == false
                flow.reviewsSteps = !installed || Self.setting(Self.reviewInstallOptionsKey)
                flow.phase = .editing(error: nil)
                autoselectDevice() // the default now depends on where the app is installed
                #if DEBUG
                // Debug-only: XSIDE_FAKE_RUNNING=1 shows the window mid-install (signing), to look at it.
                if ProcessInfo.processInfo.environment["XSIDE_FAKE_RUNNING"] == "1", let device = devices.first {
                    flow.runs = [DeviceRun(deviceID: device.id, name: device.name)]
                    flow.phase = .running(.step(.signing))
                }
                #endif
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
            flow.go(to: 1) // where the identifier field is
            return
        }
        flow.runs = targets.map { id in DeviceRun(deviceID: id, name: devices.first { $0.id == id }?.name ?? id) }
        flow.runOptions = flow.draft.options
        flow.runInApp = InAppDraft(settings: flow.inApp, touched: flow.inAppTouched)
        // Only where the option can be on (a device unchecked meanwhile keeps its own choice).
        flow.runLegacy32 = flow.info?.hasLegacy32 == true
        flow.runDuo = flow.duoDevices.filter { duoState(for: $0, app: flow.info?.duo).canTurnOn }
        // A new run imports again (the options may have changed); only its later devices reuse it.
        flow.importedRecordID = nil
        flow.guides = []
        flow.shownGuides = []
        flow.failure = nil
        // The Wi-Fi check follows a first install over USB (see `guideIfFirstInstall`, below).
        if targets.count == 1, let device = devices.first(where: { $0.id == targets[0] }) {
            flow.wifiStepPlanned = neverInstalled(on: device.id)
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
        // Before anything is installed: the devices' state as it was.
        flow.trustDue = Set(targets.filter(trustGuideDue(on:)))
        flow.firstInstalls = Set(targets.filter(neverInstalled(on:)))
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

    /// Devices whose last install failed because they were locked: their tile says to unlock
    /// them (devicectl doesn't tell whether a device is locked), until the next attempt there.
    private(set) var needsUnlock: Set<String> = []

    /// One device of a run. A first install queues its guide and, over USB with Wi-Fi refresh on,
    /// its Wi-Fi check.
    private func installOne(_ flow: InstallFlow, on deviceID: String) async {
        let startedAt = Date()
        flow.lastStage = .preparing
        flow.phase = .running(.preparing)
        flow.setStatus(.running(.preparing), for: deviceID)
        if let i = flow.runs.firstIndex(where: { $0.deviceID == deviceID }) {
            flow.runs[i].duoMissing = false
            flow.runs[i].duoOutcome = nil
            flow.runs[i].crash = nil
            flow.runs[i].checkingLaunch = false
        }
        needsUnlock.remove(deviceID)
        // Looked up now: the device may have gone (or changed transport) during the earlier ones.
        guard !removingDevices.contains(deviceID),
              let device = devices.first(where: { $0.id == deviceID && $0.isAvailable }) else {
            flow.setStatus(.failed(StepFailure(stage: .preparing, message: localizedMessage(XSideError.deviceUnavailable))),
                           for: deviceID)
            return
        }
        unhide(deviceID) // installing on it brings it back
        do {
            let installed = try await importAndInstall(flow.ipa, on: device, options: flow.runOptions,
                                       inApp: flow.runInApp, duoCompatibility: flow.runDuo.contains(deviceID),
                                       importedInto: flow.importedRecordID,
                                       imported: { flow.importedRecordID = $0 },
                                       progress: { stage in
                                           flow.lastStage = stage
                                           flow.phase = .running(stage)
                                           flow.setStatus(.running(stage), for: deviceID)
                                       },
                                       duoOutcome: { outcome in
                                           if let i = flow.runs.firstIndex(where: { $0.deviceID == deviceID }) {
                                               flow.runs[i].duoOutcome = outcome
                                           }
                                       })
            flow.setStatus(.succeeded, for: deviceID)
            if installed.installations.first(where: { $0.deviceID == deviceID })?.duoCompatibilityMissing == true,
               let i = flow.runs.firstIndex(where: { $0.deviceID == deviceID }) {
                flow.runs[i].duoMissing = true
            }
            // "Rafraîchissement automatique" off in step ③: installed, then paused (a signing
            // always leaves it on).
            if flow.runInApp?.settings.autoRefresh.value == false { await pauseAfterInstall(recordID: installed.id, deviceID: deviceID) }
            // Asked to the device itself; the remembered rule only when it can't tell.
            let signedID = installed.installations.first { $0.deviceID == deviceID }?.signedBundleID ?? installed.signedBundleID
            // Opening the app is how the device tells; when off, the remembered rule decides.
            let trust: Installer.TrustState = flow.openAppAfter
                ? await withKnownXcode { [runner] in await Installer(runner: runner).trustState(bundleID: signedID, deviceID: deviceID) }
                : .unknown
            Self.logger.notice("trust on \(deviceID): \(String(describing: trust))")
            if trust == .trusted, flow.trustDue.contains(deviceID) {
                // Already trusted (another app of the same account): nothing to say, remembered as shown.
                rememberGuideShown(deviceID)
            }
            if trust == .untrusted, flow.openTrustPage { openTrustSettings(deviceID) }
            // Launched (or the launch failed for another reason than trust): does it stay up?
            if flow.openAppAfter, trust != .untrusted {
                watchLaunch(JobKey(recordID: installed.id, deviceID: deviceID), since: startedAt,
                            launched: trust == .trusted, flow: flow)
            }
            // Trusted: no guide. Not trusted: the guide, whatever XSide remembers.
            if trust != .trusted,
               let guide = guideIfFirstInstall(on: device, flow: flow, force: trust == .untrusted) {
                flow.guides.append(guide)
            }
            // The Wi-Fi check is for a device's very first install only, not a guide shown again.
            if flow.firstInstalls.contains(device.id), devicePrefs.wifiRefresh(for: device.id) {
                if device.transport == .usb {
                    flow.wifiQueue.append(device.id)
                } else if let i = flow.runs.firstIndex(where: { $0.deviceID == deviceID }) {
                    flow.runs[i].wifiVerified = true // already installed over Wi-Fi
                }
            }
        } catch {
            // Cancelled: no error shown (the pipeline reports a step stopped by the cancellation as
            // such). Any other error, even after "Cancel install", stays a failure.
            if error is CancellationError {
                flow.setStatus(.cancelled, for: deviceID)
            } else {
                if case .deviceLocked? = error as? XSideError { needsUnlock.insert(deviceID) }
                flow.setStatus(.failed(StepFailure(stage: flow.lastStage, message: localizedMessage(error))), for: deviceID)
            }
        }
    }

    /// Pauses an installation just installed (its row is still claimed by the run, so not
    /// through `stopRefreshing`): its reminder and notification state go, as from the panel.
    private func pauseAfterInstall(recordID: UUID, deviceID: String) async {
        do {
            guard try await library.setRefreshPaused(true, recordID: recordID, deviceID: deviceID, by: .mac) else { return }
        } catch {
            Self.logger.error("pause after install failed: \(String(describing: error))")
            return
        }
        await reloadRecords()
        onInstallationRemoved?(RefreshJob(recordID: recordID, deviceID: deviceID))
    }

    /// Changes one installation's XSide-in-app settings from the Mac (Settings > Mes apps). They
    /// reach the app at its next check-in or signing.
    func editInApp(_ key: JobKey, _ transform: @escaping @Sendable (InAppSettings) -> InAppSettings) async {
        do {
            try await library.editInApp(recordID: key.recordID, deviceID: key.deviceID,
                                        reminder: Self.setting(Self.deviceReminderKey), at: Date(), transform)
            // Which installation got it (device feedback 3, E2): the phone's check-ins name it the same way.
            Self.channelLogger.notice("channel: Mac edit stored for \(key.recordID) on \(key.deviceID)")
        } catch {
            Self.logger.error("in-app settings edit failed: \(String(describing: error))")
        }
        await reloadRecords()
    }

    /// The app's own choice of XSide's features (nil: follow the Mac's default). Applies at its
    /// next install or refresh.
    /// How the iPhone Duo option shows for an app (`app`: what its .ipa supports) on a device:
    /// connected, as devicectl describes it, else as it was at its last signing.
    func duoState(for deviceID: String, app: DuoAppInfo?, installation: Installation? = nil) -> DuoCompatibility.OptionState {
        DuoCompatibility.optionState(isDuo: isDuo(deviceID, installation: installation), app: app)
    }

    /// The device is an iPhone Duo: what devicectl says of it, else (it isn't connected, or
    /// didn't say what it is) what an earlier signing there remembered (duo review minor 4).
    func isDuo(_ deviceID: String, installation: Installation? = nil) -> Bool {
        let remembered = installation?.onDuo == true
            || records.contains { $0.installations.contains { $0.deviceID == deviceID && $0.onDuo == true } }
        guard let device = devices.first(where: { $0.id == deviceID }) else { return remembered }
        return device.isDuo(remembered: remembered)
    }

    /// Settings > Mes apps: iPhone Duo compatibility for one installation, from its next signing.
    func setDuoCompatibility(_ on: Bool, for entry: AppEntry) async {
        do {
            try await library.setDuoCompatibility(on, recordID: entry.record.id, deviceID: entry.installation.deviceID)
        } catch {
            Self.logger.error("duo choice failed: \(String(describing: error))")
        }
        await reloadRecords()
    }

    func setWithoutXSideFeatures(_ without: Bool?, recordID: UUID) async {
        guard var options = records.first(where: { $0.id == recordID })?.options else { return }
        options.withoutXSideFeatures = without
        do { try await library.setOptions(options, for: recordID) } catch {
            Self.logger.error("features choice failed: \(String(describing: error))")
        }
        await reloadRecords()
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

    /// No guide was ever shown for that device: its first install with XSide.
    private func neverInstalled(on deviceID: String) -> Bool {
        TrustGuide.Shown(stored: UserDefaults.standard.object(forKey: Self.guideKey(deviceID))) == .never
    }

    /// Whether the trust guide is due on that device, judged before the run installs anything
    /// there: never shown, no XSide app left on it (iOS forgot the trust), or a new certificate.
    private func trustGuideDue(on deviceID: String) -> Bool {
        TrustGuide.isDue(shown: TrustGuide.Shown(stored: UserDefaults.standard.object(forKey: Self.guideKey(deviceID))),
                         currentIdentity: (try? environment?.get())?.identitySHA1,
                         deviceHasApps: records.contains { $0.installations.contains { $0.deviceID == deviceID } })
    }

    /// The guide is due after a successful install on a device the run marked (`trustDue`). It is
    /// marked as shown only when it is actually displayed (`guideDisplayed`).
    /// `force`: the device said it doesn't trust the developer, whatever XSide remembers.
    private func guideIfFirstInstall(on device: Device, flow: InstallFlow, force: Bool = false) -> FirstInstallGuide? {
        guard force || flow.trustDue.contains(device.id) else { return nil }
        let account = (try? environment?.get())?.identityName ?? "Apple Development"
        return FirstInstallGuide(deviceID: device.id, accountName: account,
                                 needsDeveloperMode: device.developerModeEnabled == false, openedOnDevice: force)
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
        rememberGuideShown(guide.deviceID)
        if let flow = install, flow.guides.contains(guide) { flow.shownGuides.insert(guide.deviceID) }
    }

    private static func guideKey(_ deviceID: String) -> String { "guideShown.\(deviceID)" }

    // MARK: Install settings (Settings > General > Installs and devices), all on by default.
    // The first two are the defaults of each install window (`InstallFlow.openAppAfter`).

    static let openAppAfterInstallKey = "openAppAfterInstall"
    static let openTrustSettingsKey = "openTrustSettingsAutomatically"
    static let forgetDeletedAppsKey = "forgetDeletedApps"
    /// The reminder the installed app shows itself before it expires ("Rappel avant l'expiration",
    /// default of new installs; each installation has its own since 1.1).
    nonisolated static let deviceReminderKey = "deviceReminder"
    /// The other defaults of new installs for XSide in the app (Settings > Module XSide dans les apps).
    nonisolated static let inAppShowValidityKey = "inApp.showValidity"
    nonisolated static let inAppAlertLateKey = "inApp.alertLate"
    nonisolated static let inAppRefreshCardKey = "inApp.refreshCard"
    nonisolated static let inAppLanguageKey = "inApp.language"
    /// "Installer les apps sans les fonctionnalités XSide" (see `withoutXSideFeaturesByDefault`).
    nonisolated static let installWithoutFeaturesKey = "installWithoutXSideFeatures"
    /// "Revoir les options à chaque installation" (on by default): off, an app already installed
    /// gets the summary of its options on the first step instead of the three steps.
    static let reviewInstallOptionsKey = "reviewInstallOptions"
    /// What the welcome library reads in each app (see `WelcomePayload`): the Mac-wide part; the
    /// installation's own values are filled in at signing (`Resigner.payload(_:with:)`).
    nonisolated static func welcomePayload() -> WelcomePayload {
        let defaults = UserDefaults.standard
        let threshold = RefreshPlanner.threshold(daysBefore: defaults.integer(forKey: "refreshDaysBefore"),
                                                 debugDays: defaults.double(forKey: "debugThresholdDays"))
        return WelcomePayload(thresholdHours: Int(threshold / 3600),
                              reminderLeadHours: Int(RefreshPolicy.reminderLead(threshold: threshold) / 3600),
                              inApp: inAppDefaults(at: Date()))
    }

    /// The notification when XSide forgets an app deleted from its device.
    static let notifyAppRemovedKey = "notifyAppRemoved"

    nonisolated static func setting(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// The certificate the guide was shown (or found unneeded) for: a new one brings it back.
    private func rememberGuideShown(_ deviceID: String) {
        let sha1 = (try? environment?.get())?.identitySHA1
        UserDefaults.standard.set(sha1 ?? true as Any, forKey: Self.guideKey(deviceID))
    }

    // MARK: Crash diagnosis

    /// How far back "Why does it crash?" looks.
    static let crashLookback: TimeInterval = 24 * 3600
    /// After XSide opens an app at install: how long it must stay up to count as started.
    static let launchGrace: Duration = .seconds(10)

    /// What XSide found about an installation's crashes (memory only: the device keeps the logs).
    private(set) var crashChecks: [JobKey: CrashCheck] = [:]
    /// The installation the crash window shows.
    var crashWindowKey: JobKey?
    /// Opens the crash window (set by the menu-bar label, which has `openWindow`).
    var showCrashWindow: (() -> Void)?

    /// "Why does it crash?": the window, on that installation, and a fresh look at its crash logs.
    func explainCrash(_ key: JobKey) {
        crashWindowKey = key
        showCrashWindow?()
        switch crashChecks[key] {
        case .checking?, .found?: break // its "Look again" reads them anew
        default: Task { await diagnoseCrash(key) }
        }
    }

    /// Reads the device's newest crash of the installation since `since` (default: the last 24 h),
    /// explains it and keeps the result for the panel, the window and the report. Any failure is
    /// an answer, never an error thrown at the caller.
    @discardableResult
    func diagnoseCrash(_ key: JobKey, since: Date? = nil, afterInstall: Bool = false) async -> CrashCheck {
        guard let record = records.first(where: { $0.id == key.recordID }),
              let installation = record.installations.first(where: { $0.deviceID == key.deviceID }) else {
            crashChecks[key] = .failed(L("crash.gone"))
            return .failed(L("crash.gone"))
        }
        let since = since ?? Date().addingTimeInterval(-Self.crashLookback)
        let previous = crashChecks[key]
        crashChecks[key] = .checking
        let target = CrashTarget(signedBundleID: installation.signedBundleID ?? record.signedBundleID,
                                 executable: record.executable)
        let fetcher = CrashLogFetcher(runner: runner)
        let result: CrashCheck
        do {
            if let found = try await withKnownXcode({ try await fetcher.latest(target, deviceID: key.deviceID, since: since) }) {
                let context = CrashContext(moduleName: Resigner.welcomeName,
                                           duoCompatibilityOn: installation.duoCompatibility == true)
                let diagnosis = CrashClassifier.classify(found.log, context: context)
                let secrets = [installation.teamID, record.teamID, key.deviceID].compactMap { $0 }
                let log = LogStore.shared.redact(CrashLogSanitizer.sanitize(found.text, secrets: secrets))
                Self.logger.notice("crash of \(target.signedBundleID) on \(key.deviceID): \(diagnosis.summary)")
                // The same crash the install check found stays that one (the panel keeps its line).
                let wasAfterInstall = if case .found(let earlier)? = previous, earlier.fileName == found.fileName { earlier.afterInstall } else { false }
                result = .found(CrashFinding(diagnosis: diagnosis, log: log, fileName: found.fileName,
                                             afterInstall: afterInstall || wasAfterInstall))
            } else {
                Self.logger.notice("no crash of \(target.signedBundleID) on \(key.deviceID) since \(since.formatted(.iso8601))")
                result = .none
            }
        } catch {
            Self.logger.notice("crash logs of \(key.deviceID) unreadable: \(String(describing: error))")
            result = .failed(localizedMessage(error))
        }
        crashChecks[key] = result
        return result
    }

    /// After an install that opened the app: once `launchGrace` has passed, an app no longer
    /// running (or whose launch failed) has its crash logs read, and what they say goes to the
    /// install window and the panel. Nothing found, or a device that can't tell: nothing is said.
    /// Never holds up the install.
    private func watchLaunch(_ key: JobKey, since: Date, launched: Bool, flow: InstallFlow) {
        func setRun(_ change: (inout DeviceRun) -> Void) {
            if let i = flow.runs.firstIndex(where: { $0.deviceID == key.deviceID }) { change(&flow.runs[i]) }
        }
        setRun { $0.checkingLaunch = true }
        Task { [weak self] in
            try? await Task.sleep(for: Self.launchGrace)
            guard let self else { return }
            defer { setRun { $0.checkingLaunch = false } }
            if launched, let executable = records.first(where: { $0.id == key.recordID })?.executable {
                let fetcher = CrashLogFetcher(runner: runner)
                let running = await withKnownXcode { await fetcher.isRunning(executable: executable, deviceID: key.deviceID) }
                Self.logger.notice("app running on \(key.deviceID) after launch: \(running.map(String.init) ?? "unknown")")
                if running == true { return }
            }
            var result = await diagnoseCrash(key, since: since.addingTimeInterval(-5), afterInstall: true)
            if case .none = result {
                // ReportCrash may still be writing it.
                try? await Task.sleep(for: .seconds(5))
                result = await diagnoseCrash(key, since: since.addingTimeInterval(-5), afterInstall: true)
            }
            guard case .found(let finding) = result else {
                crashChecks[key] = nil // nothing to say
                return
            }
            setRun { $0.crash = finding }
        }
    }

    /// The panel's line for an installation: its crash found after its last install, if any.
    func crashFinding(for entry: AppEntry) -> CrashFinding? {
        guard case .found(let finding)? = crashChecks[entry.id], finding.afterInstall,
              (finding.diagnosis.date ?? .distantPast) >= entry.installation.installedAt.addingTimeInterval(-120) else { return nil }
        return finding
    }

    /// One installation's answer to `xside crash`.
    struct CrashAnswer {
        let entry: AppEntry
        let device: String
        let check: CrashCheck
    }

    /// `xside crash`'s answer, in English like the tool's other output.
    static func crashReply(_ answers: [CrashAnswer], json: Bool) -> (ok: Bool, message: String) {
        let failed = answers.allSatisfy { if case .failed = $0.check { true } else { false } }
        if json {
            struct Row: Encodable {
                let app: String, device: String, found: Bool, error: String?
                let cause: String?, title: String?, explanation: String?, advice: String?
                let diagnosis: CrashDiagnosis?
            }
            let rows = answers.map { a -> Row in
                let app = a.entry.record.options.displayName ?? a.entry.record.displayName
                switch a.check {
                case .found(let f):
                    let w = CrashWording(f.diagnosis, app: app, language: "en")
                    return Row(app: app, device: a.device, found: true, error: nil, cause: f.diagnosis.cause.rawValue,
                               title: w.title, explanation: w.explanation, advice: w.advice, diagnosis: f.diagnosis)
                case .failed(let message):
                    return Row(app: app, device: a.device, found: false, error: message, cause: nil, title: nil,
                               explanation: nil, advice: nil, diagnosis: nil)
                case .none, .checking:
                    return Row(app: app, device: a.device, found: false, error: nil, cause: nil, title: nil,
                               explanation: nil, advice: nil, diagnosis: nil)
                }
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (!failed, String(decoding: (try? encoder.encode(rows)) ?? Data("[]".utf8), as: UTF8.self))
        }
        let lines = answers.map { a -> String in
            let app = a.entry.record.options.displayName ?? a.entry.record.displayName
            switch a.check {
            case .found(let f):
                let w = CrashWording(f.diagnosis, app: app, language: "en")
                var text = "\(a.device): \(w.title)\n  \(w.explanation)\n  What to do: \(w.advice)"
                let when = f.diagnosis.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "?"
                text += "\n  \(when) · \(f.diagnosis.summary)"
                return text
            case .failed(let message): return "\(a.device): couldn't read the crash reports (\(message))"
            case .none, .checking: return "\(a.device): no crash of \(app) in the last 24 hours"
            }
        }
        return (!failed, lines.joined(separator: "\n"))
    }

    /// Runs `body`'s tools with the Xcode XSide uses (as the jobs do), else the system's.
    private func withKnownXcode<T>(_ body: () async throws -> T) async rethrows -> T {
        guard let dir = lastKnownDeveloperDir else { return try await body() }
        return try await CommandEnvironment.withDeveloperDir(dir) { try await body() }
    }

    /// Opens Settings > General > VPN & Device Management on the device (see the guide).
    func openTrustSettings(_ deviceID: String) {
        let installer = Installer(runner: runner)
        Task {
            do { try await withKnownXcode { try await installer.openTrustSettings(deviceID: deviceID) } } catch {
                Self.logger.notice("opening the trust settings on \(deviceID) failed: \(String(describing: error))")
            }
        }
    }

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
        var root = support.appendingPathComponent(LibraryLocation.folderName(bundleID: Bundle.main.bundleIdentifier),
                                                  isDirectory: true)
        #if DEBUG
        // The snapshot harness keeps its made-up library in its output folder.
        if let folder = SnapshotRenderer.folder { root = URL(fileURLWithPath: folder).appendingPathComponent("library", isDirectory: true) }
        #endif
        self.root = root
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
