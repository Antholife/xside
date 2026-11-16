import Foundation

/// One file or folder of an app's data container, as `devicectl device info files` lists it.
public struct ContainerEntry: Equatable, Sendable {
    public let relativePath: String
    public let isDirectory: Bool
    public let size: Int?
    public let modified: Date?

    public init(relativePath: String, isDirectory: Bool, size: Int?, modified: Date?) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

/// Reads and writes an app's data container on a device with `devicectl` (domain
/// `appDataContainer`). File contents are never logged.
public struct AppDataContainer: Sendable {
    private let runner: CommandRunning
    private let scratchRoot: URL

    /// Left out of a backup: the app's temporary files.
    static let excludedPrefixes = ["tmp/"]
    static let cachesPrefix = "Library/Caches/"

    public init(runner: CommandRunning, scratchRoot: URL = FileManager.default.temporaryDirectory) {
        self.runner = runner
        self.scratchRoot = scratchRoot
    }

    /// The container's entries; nil when the listing isn't available or readable (the signal to
    /// fall back to a full copy). Throws only on cancellation or a runner failure.
    public func listFiles(signedBundleID: String, deviceID: String) async throws -> [ContainerEntry]? {
        let listFile = scratchRoot.appendingPathComponent("xside-container-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: listFile) }
        let result = try await runner.run("/usr/bin/xcrun",
                                          ["devicectl", "device", "info", "files", "--device", deviceID,
                                           "--domain-type", "appDataContainer", "--domain-identifier", signedBundleID,
                                           "--json-output", listFile.path],
                                          cwd: nil, timeout: CommandTimeout.deviceQuery)
        guard result.status == 0, let data = try? Data(contentsOf: listFile) else { return nil }
        return Self.parse(data)
    }

    static func parse(_ json: Data) -> [ContainerEntry]? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let files = result["files"] as? [Any] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return files.compactMap { item in
            guard let f = item as? [String: Any], let path = f["relativePath"] as? String, !path.isEmpty else { return nil }
            let isDirectory = (f["resources"] as? [String: Any])?["isDirectory"] as? Bool == true
            let metadata = f["metadata"] as? [String: Any] ?? [:]
            let dateText = metadata["lastModDate"] as? String
            return ContainerEntry(relativePath: path, isDirectory: isDirectory,
                                  size: (metadata["size"] as? NSNumber).map { $0.intValue },
                                  modified: dateText.flatMap { iso.date(from: $0) ?? plain.date(from: $0) })
        }
    }

    /// Copies `relativePath` of the container to `dest` on the Mac.
    public func pull(signedBundleID: String, deviceID: String, relativePath: String, to dest: URL) async throws {
        try await copy(["devicectl", "device", "copy", "from", "--device", deviceID,
                        "--domain-type", "appDataContainer", "--domain-identifier", signedBundleID,
                        "--source", relativePath, "--destination", dest.path])
    }

    /// Copies `src` from the Mac to `relativePath` of the container.
    public func push(signedBundleID: String, deviceID: String, from src: URL, relativePath: String) async throws {
        try await copy(["devicectl", "device", "copy", "to", "--device", deviceID,
                        "--domain-type", "appDataContainer", "--domain-identifier", signedBundleID,
                        "--source", src.path, "--destination", relativePath])
    }

    /// Stops the app; an app that isn't running is no failure.
    public func terminate(signedBundleID: String, deviceID: String) async throws {
        let result = try await runner.run("/usr/bin/xcrun",
                                          ["devicectl", "device", "process", "terminate", "--device", deviceID, signedBundleID],
                                          cwd: nil, timeout: CommandTimeout.deviceQuery)
        guard result.status != 0 else { return }
        let output = String(decoding: result.stdout, as: UTF8.self) + "\n" + result.stderr
        let mapped = Installer.mapError(output)
        if case .deviceUnavailable = mapped { throw mapped }
        let lower = output.lowercased()
        let notRunning = ["not running", "no process", "process not found", "not found", "no such process", "could not find"]
        if notRunning.contains(where: { lower.contains($0) }) { return }
        if case .commandFailed = mapped { throw XSideError.commandFailed(tool: "devicectl", status: result.status) }
        throw mapped
    }

    private func copy(_ arguments: [String]) async throws {
        let result = try await runner.run("/usr/bin/xcrun", arguments, cwd: nil, timeout: CommandTimeout.deviceInstall)
        guard result.status == 0 else {
            let mapped = Installer.mapError(String(decoding: result.stdout, as: UTF8.self) + "\n" + result.stderr)
            if case .commandFailed = mapped { throw XSideError.commandFailed(tool: "devicectl", status: result.status) }
            throw mapped
        }
    }
}
