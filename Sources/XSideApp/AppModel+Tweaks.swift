import AppKit
import Foundation
import XSideCore

/// What the tweaks need from XSide's own bundle (`scripts/bundle.sh`): ElleKit and its licence,
/// the path redirect library, the embedded dependencies. Missing ones make the verdicts say so.
enum TweakResources {
    static let elleKit = Bundle.main.url(forResource: "ElleKit", withExtension: "dylib")
    static let elleKitLicense = Bundle.main.url(forResource: "ElleKit-LICENSE", withExtension: "txt")
    static let support = Bundle.main.url(forResource: "XSideTweakSupport", withExtension: "dylib")
    static let dependencies = Bundle.main.url(forResource: "TweakDependencies", withExtension: nil)
    static let elleKitHasLibhooker = Bundle.main.object(forInfoDictionaryKey: "XSideElleKitLibhooker") as? Bool ?? false
    /// XSide's embedded dependencies, read once.
    static let embedded = TweakDependencyCatalog.load(from: dependencies)

    private static func exists(_ url: URL?) -> Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// What the classifier knows when a tweak is added: the app's id and executable and the
    /// device's iOS; the app's classes and frameworks are checked again at signing.
    static func context(bundleID: String, executable: String?, deviceOS: String?, others: [TweakPackage]) -> TweakContext {
        TweakContext(originalBundleID: bundleID, executableName: executable, deviceOS: deviceOS,
                     elleKitAvailable: exists(elleKit) && exists(elleKitLicense), supportAvailable: exists(support),
                     elleKitHasLibhooker: elleKitHasLibhooker, others: others, embedded: embedded)
    }
}

extension AppModel {
    // MARK: Step ②

    /// An app already in the library: its tweaks listed on the selected devices, each device's
    /// switch from that installation's own list (or the one chosen before its first install).
    func prefillTweaks(_ flow: InstallFlow) {
        guard let record = flow.existing else { flow.tweaks = []; return }
        let lists = tweakLists(record)
        flow.tweaks = (record.tweaks ?? []).compactMap { package in
            let listed = Set(lists.filter { $0.value.contains { $0.id == package.id } }.map(\.key))
            guard !listed.isEmpty else { return nil }
            let uses = lists.compactMapValues { $0.first { $0.id == package.id } }
            return TweakDraft(package: package, directory: library.tweakDirectory(recordID: record.id, id: package.id),
                              enabledDevices: Set(uses.filter(\.value.enabled).map(\.key)),
                              force: Set(uses.filter { $0.value.force == true }.map(\.key)),
                              verdicts: [:], stored: true, listedDevices: listed, seenDevices: Set(lists.keys))
        }
        refreshTweakVerdicts(flow)
    }

    /// Every device's list: its installation's, else the one waiting for its first install.
    private func tweakLists(_ record: AppRecord) -> [String: [TweakUse]] {
        var lists = record.pendingTweakUses ?? [:]
        for i in record.installations { if let t = i.tweaks { lists[i.deviceID] = t } }
        return lists
    }

    /// A device checked since the tweaks were added gets its starting choice: an added tweak on
    /// where it isn't ❌. Then every verdict again. Nothing to do when no device is new.
    func syncTweakDevices(_ flow: InstallFlow) {
        guard flow.tweaks.contains(where: { !Set(flow.deviceIDs).isSubset(of: $0.seenDevices) }) else { return }
        refreshTweakVerdicts(flow)
        for i in flow.tweaks.indices {
            for id in flow.deviceIDs where !flow.tweaks[i].seenDevices.contains(id) {
                flow.tweaks[i].seenDevices.insert(id)
                if !flow.tweaks[i].stored, !isIncompatible(flow.tweaks[i].verdicts[id]) { flow.tweaks[i].enabledDevices.insert(id) }
            }
        }
        refreshTweakVerdicts(flow)
    }

    /// Classifies every tweak on every selected device, with the others enabled there.
    func refreshTweakVerdicts(_ flow: InstallFlow) {
        guard let info = flow.info else { return }
        let drafts = flow.tweaks
        for (i, draft) in drafts.enumerated() {
            var verdicts: [String: TweakVerdict] = [:], forced: [String: TweakVerdict] = [:]
            for id in flow.deviceIDs {
                let others = drafts.filter { $0.id != draft.id && $0.enabledDevices.contains(id) }.map(\.package)
                let c = TweakClassifier.classify(draft.package, TweakResources.context(
                    bundleID: info.bundleID, executable: info.executable,
                    deviceOS: devices.first { $0.id == id }?.osVersion, others: others))
                verdicts[id] = c.verdict
                forced[id] = c.verdictOverridingFilter
            }
            flow.tweaks[i].verdicts = verdicts
            flow.tweaks[i].forcedVerdicts = forced
        }
    }

