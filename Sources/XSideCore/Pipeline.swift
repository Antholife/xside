import Foundation
import os

// MARK: - Step abstractions (the concrete structs conform; tests inject fakes)

public protocol Provisioning: Sendable {
    func profile(bundleID: String, env: SigningEnvironment,
                 deviceUDIDs: [String]) async throws -> (url: URL, profile: ProvisioningProfile)
}

public protocol Resigning: Sendable {
    func resign(ipa: URL, workDir: URL, bundleID: String, options: InstallOptions,
                iconURL: URL?, profileURL: URL, profile: ProvisioningProfile,
                identitySHA1: String) async throws -> URL
}

public protocol Installing: Sendable {
    func install(app: URL, deviceID: String) async throws
}

extension Provisioner: Provisioning {}
extension Resigner: Resigning {}
extension Installer: Installing {}

// MARK: - Pipeline

/// Phase reported by `SideloadPipeline.install(recordID:device:progress:)` as each step starts.
public enum InstallStep: Int, CaseIterable, Sendable {
    case profile, signing, installing
}

/// FIFO async mutex: `run` bodies execute one at a time, in arrival order.
actor AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

/// Provision -> resign -> install -> record. Jobs targeting the same `device.id` run one after
/// another; jobs for different devices may run concurrently, except provisioning: only one
/// provisioning (Xcode cache purge + xcodebuild) runs at a time across all jobs, since they share
/// the team's account and Xcode's profile cache.
public actor SideloadPipeline {
    private static let logger = Logger(subsystem: "io.github.xside.XSide", category: "pipeline")
    private let library: AppLibrary
    private let provisioner: any Provisioning
    private let resigner: any Resigning
    private let installer: any Installing
    private let env: SigningEnvironment
    private let workRoot: URL
    private let now: @Sendable () -> Date
    /// The Mac runs a macOS beta: failures with a release Xcode are explained as such.
    private let macIsBeta: Bool
    private let provisioningLock = AsyncLock()

    /// Last queued job per device id. Read and replaced without any `await` in between, so the
    /// chain stays ordered even though the actor is reentrant.
    private var tails: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    public init(library: AppLibrary, provisioner: any Provisioning, resigner: any Resigning,
                installer: any Installing, env: SigningEnvironment, workRoot: URL,
                now: @escaping @Sendable () -> Date, macIsBeta: Bool = false) {
        self.library = library
        self.provisioner = provisioner
        self.resigner = resigner
        self.installer = installer
        self.env = env
        self.workRoot = workRoot
        self.now = now
        self.macIsBeta = macIsBeta
    }

    /// `progress` is awaited as each step starts (profile, signing, installing), in that order.
    /// `.profile` fires once the provisioning lock is held, not while waiting for it.
    public func install(recordID: UUID, device: Device,
                        progress: @escaping @Sendable (InstallStep) async -> Void = { _ in }) async throws -> Installation {
        let previous = tails[device.id]?.task
        let token = UUID()
        let job = Task<Installation, Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await self.perform(recordID: recordID, device: device, progress: progress)
        }
        tails[device.id] = (token, Task { _ = try? await job.value })
        defer {
            if tails[device.id]?.token == token { tails[device.id] = nil }
        }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    private nonisolated func perform(recordID: UUID, device: Device,
                                     progress: @Sendable (InstallStep) async -> Void) async throws -> Installation {
        guard let record = await library.records().first(where: { $0.id == recordID }) else {
            throw XSideError.recordNotFound
        }
        let previous = record.installations.first { $0.deviceID == device.id }

        let fm = FileManager.default
        let workDir = workRoot.appendingPathComponent("job-\(UUID().uuidString)", isDirectory: true)
        var profileURL: URL?
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
            let provisioned = try await provisioningLock.run { [provisioner, env] in
                try Task.checkCancellation()
                await progress(.profile)
                return try await provisioner.profile(bundleID: record.signedBundleID, env: env, deviceUDIDs: [udid])
            }
            profileURL = provisioned.url
            // A refresh must push the expiry forward; otherwise Xcode reused the cached profile and
            // reinstalling would only reset the 7 days we don't actually have.
            if let previous, provisioned.profile.expirationDate <= previous.expiresAt {
                throw XSideError.profileNotRenewed
            }
            await progress(.signing)
            let app = try await resigner.resign(
                ipa: ipa, workDir: workDir, bundleID: record.signedBundleID, options: record.options,
                iconURL: icon, profileURL: provisioned.url, profile: provisioned.profile,
                identitySHA1: env.identitySHA1)
            await progress(.installing)
            try await installer.install(app: app, deviceID: device.id)

            let date = now()
            let installation = Installation(deviceID: device.id, installedAt: date,
                                            expiresAt: provisioned.profile.expirationDate,
                                            lastAttempt: date, lastErrorKey: nil)
            try await library.upsert(installation, for: recordID, requireExisting: previous != nil)
            return installation
        } catch {
            let releaseXcode = XcodeCompat.xcodeVersion(developerDir: env.developerDir).map { !$0.isBeta } ?? false
            let explained = XcodeCompat.explain(error, deviceOS: device.osVersion,
                                                sdkVersion: XcodeCompat.iOSSDKVersion(developerDir: env.developerDir),
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
            throw XSideError.invalidIPA("Chemin hors de la bibliothèque : \(relative)")
        }
        return url
    }
}
