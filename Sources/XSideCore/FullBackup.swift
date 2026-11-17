import Foundation

/// A full backup bundles a chosen set of XSide apps into one `.xsbak` archive (a zip): per app its
/// `original.ipa` and tweak `.deb`s (when "App" was chosen), a data snapshot (when "Données" was
/// chosen), and this manifest. The restore drives the normal install pipeline per app, so the app
/// comes back with its options, update source, compatibility, in-app XSide settings, tweaks and data.
///
/// The manifest is the restorable subset only: device-transient and secret fields of `Installation`
/// (channel secret, signing identity, expiry, check-in times) are never written to the archive.
public struct FullBackupManifest: Codable, Equatable, Sendable {
    /// Archive format version, so a newer XSide can refuse or migrate an older/newer archive.
    public var version: Int
    public var createdAt: Date
    /// XSide version that wrote the archive (informational).
    public var appVersion: String
    public var apps: [BackupAppEntry]

    public static let currentVersion = 1

    public init(version: Int = FullBackupManifest.currentVersion, createdAt: Date, appVersion: String,
                apps: [BackupAppEntry]) {
        self.version = version
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.apps = apps
    }
}

/// One app inside a full backup, and what the archive actually holds for it. A part the person left
/// out is simply absent: `hasIPA`/`hasData` are false, or the installation config carries nil/empty
/// for the excluded compatibility / in-app / tweaks.
public struct BackupAppEntry: Codable, Equatable, Sendable {
    public var recordID: UUID
    public var displayName: String
    public var originalBundleID: String
    /// The record's install options (name, bundle id, icon, min OS, file sharing, …).
    public var options: InstallOptions
    /// The followed GitHub update source, when the app had one (so it keeps updating after restore).
    public var updateSource: UpdateSource?
    /// The restorable installation config: compatibility, in-app settings, tweaks (only the parts
    /// that were included).
    public var installation: InstallationConfig
    /// `apps/<id>/original.ipa` is present.
    public var hasIPA: Bool
    /// `apps/<id>/data.zip` is present.
    public var hasData: Bool
    public var dataIncludesCaches: Bool
    public var ipaBytes: Int
    public var dataBytes: Int
    /// packageID → deb file name inside `apps/<id>/tweaks/` (empty when no tweaks were included).
    public var tweakFiles: [String: String]

    public init(recordID: UUID, displayName: String, originalBundleID: String, options: InstallOptions,
                updateSource: UpdateSource? = nil, installation: InstallationConfig, hasIPA: Bool, hasData: Bool,
                dataIncludesCaches: Bool, ipaBytes: Int, dataBytes: Int, tweakFiles: [String: String]) {
        self.recordID = recordID
        self.displayName = displayName
        self.originalBundleID = originalBundleID
        self.options = options
        self.updateSource = updateSource
        self.installation = installation
        self.hasIPA = hasIPA
        self.hasData = hasData
        self.dataIncludesCaches = dataIncludesCaches
        self.ipaBytes = ipaBytes
        self.dataBytes = dataBytes
        self.tweakFiles = tweakFiles
    }

    /// Which aspects the archive can restore for this app (greys the unchecked columns in the sheet).
    /// Compatibility / in-app / tweaks need the IPA; each is available only if it was actually stored.
    public var availableAspects: BackupAspects {
        BackupAspects(
            app: hasIPA,
            compat: hasIPA && (installation.duoCompatibility != nil || installation.iCloudSignedOut != nil),
            inApp: hasIPA && installation.inApp != nil,
            tweaks: hasIPA && !installation.tweaks.isEmpty,
            data: hasData)
    }
}

/// The subset of `Installation` a reinstall needs to rebuild the app as it was. No secrets, no
/// device-transient state.
public struct InstallationConfig: Codable, Equatable, Sendable {
    public var sourceDeviceID: String
    public var sourceDeviceName: String
    public var appVersion: String?
    public var duoCompatibility: Bool?
    public var iCloudSignedOut: Bool?
    public var withoutXSideFeatures: Bool?
    public var inApp: InAppSettings?
    public var tweaks: [TweakUse]

    public init(sourceDeviceID: String, sourceDeviceName: String, appVersion: String? = nil,
                duoCompatibility: Bool? = nil, iCloudSignedOut: Bool? = nil, withoutXSideFeatures: Bool? = nil,
                inApp: InAppSettings? = nil, tweaks: [TweakUse] = []) {
        self.sourceDeviceID = sourceDeviceID
        self.sourceDeviceName = sourceDeviceName
        self.appVersion = appVersion
        self.duoCompatibility = duoCompatibility
        self.iCloudSignedOut = iCloudSignedOut
        self.withoutXSideFeatures = withoutXSideFeatures
        self.inApp = inApp
        self.tweaks = tweaks
    }
}

/// The five per-app aspects, used as availability, the person's choice, and the resolved inclusion.
/// `app` is the IPA reinstall (which also carries the app's options and update source).
public struct BackupAspects: Equatable, Sendable {
    public var app: Bool
    public var compat: Bool
    public var inApp: Bool
    public var tweaks: Bool
    public var data: Bool

    public init(app: Bool = false, compat: Bool = false, inApp: Bool = false, tweaks: Bool = false, data: Bool = false) {
        self.app = app
        self.compat = compat
        self.inApp = inApp
        self.tweaks = tweaks
        self.data = data
    }

    public static let all = BackupAspects(app: true, compat: true, inApp: true, tweaks: true, data: true)
}

/// Pure decisions for building a backup selection and resolving a restore, kept UI-free and tested.
public enum FullBackup {
    /// What ends up in the archive for one app. Compatibility / in-app / tweaks are part of the
    /// install, so they need `app`; data is independent. A choice is honored only where available.
    public static func backupInclusion(available: BackupAspects, chosen: BackupAspects) -> BackupAspects {
        let app = available.app && chosen.app
        return BackupAspects(
            app: app,
            compat: app && available.compat && chosen.compat,
            inApp: app && available.inApp && chosen.inApp,
            tweaks: app && available.tweaks && chosen.tweaks,
            data: available.data && chosen.data)
    }

    /// Whether an app with this resolved inclusion belongs in the archive at all.
    public static func isIncluded(_ a: BackupAspects) -> Bool { a.app || a.data }

    /// What the restore will do for one archived app. The install pipeline reapplies the chosen
    /// config; `dataOnly` reinjects data onto an app already on the device.
    public enum RestoreAction: Equatable, Sendable {
        case reinstall(compat: Bool, inApp: Bool, tweaks: Bool, data: Bool)
        case dataOnly
        case skip
    }

    /// Resolves the per-app restore action, enforcing that compat/in-app/tweaks ride with `app` and
    /// that each chosen part exists in the archive.
    public static func restoreAction(available: BackupAspects, chosen: BackupAspects) -> RestoreAction {
        if available.app && chosen.app {
            return .reinstall(compat: available.compat && chosen.compat,
                              inApp: available.inApp && chosen.inApp,
                              tweaks: available.tweaks && chosen.tweaks,
                              data: available.data && chosen.data)
        }
        if available.data && chosen.data { return .dataOnly }
        return .skip
    }

    /// The archive's on-disk size estimate for one app's resolved inclusion (bytes actually written).
    public static func entryBytes(_ inc: BackupAspects, ipaBytes: Int, dataBytes: Int) -> Int {
        (inc.app ? ipaBytes : 0) + (inc.data ? dataBytes : 0)
    }

    /// Number of apps that will actually be restored (action is not `.skip`).
    public static func restoreCount(_ resolved: [RestoreAction]) -> Int {
        resolved.filter { $0 != .skip }.count
    }
}
