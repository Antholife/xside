import Foundation

public struct Installation: Codable, Equatable, Sendable {
    public var deviceID: String
    public var installedAt: Date
    public var expiresAt: Date
    public var lastAttempt: Date?
    public var lastErrorKey: String?

    public init(deviceID: String, installedAt: Date, expiresAt: Date,
                lastAttempt: Date? = nil, lastErrorKey: String? = nil) {
        self.deviceID = deviceID
        self.installedAt = installedAt
        self.expiresAt = expiresAt
        self.lastAttempt = lastAttempt
        self.lastErrorKey = lastErrorKey
    }
}

public struct AppRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public let originalBundleID: String
    public var signedBundleID: String
    /// Path relative to the library root.
    public var ipaPath: String
    public var options: InstallOptions
    public var installations: [Installation]
    /// Team id used at import, needed to derive `signedBundleID`.
    public var teamID: String
    /// First successful install per signed bundle id (each one is an App ID). Lets the App ID
    /// counter date an App ID even after its cached profiles were replaced. nil in state written
    /// before this was tracked.
    public var appIDFirstUse: [String: Date]?
}

public actor AppLibrary {
    public nonisolated let root: URL
    private var items: [AppRecord] = []
    private var stateURL: URL { root.appendingPathComponent("state.json") }

    public init(root: URL) {
        self.root = root
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([AppRecord].self, from: data) {
            items = decoded
        } else {
            let corrupt = root.appendingPathComponent("state.json.corrupt")
            try? fm.removeItem(at: corrupt)
            try? fm.moveItem(at: url, to: corrupt)
        }
    }

    public func records() -> [AppRecord] {
        items.sorted {
            let c = $0.displayName.caseInsensitiveCompare($1.displayName)
            return c == .orderedSame ? $0.id.uuidString < $1.id.uuidString : c == .orderedAscending
        }
    }

    public func importIPA(_ source: URL, info: AppInfo, teamID: String) throws -> AppRecord {
        let fm = FileManager.default
        let index = items.firstIndex { $0.originalBundleID == info.bundleID }
        let id = index.map { items[$0].id } ?? UUID()
        let relative = "apps/\(id.uuidString)/original.ipa"
        let dest = root.appendingPathComponent(relative)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = dest.deletingLastPathComponent().appendingPathComponent(".incoming-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: dest)
        }

        let previous = items
        let record: AppRecord
        if let index {
            items[index].displayName = info.name
            items[index].ipaPath = relative
            record = items[index]
        } else {
            record = AppRecord(id: id, displayName: info.name, originalBundleID: info.bundleID,
                               signedBundleID: "\(info.bundleID).\(teamID)", ipaPath: relative,
                               options: InstallOptions(), installations: [], teamID: teamID)
            items.append(record)
        }
        do { try save() } catch { items = previous; throw error }
        return record
    }

    public func setOptions(_ options: InstallOptions, for id: UUID) throws {
        let index = try indexOf(id)
        let fm = FileManager.default
        var options = options
        let relativeIcon = "apps/\(id.uuidString)/icon.png"
        let iconURL = root.appendingPathComponent(relativeIcon)
        if let path = options.iconPath, !path.isEmpty {
            if path != relativeIcon {
                let source = URL(fileURLWithPath: path)
                try fm.createDirectory(at: iconURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let staging = iconURL.deletingLastPathComponent().appendingPathComponent(".incoming-\(UUID().uuidString)")
                try fm.copyItem(at: source, to: staging)
                if fm.fileExists(atPath: iconURL.path) {
                    _ = try fm.replaceItemAt(iconURL, withItemAt: staging)
                } else {
                    try fm.moveItem(at: staging, to: iconURL)
                }
                options.iconPath = relativeIcon
            }
        } else {
            options.iconPath = nil
            try? fm.removeItem(at: iconURL)
        }

        let previous = items
        let custom = options.customBundleID.flatMap { $0.isEmpty ? nil : $0 }
        items[index].options = options
        items[index].signedBundleID = custom ?? "\(items[index].originalBundleID).\(items[index].teamID)"
        do { try save() } catch { items = previous; throw error }
    }

    public func upsert(_ installation: Installation, for id: UUID) throws {
        let index = try indexOf(id)
        let previous = items
        if installation.lastErrorKey == nil, items[index].appIDFirstUse?[items[index].signedBundleID] == nil {
            // Nothing tracked yet (new or pre-tracking record): the earliest known installation.
            let since = items[index].appIDFirstUse == nil
                ? items[index].installations.map(\.installedAt).reduce(installation.installedAt, min)
                : installation.installedAt
            items[index].appIDFirstUse = (items[index].appIDFirstUse ?? [:])
                .merging([items[index].signedBundleID: since]) { old, _ in old }
        }
        if let i = items[index].installations.firstIndex(where: { $0.deviceID == installation.deviceID }) {
            items[index].installations[i] = installation
        } else {
            items[index].installations.append(installation)
        }
        do { try save() } catch { items = previous; throw error }
    }

    public func remove(_ id: UUID) throws {
        let index = try indexOf(id)
        let previous = items
        items.remove(at: index)
        do { try save() } catch { items = previous; throw error }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("apps/\(id.uuidString)"))
    }

    /// Forgets a device: drops its installations from every record and deletes the records left
    /// with none (with their files). One atomic save. Returns the number of installations removed.
    /// Nothing is uninstalled from the device itself.
    @discardableResult
    public func removeDevice(_ deviceID: String) throws -> Int {
        let previous = items
        var removed = 0
        var emptied: [UUID] = []
        for index in items.indices {
            let before = items[index].installations.count
            items[index].installations.removeAll { $0.deviceID == deviceID }
            let dropped = before - items[index].installations.count
            removed += dropped
            if dropped > 0, items[index].installations.isEmpty { emptied.append(items[index].id) }
        }
        guard removed > 0 else { return 0 }
        items.removeAll { emptied.contains($0.id) }
        do { try save() } catch { items = previous; throw error }
        for id in emptied {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("apps/\(id.uuidString)"))
        }
        return removed
    }

    private func indexOf(_ id: UUID) throws -> Int {
        guard let i = items.firstIndex(where: { $0.id == id }) else { throw XSideError.recordNotFound }
        return i
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(items)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let temp = root.appendingPathComponent(".state-\(UUID().uuidString).tmp")
        try data.write(to: temp)
        if fm.fileExists(atPath: stateURL.path) {
            _ = try fm.replaceItemAt(stateURL, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: stateURL)
        }
    }
}
