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
}

@MainActor @Observable
final class AppModel {
    private static let logger = Logger(subsystem: "io.github.xside.XSide", category: "model")

    private(set) var environment: Result<SigningEnvironment, XSideError>?
    private(set) var isProbing = false
    private(set) var devices: [Device] = []
    private(set) var records: [AppRecord] = []
    private(set) var appIDsRemaining: Int?
    /// Current step of each running install/refresh, per app row.
    private(set) var jobs: [JobKey: InstallStep] = [:]
    private(set) var pairing: Set<String> = []
    private(set) var pairErrors: [String: String] = [:]

    /// The `.ipa` waiting in the install window. Setting it (even to the same file again) starts a
    /// new install flow, unless an install is running.
    var pendingIPA: URL? {
        didSet { beginFlow() }
    }
    private(set) var install: InstallFlow?

    let library: AppLibrary
    private let runner = ProcessRunner()
    private let paths: Paths
    private var pipeline: SideloadPipeline?
    private var pipelineEnv: SigningEnvironment?
    private var listingDevices = false

    init() {
        paths = Paths()
        library = AppLibrary(root: paths.root)
        Task { await start() }
    }

    // MARK: - Startup

    private func start() async {
        await reloadRecords()
        refreshDevices()
        await probeEnvironment()
    }

    func recheckEnvironment() {
        Task { await probeEnvironment() }
    }

    private func probeEnvironment() async {
        guard !isProbing else { return }
        isProbing = true
        defer { isProbing = false }
        let result = await EnvironmentProbe(runner: runner).detect()
        environment = result
        if case .success(let env) = result, env != pipelineEnv {
            pipelineEnv = env
            pipeline = SideloadPipeline(
                library: library,
                provisioner: Provisioner(runner: runner, templateDir: paths.template, workDir: paths.provisioningWork),
                resigner: Resigner(runner: runner), installer: Installer(runner: runner),
                env: env, workRoot: paths.jobsWork, now: { Date() })
        }
        await updateAppIDCounter()
    }

    // MARK: - Devices

    /// Called when the popover appears and after actions. Periodic polling comes later.
    func popoverAppeared() {
        refreshDevices()
        Task { await reloadRecords() }
    }

