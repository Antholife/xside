import Foundation
import os

// MARK: - Step abstractions (the concrete structs conform; tests inject fakes)

public protocol Provisioning: Sendable {
    func profile(bundleID: String, env: SigningEnvironment,
                 deviceUDIDs: [String]) async throws -> (url: URL, profile: ProvisioningProfile)
}

public protocol Resigning: Sendable {
    /// `otherBundleIDs`: the signed ids of XSide's other apps, whose own keychain groups the app
    /// must never be granted.
    func resign(ipa: URL, workDir: URL, bundleID: String, options: InstallOptions,
                iconURL: URL?, profileURL: URL, profile: ProvisioningProfile,
                identitySHA1: String, otherBundleIDs: Set<String>) async throws -> URL
}

public protocol Installing: Sendable {
    func install(app: URL, deviceID: String) async throws
    func uninstall(bundleID: String, deviceID: String) async throws
}

extension Provisioner: Provisioning {}
extension Resigner: Resigning {}
extension Installer: Installing {}

// MARK: - Pipeline

/// Phase reported by `SideloadPipeline.install(recordID:device:env:refresh:progress:)` as each step starts.
public enum InstallStep: Int, CaseIterable, Sendable {
    case profile, signing, installing
}

/// FIFO async mutex: `run` bodies execute one at a time, in arrival order. A task already
/// cancelled, or cancelled while it waits, throws `CancellationError` without taking the lock
/// (its body never runs); a body that throws, or is cancelled while running, still hands it on.
actor AsyncLock {
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }

    /// Waiters still queued (tests).
    var waiterCount: Int { waiters.count }

    /// Tests: callers suspended until that many waiters are queued.
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Tests: returns once at least `count` waiters are queued (no polling).
    func untilWaiting(_ count: Int) async {
        if waiters.count >= count { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard busy else {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Cancelled before queueing: the handler below already ran and found nothing to remove.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                    let ready = watchers.filter { $0.count <= waiters.count }
                    watchers.removeAll { $0.count <= waiters.count }
                    for watcher in ready { watcher.continuation.resume() }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Still queued: leaves without the lock. Already handed the lock: nothing to do, its body
    /// starts, sees the cancellation and releases the lock.
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().continuation.resume() }
    }
}

/// Waits for `previous` to end, or throws `CancellationError` as soon as the calling task is
/// cancelled (a `Task<Void, Never>`'s `value` ignores cancellation). `previous` itself goes on.
func waitCancellably(for previous: Task<Void, Never>?) async throws {
    guard let previous else { return }
    let gate = OnceContinuation()
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            gate.install(continuation)
            Task {
                await previous.value
                gate.resume(with: nil)
            }
        }
    } onCancel: {
        gate.resume(with: CancellationError())
    }
}

/// A continuation resumed once, by whichever comes first; an outcome arriving before the
/// continuation is installed is kept and applied on install.
private final class OnceContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    /// Set once: nil inside means success.
    private var outcome: (any Error)??

    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        lock.lock()
        guard let outcome else {
            self.continuation = continuation
            lock.unlock()
            return
        }
        lock.unlock()
        Self.resume(continuation, outcome)
    }

    func resume(with error: (any Error)?) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = .some(error)
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let pending { Self.resume(pending, error) }
    }

    private static func resume(_ continuation: CheckedContinuation<Void, any Error>, _ error: (any Error)?) {
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}