    private func isIncompatible(_ verdict: TweakVerdict?) -> Bool {
        if case .incompatible? = verdict { return true }
        return false
    }

    /// Analyses each file into the window's staging folder; a new tweak starts on every selected
    /// device where it isn't ❌. Another version of a package already there asks to replace it.
    /// A file that can't be added says why in the section.
    func addTweaks(_ urls: [URL], to flow: InstallFlow) async {
        flow.tweakErrors = []
        guard !urls.isEmpty else { return }
        let staging: URL
        if let existing = flow.tweakStaging {
            staging = existing
        } else {
            staging = libraryRoot.appendingPathComponent(AppLibrary.stagingFolder).appendingPathComponent(UUID().uuidString)
            flow.tweakStaging = staging
        }
        for url in urls {
            let name = url.lastPathComponent
            flow.tweaksBeingAdded.append(name)
            defer { if let i = flow.tweaksBeingAdded.firstIndex(of: name) { flow.tweaksBeingAdded.remove(at: i) } }
            let package: TweakPackage
            do {
                package = try await TweakAnalyzer.analyze(url, into: staging, runner: runner, now: Date())
            } catch {
                Self.logger.notice("tweak not added (\(name)): \(String(describing: error))")
                flow.tweakErrors.append(Self.tweakErrorText(error, name: name))
                continue
            }
            guard install === flow, !flow.isRunning else { return }
            if flow.tweaks.contains(where: { $0.id == package.id }) { continue } // the same bytes again
            var draft = TweakDraft(package: package, directory: staging.appendingPathComponent(package.id),
                                   enabledDevices: [], force: [], verdicts: [:])
            if let i = flow.tweaks.firstIndex(where: { $0.package.packageID == package.packageID }) {
                let old = flow.tweaks[i]
                guard confirmReplace(old: old.package, new: package) else {
                    try? FileManager.default.removeItem(at: draft.directory)
                    continue
                }
                // In its place, with its switches; ❌ ones go off after the verdicts below.
                draft.enabledDevices = old.enabledDevices
                draft.force = old.force
                draft.listedDevices = old.listedDevices
                draft.seenDevices = old.seenDevices
                draft.replacing = old.stored ? old.id : old.replacing
                flow.tweaks[i] = draft
                if !old.stored { try? FileManager.default.removeItem(at: old.directory) }
                refreshTweakVerdicts(flow)
                for id in flow.tweaks[i].enabledDevices where !flow.tweaks[i].isEnabled(on: id) {
                    flow.tweaks[i].enabledDevices.remove(id)
                }
            } else {
                flow.tweaks.append(draft)
                syncTweakDevices(flow)
            }
        }
        refreshTweakVerdicts(flow)
    }

    func setTweak(_ id: String, enabled: Bool, for deviceID: String, in flow: InstallFlow) {
        guard let i = flow.tweaks.firstIndex(where: { $0.id == id }) else { return }
        if enabled { flow.tweaks[i].enabledDevices.insert(deviceID) } else { flow.tweaks[i].enabledDevices.remove(deviceID) }
        refreshTweakVerdicts(flow)
    }

    /// « Injecter quand même » on one device: turning it on also turns the tweak on there.
    func setTweakForce(_ id: String, _ on: Bool, for deviceID: String, in flow: InstallFlow) {
        guard let i = flow.tweaks.firstIndex(where: { $0.id == id }) else { return }
        if on {
            flow.tweaks[i].force.insert(deviceID)
            flow.tweaks[i].enabledDevices.insert(deviceID)
        } else {
            flow.tweaks[i].force.remove(deviceID)
            flow.tweaks[i].enabledDevices.remove(deviceID)
        }
        refreshTweakVerdicts(flow)
    }

    /// « Retirer »: gone from the app on every device of this install (the others keep theirs).
    func removeTweak(_ id: String, from flow: InstallFlow) {
        guard let i = flow.tweaks.firstIndex(where: { $0.id == id }) else { return }
        let draft = flow.tweaks.remove(at: i)
        if !draft.stored { try? FileManager.default.removeItem(at: draft.directory) }
        refreshTweakVerdicts(flow)
    }

    /// The tweaks that go in converted on any of `targets`, each once, with what changed.
    func convertedTweaks(in flow: InstallFlow, on targets: [String]) -> [(name: String, conversions: [TweakConversion])] {
        flow.tweaks.compactMap { draft in
            for id in targets where draft.isEnabled(on: id) {
                if case .converted(let list)? = draft.verdict(on: id) { return (draft.package.name, list) }
            }
            return nil
        }
    }