    func refreshDevices() {
        guard !listingDevices else { return }
        listingDevices = true
        Task {
            defer { listingDevices = false }
            do {
                let listed = try await DeviceService(runner: runner).list()
                devices = listed.filter { $0.kind != .other }
                rememberNames(devices)
                autoselectDevice()
            } catch {
                Self.logger.error("device list failed: \(String(describing: error), privacy: .public)")
            }
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
                        apps: entries.filter { $0.installation.deviceID == d.id })
        }
        let known = Set(groups.map(\.id))
        var orphanIDs: [String] = []
        for e in entries where !known.contains(e.installation.deviceID) && !orphanIDs.contains(e.installation.deviceID) {
            orphanIDs.append(e.installation.deviceID)
        }
        let names = cachedNames
        for id in orphanIDs {
            groups.append(DeviceGroup(id: id, device: nil, name: names[id] ?? L("popover.unknownDevice"),
                                      kind: .iPhone, apps: entries.filter { $0.installation.deviceID == id }))
        }
        return groups
    }

    private static let namesKey = "deviceNames"
    private var cachedNames: [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
    }
    private func rememberNames(_ list: [Device]) {
        var names = cachedNames
        for d in list where d.isPaired { names[d.id] = d.name }
        UserDefaults.standard.set(names, forKey: Self.namesKey)
    }

    // MARK: - Library

    func reloadRecords() async {
        records = await library.records()
    }

    private func updateAppIDCounter() async {
        guard case .success(let env) = environment else { appIDsRemaining = nil; return }
        let profiles = await ProfileReader(runner: runner).scan(paths.xcodeProfileDirs)
        appIDsRemaining = AppIDCounter.remaining(profiles, teamID: env.teamID, now: Date())
    }

    /// Resolves an icon path from `InstallOptions` (library-relative once saved, absolute when just chosen).
    func iconURL(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : library.root.appendingPathComponent(path)
    }

    // MARK: - Install

    /// Inspect → import (or update the existing record) → save options → sign and install.
    /// `options == nil` keeps the options remembered for this app.
    @discardableResult
    func importAndInstall(_ ipa: URL, on device: Device, options: InstallOptions? = nil,
                          progress: @escaping @MainActor @Sendable (InstallStep) -> Void = { _ in }) async throws -> AppRecord {
        guard let env = try environment?.get(), let pipeline else { throw XSideError.xcodeMissing }
        let info: AppInfo
        if let flow = install, flow.ipa == ipa, let known = flow.info {
            info = known
        } else {
            info = try await IPAImporter.inspect(ipa: ipa, runner: runner)
        }
        let record = try await library.importIPA(ipa, info: info, teamID: env.teamID)
        if let options { try await library.setOptions(options, for: record.id) }
        await reloadRecords()
        try await run(pipeline, recordID: record.id, device: device, progress: progress)
        return record
    }

    func refreshNow(_ job: RefreshJob) {
        guard let pipeline, jobs[JobKey(recordID: job.recordID, deviceID: job.deviceID)] == nil,
              let device = devices.first(where: { $0.id == job.deviceID }) else { return }
        Task { try? await run(pipeline, recordID: job.recordID, device: device) }
    }

    func canRefresh(_ entry: AppEntry) -> Bool {
        pipeline != nil && jobs[entry.id] == nil
            && devices.contains { $0.id == entry.installation.deviceID && $0.isAvailable }
    }

    private func run(_ pipeline: SideloadPipeline, recordID: UUID, device: Device,
                     progress: @escaping @MainActor @Sendable (InstallStep) -> Void = { _ in }) async throws {
        let key = JobKey(recordID: recordID, deviceID: device.id)
        jobs[key] = .profile
        defer { jobs[key] = nil }
        do {
            _ = try await pipeline.install(recordID: recordID, device: device) { step in
                await MainActor.run {
                    self.jobs[key] = step
                    progress(step)
                }
            }
        } catch {
            await reloadRecords()
            throw error
        }
        await reloadRecords()
        await updateAppIDCounter()
    }

    // MARK: - Install window flow

    private func beginFlow() {
        if let current = install, current.isRunning { return }
        guard let url = pendingIPA else { install = nil; return }
        let flow = InstallFlow(ipa: url)
        install = flow
        autoselectDevice()
        Task {
            do {
                let info = try await IPAImporter.inspect(ipa: url, runner: runner)
                guard install === flow else { return }
                flow.info = info
                let existing = records.first { $0.originalBundleID == info.bundleID }
                flow.existing = existing
                flow.draft = OptionsDraft(existing?.options ?? InstallOptions())
                flow.phase = .editing(error: nil)
            } catch {
                guard install === flow else { return }
                flow.phase = .rejected(localizedMessage(error))
            }
        }
        refreshDevices()
    }

    /// Identifier the app is signed with when no custom one is set.
    func defaultBundleID(for flow: InstallFlow) -> String? {
        guard let info = flow.info else { return nil }
        if let existing = flow.existing { return "\(existing.originalBundleID).\(existing.teamID)" }
        guard case .success(let env) = environment else { return info.bundleID }
        return "\(info.bundleID).\(env.teamID)"
    }

    /// True when the draft identifier would register a new App ID.
    func usesNewAppID(_ flow: InstallFlow) -> Bool {
        let custom = flow.draft.bundleID.trimmingCharacters(in: .whitespaces)
        guard !custom.isEmpty else { return false }
        return custom != flow.existing?.signedBundleID
    }

    private func autoselectDevice() {
        guard let flow = install, !flow.isRunning else { return }
        let available = pairedDevices.filter(\.isAvailable)
        if let id = flow.deviceID, available.contains(where: { $0.id == id }) { return }
        flow.deviceID = available.first?.id
    }

    func startInstall() {
        guard let flow = install, !flow.isRunning,
              let device = devices.first(where: { $0.id == flow.deviceID && $0.isAvailable }) else { return }
        let options = flow.draft.options
        flow.phase = .running(.profile)
        Task {
            do {
                try await importAndInstall(flow.ipa, on: device, options: options) { flow.phase = .running($0) }
                flow.phase = .succeeded(deviceName: device.name, guide: guideIfFirstInstall(on: device))
            } catch {
                flow.phase = .editing(error: localizedMessage(error))
            }
        }
    }

    /// The guide shows once per device, after its first successful install.
    private func guideIfFirstInstall(on device: Device) -> FirstInstallGuide? {
        let key = "guideShown.\(device.id)"
        guard !UserDefaults.standard.bool(forKey: key) else { return nil }
        UserDefaults.standard.set(true, forKey: key)
        let account = (try? environment?.get())?.identityName ?? "Apple Development"
        return FirstInstallGuide(accountName: account, needsDeveloperMode: device.developerModeEnabled == false)
    }

    /// The install window closed or was dismissed. A running install keeps going (its row shows progress).
    func closeInstall() {
        guard install?.isRunning != true else { return }
        pendingIPA = nil
    }
}

/// Where XSide keeps its files. Nothing here is specific to a Mac or an account.
private struct Paths {
    let root: URL
    let provisioningWork: URL
    let jobsWork: URL
    let template: URL
    let xcodeProfileDirs: [URL]

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("XSide", isDirectory: true)
        provisioningWork = root.appendingPathComponent("work/provisioning", isDirectory: true)
        jobsWork = root.appendingPathComponent("work/jobs", isDirectory: true)
        template = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("ProvisioningTemplate", isDirectory: true)
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        xcodeProfileDirs = [
            library.appendingPathComponent("Developer/Xcode/UserData/Provisioning Profiles", isDirectory: true),
            library.appendingPathComponent("MobileDevice/Provisioning Profiles", isDirectory: true),
        ]
    }
}
