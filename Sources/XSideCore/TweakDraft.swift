import Foundation

/// One tweak of step ③, with each selected device's choice and verdict.
public struct TweakDraft: Identifiable, Sendable {
    public let package: TweakPackage
    /// The package's stored folder: in the library for the app's own, in `tweakStaging` otherwise.
    public let directory: URL
    /// Devices where its switch is on.
    public var enabledDevices: Set<String>
    /// Devices where « Injecter quand même » is on.
    public var force: Set<String>
    /// The verdict on each device, as is (`TweakClassifier.classify`).
    public var verdicts: [String: TweakVerdict]
    /// …and with « Injecter quand même » (differs only for an overridable ❌).
    public var forcedVerdicts: [String: TweakVerdict]
    /// Already in the app's pool (the library): nothing to hand over at Install.
    public var stored: Bool
    /// The pool's package it replaces (another version of the same package id, confirmed).
    public var replacing: String?
    /// Devices whose stored list has it (on or off): they keep it, off, when its switch is off.
    public var listedDevices: Set<String>
    /// Devices it got a starting choice for; one checked later gets its own then.
    public var seenDevices: Set<String>
    /// Devices whose last signing injected it: a ❌ from the check made here (without the app's
    /// files or the SDK) doesn't switch it off there; the signing checks it again.
    public var injectedOn: Set<String>
    /// Per device, the `Depends` package ids missing there (« Dépendances »), flagged on its row.
    public var missingDependencies: [String: [String]]

    public init(package: TweakPackage, directory: URL, enabledDevices: Set<String>, force: Set<String>,
                verdicts: [String: TweakVerdict], forcedVerdicts: [String: TweakVerdict] = [:], stored: Bool = false,
                replacing: String? = nil, listedDevices: Set<String> = [], seenDevices: Set<String> = [],
                injectedOn: Set<String> = [], missingDependencies: [String: [String]] = [:]) {
        self.package = package
        self.directory = directory
        self.enabledDevices = enabledDevices
        self.force = force
        self.verdicts = verdicts
        self.forcedVerdicts = forcedVerdicts
        self.stored = stored
        self.replacing = replacing
        self.listedDevices = listedDevices
        self.seenDevices = seenDevices
        self.injectedOn = injectedOn
        self.missingDependencies = missingDependencies
    }

    public var id: String { package.id }

    /// What applies on `deviceID`: the forced verdict when « Injecter quand même » is on there.
    public func verdict(on deviceID: String) -> TweakVerdict? {
        let base = verdicts[deviceID]
        guard force.contains(deviceID), base?.canOverride == true else { return base }
        return forcedVerdicts[deviceID] ?? base
    }

    /// Goes in the app on `deviceID`: its switch on and not ❌ there.
    public func isEnabled(on deviceID: String) -> Bool {
        guard enabledDevices.contains(deviceID), let v = verdict(on: deviceID) else { return false }
        if case .incompatible = v { return injectedOn.contains(deviceID) }
        return true
    }

    /// Its entry in `deviceID`'s list for the run: on, off (kept, for a device that had it), or none.
    /// A device not judged yet keeps its switch as is (mega review U1): the signing checks it.
    public func use(on deviceID: String) -> TweakUse? {
        let forced: Bool? = force.contains(deviceID) ? true : nil
        let on = verdicts[deviceID] == nil ? enabledDevices.contains(deviceID) : isEnabled(on: deviceID)
        if on { return TweakUse(id: id, enabled: true, force: forced) }
        return listedDevices.contains(deviceID) ? TweakUse(id: id, enabled: false, force: forced) : nil
    }

    /// What to ask about before it goes in converted on `deviceID`: nil when it isn't converted
    /// there, is off, or is the app's own and the last signing already put it in there (mega
    /// review U12: not asked again at every reinstall).
    public func conversionsToConfirm(on deviceID: String) -> [TweakConversion]? {
        guard isEnabled(on: deviceID), case .converted(let list)? = verdict(on: deviceID) else { return nil }
        if stored && injectedOn.contains(deviceID) { return nil }
        return list
    }
}