/// Provision -> resign -> install -> record. Jobs targeting the same `device.id` run one after
/// another; jobs for different devices may run concurrently, except provisioning: only one
/// provisioning (Xcode cache purge + xcodebuild) runs at a time across all jobs, since they share
/// the team's account and Xcode's profile cache. Keep one pipeline for the app's lifetime: both
/// guarantees hold only within one instance. The signing environment is given per job.
public actor SideloadPipeline {
    private static let logger = Logger(subsystem: "io.github.xside.XSide", category: "pipeline")
    private let library: AppLibrary
    private let provisioner: any Provisioning
    private let resigner: any Resigning
    private let installer: any Installing
    private let workRoot: URL
    private let now: @Sendable () -> Date
    /// The Mac runs a macOS beta: failures with a release Xcode are explained as such.
    private let macIsBeta: Bool
    private let provisioningLock = AsyncLock()

    /// Last queued job per device id. Read and replaced without any `await` in between, so the
    /// chain stays ordered even though the actor is reentrant. Each tail waits for the one before it
    /// and for its own job, so a job cancelled while queued never lets a later one skip ahead.
    private var tails: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    public init(library: AppLibrary, provisioner: any Provisioning, resigner: any Resigning,
                installer: any Installing, workRoot: URL,
                now: @escaping @Sendable () -> Date, macIsBeta: Bool = false) {
        self.library = library
        self.provisioner = provisioner
        self.resigner = resigner
        self.installer = installer
        self.workRoot = workRoot
        self.now = now
        self.macIsBeta = macIsBeta
    }

    /// `progress` is awaited as each step starts (profile, signing, installing), in that order.
    /// `.profile` fires once the provisioning lock is held, not while waiting for it.
    /// `refresh`: renews the device's installation with the bundle id it was signed with (another
    /// device may have been reinstalled with a new custom id since); otherwise the record's
    /// current `signedBundleID` is used.
    /// `environment` is asked once the job holds the provisioning lock: a job queued behind others
    /// signs with the identity current when it actually runs. When it throws (the environment
    /// broke meanwhile), the job fails with that error and nothing is recorded on the row.
    /// Cancelling the calling task cancels the job at once, wherever it is: its running subprocess
    /// is stopped, and a wait for the provisioning lock or for the device's previous job ends
    /// (that job goes on, and jobs queued later still wait for it). It throws `CancellationError`
    /// and records nothing, so an existing installation is left exactly as it was.
    public func install(recordID: UUID, device: Device,
                        environment: @escaping @Sendable () async throws -> SigningEnvironment,
                        refresh: Bool = false,
                        progress: @escaping @Sendable (InstallStep) async -> Void = { _ in }) async throws -> Installation {
        let previous = tails[device.id]?.task
        let token = UUID()
        let job = Task<Installation, Error> {
            try await waitCancellably(for: previous)
            try Task.checkCancellation()
            return try await self.perform(recordID: recordID, device: device, environment: environment,
                                          refresh: refresh, progress: progress)
        }
        // The chain waits for the previous job too: one cancelled while queued ends at once, and a
        // job queued after it must still wait for the one running.
        tails[device.id] = (token, Task {
            await previous?.value
            _ = try? await job.value
            self.chainEnded(device.id, token: token)
        })
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    /// The tail queued with `token` is done, and so is everything before it: forgotten unless a
    /// later job took its place. Not when the caller returns: a job cancelled while queued
    /// returns early, and the jobs before it may still run.
    private func chainEnded(_ deviceID: String, token: UUID) {
        if tails[deviceID]?.token == token { tails[deviceID] = nil }
    }

    /// Removes the record's app from the device, then its installation from the library (the
    /// record itself stays, even with no installation left: see `AppLibrary.removeIfEmpty`).
    /// Queued on the device's chain like an install, so it never overlaps a job on that device;
    /// no provisioning, so the provisioning lock isn't taken. The app removed is the one the
    /// device was signed with. `developerDir` is asked once the job runs, like an install's
    /// environment: nil leaves `DEVELOPER_DIR` to the runner. Throws `recordNotFound` when the
    /// installation is gone (removed meanwhile); on failure the library is left untouched.
    public func uninstall(recordID: UUID, deviceID: String,
                          developerDir: @escaping @Sendable () async -> URL?) async throws {
        let previous = tails[deviceID]?.task
        let token = UUID()
        let job = Task<Void, Error> {
            try await waitCancellably(for: previous)
            try Task.checkCancellation()
            try await self.performUninstall(recordID: recordID, deviceID: deviceID, developerDir: developerDir)
        }
        tails[deviceID] = (token, Task {
            await previous?.value
            _ = try? await job.value
            self.chainEnded(deviceID, token: token)
        })
        try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    private nonisolated func performUninstall(recordID: UUID, deviceID: String,
                                              developerDir: @Sendable () async -> URL?) async throws {
        guard let record = await library.records().first(where: { $0.id == recordID }),
              let installation = record.installations.first(where: { $0.deviceID == deviceID }) else {
            throw XSideError.recordNotFound
        }
        let bundleID = installation.signedBundleID ?? record.signedBundleID
        if let dir = await developerDir() {
            try await CommandEnvironment.withDeveloperDir(dir) { [installer] in
                try await installer.uninstall(bundleID: bundleID, deviceID: deviceID)
            }
        } else {
            try await installer.uninstall(bundleID: bundleID, deviceID: deviceID)
        }
        // Still on the device's chain: a job queued behind sees the installation gone. A record
        // deleted meanwhile has nothing left to forget.
        do {
            try await library.removeInstallation(recordID: recordID, deviceID: deviceID)
        } catch XSideError.recordNotFound {}
    }

    /// A fixed environment (tests, callers that just probed).
    public func install(recordID: UUID, device: Device, env: SigningEnvironment, refresh: Bool = false,
                        progress: @escaping @Sendable (InstallStep) async -> Void = { _ in }) async throws -> Installation {
        try await install(recordID: recordID, device: device, environment: { env }, refresh: refresh, progress: progress)
    }

    /// Thrown inside the provisioning lock when `environment` fails, to tell it from a job failure.
    private struct EnvironmentUnavailable: Error { let underlying: any Error }

    private nonisolated func perform(recordID: UUID, device: Device,
                                     environment: @escaping @Sendable () async throws -> SigningEnvironment,
                                     refresh: Bool,
                                     progress: @Sendable (InstallStep) async -> Void) async throws -> Installation {
        guard let record = await library.records().first(where: { $0.id == recordID }) else {
            throw XSideError.recordNotFound
        }
        let previous = record.installations.first { $0.deviceID == device.id }
        let previousBundleID = previous.map { $0.signedBundleID ?? record.signedBundleID }
        let bundleID = refresh ? previousBundleID ?? record.signedBundleID : record.signedBundleID

        let fm = FileManager.default
        let workDir = workRoot.appendingPathComponent("job-\(UUID().uuidString)", isDirectory: true)
        var profileURL: URL?
        var env: SigningEnvironment?
        defer {
            try? fm.removeItem(at: workDir)
            if let profileURL { try? fm.removeItem(at: profileURL) }
        }

        do {
            // Inside the `do` so the failure is recorded (`lastAttempt` drives the retry delay).
            guard let udid = device.udid else { throw XSideError.deviceUnavailable }
            let ipa = try resolve(record.ipaPath)
            let icon = try record.options.iconPath.flatMap { $0.isEmpty ? nil : try resolve($0) }
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

            // Reported once the lock is held: a job queued behind another provisioning is still waiting.
            let (current, provisioned) = try await provisioningLock.run { [provisioner] in
                try Task.checkCancellation()
                let current: SigningEnvironment
                do { current = try await environment() } catch { throw EnvironmentUnavailable(underlying: error) }
                await progress(.profile)
                let provisioned = try await CommandEnvironment.withDeveloperDir(current.developerDir) {
                    try await provisioner.profile(bundleID: bundleID, env: current, deviceUDIDs: [udid])
                }
                return (current, provisioned)
            }
            env = current
            profileURL = provisioned.url
            // A refresh must push the expiry forward; otherwise Xcode reused the cached profile and
            // reinstalling would only reset the 7 days we don't actually have. A new bundle id is a
            // new App ID, unrelated to the previous expiry. With a new certificate, the same
            // still-valid profile may come back (it already lists that certificate): re-signing
            // is the point then, not the expiry.
            let certificateChanged = previous?.signingIdentitySHA1.map {
                $0.uppercased() != current.identitySHA1.uppercased()
            } ?? false
            if let previous, previousBundleID == bundleID, !certificateChanged,
               provisioned.profile.expirationDate <= previous.expiresAt {
                throw XSideError.profileNotRenewed
            }
            await progress(.signing)
            let others = await library.records().filter { $0.id != recordID }
                .reduce(into: Set<String>()) { ids, other in
                    ids.insert(other.signedBundleID)
                    for i in other.installations { if let id = i.signedBundleID { ids.insert(id) } }
                }
            // The job's tools all use the Xcode of the environment it started with.
            let app = try await CommandEnvironment.withDeveloperDir(current.developerDir) { [resigner] in
                try await resigner.resign(
                    ipa: ipa, workDir: workDir, bundleID: bundleID, options: record.options,
                    iconURL: icon, profileURL: provisioned.url, profile: provisioned.profile,
                    identitySHA1: current.identitySHA1, otherBundleIDs: others)
            }
            await progress(.installing)
            try await CommandEnvironment.withDeveloperDir(current.developerDir) { [installer] in
                try await installer.install(app: app, deviceID: device.id)
            }

            let date = now()
            let installation = Installation(deviceID: device.id, installedAt: date,
                                            expiresAt: provisioned.profile.expirationDate,
                                            lastAttempt: date, lastErrorKey: nil, signedBundleID: bundleID,
                                            signingIdentitySHA1: current.identitySHA1, teamID: current.teamID)
            try await library.upsert(installation, for: recordID, requireExisting: previous != nil)
            return installation
        } catch let unavailable as EnvironmentUnavailable {
            // Not this row's failure: no attempt recorded, so the refresh runs once it's fixed.
            throw unavailable.underlying
        } catch where error is CancellationError || Task.isCancelled {
            // Stopped by the user (or the app): not a failure of the row. Nothing is recorded, so
            // no error is shown and no retry delay applies; the installation stays as it was.
            throw CancellationError()
        } catch {
            let developerDir = env?.developerDir
            let releaseXcode = developerDir.flatMap(XcodeCompat.xcodeVersion).map { !$0.isBeta } ?? false
            let explained = XcodeCompat.explain(error, deviceOS: device.osVersion,
                                                sdkVersion: developerDir.flatMap(XcodeCompat.iOSSDKVersion),
                                                macBetaWithReleaseXcode: macIsBeta && releaseXcode)
            if let replaced = explained as? XSideError, replaced != error as? XSideError {
                // The likely cause is shown; keep the actual failure for diagnosis.
                Self.logger.error("""
                    \(replaced.key, privacy: .public) (device iOS \(device.osVersion ?? "?", privacy: .public)) \
                    explains: \(String(describing: error), privacy: .public)
                    """)
            }
            if var failed = previous {
                failed.lastAttempt = now()
                failed.lastErrorKey = (explained as? XSideError)?.key ?? "unknown"
                try? await library.upsert(failed, for: recordID, requireExisting: true)
            }
            throw explained
        }
    }

    /// Resolves a library-relative path, refusing anything that escapes the library root.
    private nonisolated func resolve(_ relative: String) throws -> URL {
        let root = library.root.standardizedFileURL
        let url = root.appendingPathComponent(relative).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else {
            throw XSideError.invalidIPA("Path outside the library: \(relative)")
        }
        return url
    }
}