    /// Hands the window's tweaks to the library with `deviceID`'s list, right before its job.
    func handOverTweaks(_ flow: InstallFlow, uses: [TweakUse], deviceID: String, recordID: UUID) async throws {
        let staged = flow.tweaks.filter { !$0.stored }.map {
            StagedTweak(package: $0.package, directory: $0.directory, replacing: $0.replacing)
        }
        guard !staged.isEmpty || !uses.isEmpty || flow.existing != nil else { return }
        try await library.adoptTweaks(staged, uses: [deviceID: uses], recordID: recordID)
    }

    // MARK: Confirmations

    /// Asks before installing (or turning on) converted tweaks: one alert per tweak, with what
    /// changed. False as soon as one is cancelled.
    func confirmConvertedTweaks(_ tweaks: [(name: String, conversions: [TweakConversion])],
                                button: String = L("tweaks.confirm.install")) -> Bool {
        for tweak in tweaks {
            let alert = NSAlert()
            alert.messageText = L("tweaks.confirm.title")
            let list = tweak.conversions.map { Self.lowercasedFirst(TweakText.conversion($0)) }.joined(separator: " ; ")
            alert.informativeText = tweak.name + "\n\n" + L("tweaks.confirm.text", list)
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: L("install.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        return true
    }

    func confirmReplace(old: TweakPackage, new: TweakPackage) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("tweaks.replace.title", old.name, old.version ?? "", new.version ?? new.name)
        alert.addButton(withTitle: L("tweaks.replace.button"))
        alert.addButton(withTitle: L("install.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func lowercasedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }

    static func tweakErrorText(_ error: any Error, name: String) -> String {
        switch error as? TweakError {
        case .tooLarge: L("tweaks.error.tooLarge", name)
        case .unsupportedFile: L("tweaks.error.unsupported", name)
        case .nothingUsable: L("tweaks.error.nothingUsable", name)
        case .symlinkInFolder: L("tweaks.error.symlink", name)
        default: L("tweaks.error.unreadable", name)
        }
    }

    // MARK: Settings > Mes apps

    /// The verdict of `package` for this installation, with the other tweaks enabled there.
    func tweakVerdicts(_ package: TweakPackage, for entry: AppEntry) -> (verdict: TweakVerdict, forced: TweakVerdict) {
        let pool = entry.record.tweaks ?? []
        let enabled = Set(entry.installation.enabledTweakIDs)
        let others = pool.filter { $0.id != package.id && enabled.contains($0.id) }
        let c = TweakClassifier.classify(package, TweakResources.context(
            bundleID: entry.record.originalBundleID, executable: entry.record.executable,
            deviceOS: devices.first { $0.id == entry.installation.deviceID }?.osVersion, others: others))
        return (c.verdict, c.verdictOverridingFilter)
    }

    /// Adds files to the installation's tweaks, from its next signing: each starts on unless ❌
    /// (or, converted, unless the person cancels). Another version of one it has asks to replace it.
    func addTweaks(_ urls: [URL], for entry: AppEntry) async {
        let key = entry.id
        tweakErrors[key] = nil
        for url in urls {
            let name = url.lastPathComponent
            tweaksBeingAdded[key, default: []].append(name)
            defer {
                if let i = tweaksBeingAdded[key]?.firstIndex(of: name) { tweaksBeingAdded[key]?.remove(at: i) }
                if tweaksBeingAdded[key]?.isEmpty == true { tweaksBeingAdded[key] = nil }
            }
            do {
                let (package, replacing) = try await library.addTweak(url, recordID: key.recordID, deviceIDs: [key.deviceID],
                                                                      runner: runner, now: Date())
                if let replacing {
                    if confirmReplace(old: replacing, new: package) {
                        try await library.replaceTweak(replacing.id, with: package, recordID: key.recordID)
                    }
                    await reloadRecords()
                    continue
                }
                await reloadRecords()
                guard let current = currentEntry(key) else { continue }
                let verdict = tweakVerdicts(package, for: current).verdict
                switch verdict {
                case .incompatible:
                    await setTweak(package.id, enabled: false, for: current, asking: false)
                case .converted(let list):
                    if !confirmConvertedTweaks([(package.name, list)], button: L("tweaks.confirm.enable")) {
                        await setTweak(package.id, enabled: false, for: current, asking: false)
                    }
                case .compatible: break
                }
            } catch {
                Self.logger.notice("tweak not added (\(name)): \(String(describing: error))")
                tweakErrors[key, default: []].append(Self.tweakErrorText(error, name: name))
            }
        }
        await reloadRecords()
    }

    /// The installation as the library has it now.
    func currentEntry(_ key: JobKey) -> AppEntry? {
        guard let record = records.first(where: { $0.id == key.recordID }),
              let installation = record.installations.first(where: { $0.deviceID == key.deviceID }) else { return nil }
        return AppEntry(record: record, installation: installation)
    }

    /// One tweak's switch for this installation, from its next signing. Turning on a converted
    /// one asks first.
    func setTweak(_ id: String, enabled: Bool, for entry: AppEntry, asking: Bool = true) async {
        guard let current = currentEntry(entry.id) else { return }
        if enabled, asking, let package = current.record.tweaks?.first(where: { $0.id == id }) {
            let use = current.installation.tweaks?.first { $0.id == id }
            let v = tweakVerdicts(package, for: current)
            let applied = use?.force == true && v.verdict.canOverride ? v.forced : v.verdict
            if case .converted(let list) = applied,
               !confirmConvertedTweaks([(package.name, list)], button: L("tweaks.confirm.enable")) { return }
        }
        await changeTweaks(current) { uses in
            if let i = uses.firstIndex(where: { $0.id == id }) { uses[i].enabled = enabled }
        }
    }

    /// « Injecter quand même » for this installation: on also turns the tweak on.
    func setTweakForce(_ id: String, _ on: Bool, for entry: AppEntry) async {
        guard let current = currentEntry(entry.id) else { return }
        await changeTweaks(current) { uses in
            if let i = uses.firstIndex(where: { $0.id == id }) {
                uses[i].force = on ? true : nil
                uses[i].enabled = on
            }
        }
    }

    /// « Retirer »: off this device's list, from its next signing (the files go once no device has it).
    func removeTweak(_ id: String, for entry: AppEntry) async {
        guard let current = currentEntry(entry.id) else { return }
        await changeTweaks(current) { uses in uses.removeAll { $0.id == id } }
    }

    private func changeTweaks(_ entry: AppEntry, _ change: (inout [TweakUse]) -> Void) async {
        var uses = entry.installation.tweaks ?? []
        change(&uses)
        do {
            try await library.setTweaks(uses, recordID: entry.record.id, deviceID: entry.installation.deviceID)
        } catch {
            Self.logger.error("tweak choice failed: \(String(describing: error))")
        }
        await reloadRecords()
    }
}

/// The words of a verdict, a conversion, a problem and a signing's result.
enum TweakText {
    static func conversion(_ c: TweakConversion) -> String {
        c.argument.map { L(c.stringKey, $0) } ?? L(c.stringKey)
    }

    /// `deviceName`: the device the verdict is for (an iOS version names it).
    static func problem(_ p: TweakProblem, package: TweakPackage, deviceName: String) -> String {
        let key = p.stringKey(for: package)
        switch p {
        case .iOSVersion(let required, let device): return L(key, required, deviceName, device)
        default:
            let args = p.arguments
            let format = L(key)
            return String(format: format, locale: Locale(identifier: AppLanguage.current.resolvedCode),
                          arguments: args.map { $0 as CVarArg })
        }
    }

    static func note(_ n: TweakNote) -> String {
        switch n {
        case .settingsNotConverted: L("tweaks.note.settingsNotConverted")
        case .filesIgnored: L("tweaks.note.filesIgnored")
        case .linksSkipped: L("tweaks.note.linksSkipped")
        }
    }

    /// Where it loads: its filter's first bundle id, else « Cette app ».
    static func target(_ package: TweakPackage) -> String {
        package.targetBundleID ?? L("tweaks.target.thisApp")
    }

    /// « Pour com.example.app », « Pour cette app ».
    static func targetLine(_ package: TweakPackage) -> String {
        guard let id = package.targetBundleID else {
            let thisApp = L("tweaks.target.thisApp")
            return L("tweaks.target", (thisApp.first.map { $0.lowercased() } ?? "") + thisApp.dropFirst())
        }
        return L("tweaks.target", id)
    }

    /// What the last signing did with it (nil: nothing to say).
    static func result(_ r: TweakResult?, package: TweakPackage, enabled: Bool, signed: Bool, deviceName: String) -> String? {
        switch r {
        case .injected(let converted)?: return L(converted ? "tweaks.result.injectedConverted" : "tweaks.result.injected")
        case .skipped(.noRoom)?: return L("tweaks.skipped.noRoom")
        case .skipped(.failed)?: return L("tweaks.skipped.failed")
        case .skipped(.incompatible(let p))?:
            return L("tweaks.skipped.incompatible", problem(p, package: package, deviceName: deviceName))
        case nil:
            // A library no enabled tweak relied on: the signing left it out, and says nothing.
            return enabled && signed && package.entries.isEmpty ? L("tweaks.result.notUsed") : nil
        }
    }
}
