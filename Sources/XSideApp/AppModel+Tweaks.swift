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
    // MARK: Step ③

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
                              verdicts: [:], stored: true, listedDevices: listed, seenDevices: Set(lists.keys),
                              injectedOn: Set(record.installations.filter {
                                  if case .injected? = $0.tweakResults?[package.id] { true } else { false }
                              }.map(\.deviceID)))
        }
        refreshTweakVerdicts(flow)
    }

    /// Every device's list: its installation's, else the one waiting for its first install.
    func tweakLists(_ record: AppRecord) -> [String: [TweakUse]] {
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
        guard flow.info != nil else { return }
        let drafts = flow.tweaks
        for (i, draft) in drafts.enumerated() {
            var verdicts: [String: TweakVerdict] = [:], forced: [String: TweakVerdict] = [:]
            var missing: [String: [String]] = [:]
            for id in flow.deviceIDs {
                let context = draftContext(flow, draft.id, on: id, drafts: drafts)
                let c = TweakClassifier.classify(draft.package, context)
                verdicts[id] = c.verdict
                forced[id] = c.verdictOverridingFilter
                // A missing dependency the verdict can't judge (unknown package) is flagged on the row.
                let names = DependencyRows.missing(draft.package, context)
                if !names.isEmpty { missing[id] = names }
            }
            flow.tweaks[i].verdicts = verdicts
            flow.tweaks[i].forcedVerdicts = forced
            flow.tweaks[i].missingDependencies = missing
        }
    }

    /// Its group in step ③ (device round 2, items 3 and 6): « À régler » blocks « Suivant ».
    func draftGroup(_ draft: TweakDraft, in flow: InstallFlow) -> TweakGroups.Group {
        TweakGroups.group(flow.deviceIDs.map { id in
            TweakGroups.DeviceState(verdict: draft.verdicts[id], isOn: draft.enabledDevices.contains(id),
                                    isForced: draft.force.contains(id), signedAnyway: draft.injectedOn.contains(id),
                                    missingDependencies: draft.missingDependencies[id] ?? [])
        })
    }

    /// The window's tweaks « À régler » (dependencies nested under a tweak don't count on their own).
    func tweaksToSettle(_ flow: InstallFlow) -> [TweakDraft] {
        let nested = TweakNesting.parents(flow.tweaks.map(\.package))
        return flow.tweaks.filter { nested[$0.id] == nil && draftGroup($0, in: flow) == .toSettle }
    }

    /// « Retirer les tweaks à régler »: every one of them leaves the window, with the dependencies
    /// only they needed.
    func removeTweaksToSettle(_ flow: InstallFlow) {
        let removed = tweaksToSettle(flow)
        guard !removed.isEmpty else { return }
        let nested = TweakNesting.parents(flow.tweaks.map(\.package))
        let gone = Set(removed.map(\.id))
        for draft in removed { removeTweak(draft.id, from: flow) }
        for (dep, parent) in nested where gone.contains(parent) {
            guard let package = flow.tweaks.first(where: { $0.id == dep })?.package,
                  DependencyRows.dependents(of: package, among: flow.tweaks.map(\.package)).isEmpty else { continue }
            removeTweak(dep, from: flow)
        }
        Self.logger.notice("install window: \(removed.count) tweak(s) to settle removed")
    }

    /// What the classifier knows for `tweakID` on one device: the other tweaks enabled there and its iOS.
    func draftContext(_ flow: InstallFlow, _ tweakID: String, on deviceID: String, drafts: [TweakDraft]? = nil) -> TweakContext {
        let others = (drafts ?? flow.tweaks).filter { $0.id != tweakID && $0.enabledDevices.contains(deviceID) }.map(\.package)
        return TweakResources.context(bundleID: flow.info?.bundleID ?? "", executable: flow.info?.executable,
                                      deviceOS: devices.first { $0.id == deviceID }?.osVersion, others: others)
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
        let staging = tweakStaging(flow)
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
            // The window closed (or the install started) meanwhile: the analysis leaves nothing.
            guard install === flow, !flow.isRunning else {
                if !flow.tweaks.contains(where: { $0.id == package.id }) {
                    try? FileManager.default.removeItem(at: staging.appendingPathComponent(package.id))
                }
                if flow.tweakStaging == nil { try? FileManager.default.removeItem(at: staging) }
                return
            }
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

    /// The window's staging folder (`AppLibrary.stagingFolder`), made on first use.
    func tweakStaging(_ flow: InstallFlow) -> URL {
        if let existing = flow.tweakStaging { return existing }
        let staging = libraryRoot.appendingPathComponent(AppLibrary.stagingFolder).appendingPathComponent(UUID().uuidString)
        flow.tweakStaging = staging
        return staging
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

    /// Puts the tweaks added in the window into the app's pool, held until `releaseTweaks` with
    /// the ids returned (the device's job holds them too). The device's list itself is recorded
    /// by its job, only when the install succeeds.
    func handOverTweaks(_ flow: InstallFlow, recordID: UUID) async throws -> [String] {
        let staged = flow.tweaks.filter { !$0.stored }.map {
            StagedTweak(package: $0.package, directory: $0.directory, replacing: $0.replacing)
        }
        guard !staged.isEmpty else { return [] }
        return try await library.adoptTweaks(staged, recordID: recordID)
    }

    // MARK: Confirmations

    /// Asks before installing (or turning on) converted tweaks: one alert for all of them, with
    /// what changed in each. False when cancelled.
    func confirmConvertedTweaks(_ tweaks: [(name: String, conversions: [TweakConversion])],
                                button: String = L("tweaks.confirm.install")) -> Bool {
        guard !tweaks.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = L("tweaks.confirm.title")
        // The spec's sentence once, naming them; then, per tweak, what changed.
        let names = tweaks.map(\.name).joined(separator: ", ")
        let details = tweaks.map { t in
            "• " + t.name + " : " + t.conversions.map { Self.lowercasedFirst(TweakText.conversion($0)) }.joined(separator: " ; ")
        }
        alert.informativeText = L("tweaks.confirm.text", names) + "\n\n" + details.joined(separator: "\n")
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: L("install.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func confirmReplace(old: TweakPackage, new: TweakPackage) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("tweaks.replace.title", old.name, old.version ?? "", new.version ?? new.name)
        // The new version takes the old one's place on every device of this app that has it.
        alert.informativeText = L("tweaks.replace.text")
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
        let c = TweakClassifier.classify(package, entryContext(entry.record, package.id, on: entry.installation.deviceID))
        return (c.verdict, c.verdictOverridingFilter)
    }

    /// The package ids `package` misses on this installation (the row's flag).
    func missingDependencies(_ package: TweakPackage, for entry: AppEntry) -> [String] {
        DependencyRows.missing(package, entryContext(entry.record, package.id, on: entry.installation.deviceID))
    }

    /// One device of an app in the library: the other tweaks its list enables (its installation's,
    /// else the one waiting for its first install), and its iOS.
    func entryContext(_ record: AppRecord, _ tweakID: String, on deviceID: String) -> TweakContext {
        let enabled = Set((tweakLists(record)[deviceID] ?? []).filter(\.enabled).map(\.id))
        let others = (record.tweaks ?? []).filter { $0.id != tweakID && enabled.contains($0.id) }
        return TweakResources.context(bundleID: record.originalBundleID, executable: record.executable,
                                      deviceOS: devices.first { $0.id == deviceID }?.osVersion, others: others)
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

    /// A tweak dropped on an app row of the panel: Settings > Mes apps on that installation, with
    /// the files added (pending, for that device only; the dependencies sheet opens if needed).
    /// The caller brings Settings to the front.
    func openSettingsAddingTweaks(_ urls: [URL], entry: AppEntry) {
        settingsApp = entry.id
        settingsPane = .apps
        Task { await addTweaks(urls, for: entry) }
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
    /// The copies downloaded (or reused from the kept downloads) for it that nothing left there
    /// relies on go with it (device round 3, F3), signed with it or not.
    func removeTweak(_ id: String, for entry: AppEntry) async {
        guard let current = currentEntry(entry.id) else { return }
        let pool = current.record.tweaks ?? []
        let listed = (current.installation.tweaks ?? []).compactMap { u in pool.first { $0.id == u.id } }
        let freed = listed.first { $0.id == id }.map { removed in
            Set(DependencyRows.copiesFreedByRemoving(removed, listed: listed,
                                                     context: entryContext(current.record, id, on: current.installation.deviceID))
                .map(\.id))
        } ?? []
        if !freed.isEmpty {
            Self.logger.notice("tweak removed on \(current.installation.deviceID): \(freed.count) dependency copy(ies) no longer needed go too")
        }
        await changeTweaks(current) { uses in uses.removeAll { $0.id == id || freed.contains($0.id) } }
    }

    private func changeTweaks(_ entry: AppEntry, _ change: (inout [TweakUse]) -> Void) async {
        var uses = entry.installation.tweaks ?? []
        change(&uses)
        do {
            let changed = try await library.setTweaks(uses, recordID: entry.record.id, deviceID: entry.installation.deviceID)
            await reloadRecords()
            // What the « Changement en attente » line will say (device round 2, item 10).
            let pending = currentEntry(entry.id)?.installation.signedChoices.map { _ in
                currentEntry(entry.id)!.installation.pendingSigningChanges(wantsWithoutXSideFeatures: false).contains(.tweaks)
            }
            Self.logger.notice("tweak choice on \(entry.installation.deviceID): \(changed ? "stored" : "unchanged"), "
                               + "on \(uses.filter(\.enabled).count) of \(uses.count), pending: \(pending.map(String.init) ?? "unknown (never signed with tweaks)")")
        } catch {
            Self.logger.error("tweak choice failed: \(String(describing: error))")
            await reloadRecords()
        }
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

    static func warning(_ w: TweakWarning) -> String {
        switch w {
        case .cFunctionHooks(let names): L(w.stringKey, names.joined(separator: ", "))
        }
    }

    static func note(_ n: TweakNote) -> String {
        switch n {
        case .settingsNotConverted: L("tweaks.note.settingsNotConverted")
        case .filesIgnored: L("tweaks.note.filesIgnored")
        case .linksSkipped: L("tweaks.note.linksSkipped")
        }
    }

    /// « ajoutée par toi », « téléchargée depuis Chariz », « fournie par XSide ».
    static func origin(_ o: TweakOrigin) -> String {
        switch o {
        case .added: L("tweaks.origin.added")
        case .downloaded(let repo, _, _): L("tweaks.origin.downloaded", DependencySources.name(forRepoID: repo))
        case .embedded: L("tweaks.origin.embedded")
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

// MARK: - « Dépendances »

/// Whose dependencies the sheet shows: a tweak of the install window (step ③), or one of an
/// installation (Settings > Mes apps).
enum DependencyTarget: Hashable {
    case draft(tweakID: String)
    case entry(JobKey, tweakID: String)

    var tweakID: String {
        switch self {
        case .draft(let id), .entry(_, let id): id
        }
    }
}

extension AppModel {
    /// The tweak and one row per `Depends` group, per device it goes on: each device with the
    /// other tweaks enabled there and its iOS (one status when they all agree). The devices are
    /// those where it is on (all of the window's or the app's when it is on nowhere).
    /// Nothing here reaches the network or the disk.
    func dependencyRows(_ target: DependencyTarget) -> (package: TweakPackage, rows: [DependencyRow], deviceNames: [String: String])? {
        let package: TweakPackage, contexts: [(deviceID: String, context: TweakContext)]
        switch target {
        case .draft(let id):
            guard let flow = install, let draft = flow.tweaks.first(where: { $0.id == id }) else { return nil }
            let on = flow.deviceIDs.filter { draft.enabledDevices.contains($0) }
            package = draft.package
            contexts = (on.isEmpty ? flow.deviceIDs : on).map { ($0, draftContext(flow, id, on: $0)) }
        case .entry(let key, let id):
            guard let record = records.first(where: { $0.id == key.recordID }),
                  let p = record.tweaks?.first(where: { $0.id == id }) else { return nil }
            package = p
            contexts = dependencyDevices(record, tweakID: id, first: key.deviceID).map { ($0, entryContext(record, id, on: $0)) }
        }
        var names: [String: String] = [:]
        for (id, _) in contexts { names[id] = devices.first { $0.id == id }?.name ?? L("popover.unknownDevice") }
        return (package, DependencyRows.rows(package, contexts: contexts), names)
    }

    /// The app's devices whose list has the tweak on (`first`, the one shown, leads); just `first`
    /// when it's on nowhere.
    private func dependencyDevices(_ record: AppRecord, tweakID: String, first: String) -> [String] {
        let on = tweakDevices(record, tweakID: tweakID)
        guard !on.isEmpty else { return [first] }
        return on.contains(first) ? [first] + on.filter { $0 != first } : on
    }

    /// The devices whose list (pending included) has `tweakID` on, sorted.
    private func tweakDevices(_ record: AppRecord, tweakID: String) -> [String] {
        tweakLists(record).filter { $0.value.contains { $0.id == tweakID && $0.enabled } }.map(\.key).sorted()
    }

    /// « Ajouter son .deb… »: kept only if it is that package in a version that will do.
    func addDependencyDeb(_ urls: [URL], for dependency: DebDependency, target: DependencyTarget) async {
        guard let url = urls.first else { return }
        dependencyLineOwners[dependency.package] = target.tweakID
        await addingDependency(dependency, target: target) {
            self.dependencyProgress[dependency.package] = L("tweaks.adding", url.lastPathComponent)
            return try await self.addDependency(url, origin: .added, for: dependency, target: target)
        }
    }

    /// « Télécharger »: a kept copy that satisfies it is reused without network; otherwise the
    /// trusted repo is asked now (only after the click), the person confirms what, from where and
    /// how big, then it is downloaded, checked, kept and added on the devices that use the tweak.
    func downloadDependency(_ dependency: DebDependency, for tweak: TweakPackage, target: DependencyTarget) async {
        let repoName = DependencySources.name(for: dependency.package)
        dependencyLineOwners[dependency.package] = target.tweakID
        await addingDependency(dependency, target: target) {
            let work = self.libraryRoot.appendingPathComponent(AppLibrary.stagingFolder).appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: work) }
            let downloader = DependencyDownloader(library: self.library,
                                                  client: RepoClient(fetcher: self.repoFetcher, runner: self.runner, workDir: work))
            let source: DependencySource
            self.dependencyProgress[dependency.package] = L("deps.progress.looking", repoName)
            do {
                source = try await downloader.prepare(dependency, preferredArchitecture: tweak.architecture)
            } catch {
                throw DependencyFailure(text: Self.downloadErrorText(error, dependency: dependency, repoName: repoName))
            }
            guard self.confirmDownload(source, dependency: dependency) else { return .cancelled("download not confirmed") }
            self.dependencyProgress[dependency.package] = Self.downloadingText(source)
            let fetched: (file: URL, origin: TweakOrigin)
            do {
                fetched = try await downloader.fetch(source)
            } catch {
                throw DependencyFailure(text: Self.downloadErrorText(error, dependency: dependency, repoName: source.repoName))
            }
            return try await self.addDependency(fetched.file, origin: fetched.origin, for: dependency, target: target,
                                                fromKeptCopy: source.isCached)
        }
    }

    private struct DependencyFailure: Error { let text: String }

    /// How one add of a dependency ended: always logged, and shown under its row (green when
    /// added, orange when not; nothing when the person cancelled).
    enum DependencyOutcome {
        /// `package`: the copy it added there (nil: nothing added, e.g. « à jour »).
        case added(String, package: String? = nil)
        case problem(String)
        case cancelled(String)
    }

    /// Runs one add for a dependency's row: its spinner, then its green or orange line.
    /// `updating`: « Mettre à jour » on the dependency's own card, whose id the new copy replaces.
    private func addingDependency(_ dependency: DebDependency, target: DependencyTarget, updating: Bool = false,
                                  _ work: @escaping () async throws -> DependencyOutcome) async {
        let key = dependency.package
        guard !dependenciesBeingAdded.contains(key) else { return }
        dependencyErrors[key] = nil
        dependencyNotices[key] = nil
        dependencyNoticeSubjects[key] = nil
        dependenciesBeingAdded.insert(key)
        defer {
            dependenciesBeingAdded.remove(key)
            dependencyProgress[key] = nil
        }
        do {
            switch try await work() {
            case .added(let notice, let package):
                Self.logger.notice("dependency \(key) added: \(notice)")
                dependencyNotices[key] = notice
                let about = updating ? package ?? target.tweakID : target.tweakID
                dependencyNoticeSubjects[key] = (target, DependencyNoticeSubject(tweakID: about, packageID: package))
            case .problem(let problem):
                Self.logger.notice("dependency \(key) not added: \(problem)")
                dependencyErrors[key] = problem
            case .cancelled(let why):
                Self.logger.notice("dependency \(key) not added: \(why)")
            }
        } catch let failure as DependencyFailure {
            Self.logger.notice("dependency \(key) not added: \(failure.text)")
            dependencyErrors[key] = failure.text
        } catch {
            Self.logger.notice("dependency \(key) not added: \(String(describing: error))")
            dependencyErrors[key] = Self.tweakErrorText(error, name: key)
        }
    }

    private static func downloadErrorText(_ error: any Error, dependency: DebDependency, repoName: String) -> String {
        logger.notice("dependency \(dependency.package) not downloaded: \(String(describing: error))")
        let name = DependencyNames.display(dependency.package)
        let fromGitHub = TrustedRepos.offering(dependency.package).isEmpty && AuthorReleases.source(for: dependency.package) != nil
        switch DependencyDownloader.failure(error) {
        case .hash: return L("deps.error.hash")
        case .mismatch: return L("deps.error.mismatch", name)
        case .notFound: return fromGitHub ? L("deps.error.notFound.github", name) : L("deps.error.notFound", name)
        case .network: return L("deps.error.network", repoName)
        }
    }

    /// What, from where, how big (or that the kept copy is used), and the `.deb`'s URL.
    private func confirmDownload(_ source: DependencySource, dependency: DebDependency) -> Bool {
        let name: String
        switch source {
        case .cached: name = DependencyNames.display(dependency.package)
        case .repo(let o): name = o.name
        case .authorRelease: name = DependencyNames.display(dependency.package)
        }
        let alert = NSAlert()
        alert.messageText = L("deps.confirm.title", name, source.version)
        var text: String
        if case .authorRelease(let o) = source {
            text = L("deps.confirm.github", name + " " + source.version, fileSize(Int64(o.size)), o.source.page.absoluteString)
        } else if let size = source.size {
            text = L("deps.confirm.text", name + " " + source.version,
                     fileSize(Int64(size)),
                     source.repoName, source.repoURL?.absoluteString ?? "")
        } else {
            text = L("deps.confirm.cached")
        }
        text += "\n\n" + L("deps.confirm.file", source.debURL)
        alert.informativeText = text
        alert.addButton(withTitle: L("deps.download"))
        alert.addButton(withTitle: L("install.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Analyses `url`, checks it is `dependency` (else the orange line's text), and adds it where
    /// `DependencyPlacement` says: where the tweak that needs it is on, and where it unblocks that
    /// tweak (which is turned on there). Says what it did.
    private func addDependency(_ url: URL, origin: TweakOrigin, for dependency: DebDependency,
                               target: DependencyTarget, askReplace: Bool = true,
                               fromKeptCopy: Bool = false) async throws -> DependencyOutcome {
        switch target {
        case .draft(let tweakID):
            guard let flow = install, !flow.isRunning else { return .cancelled("the install window closed or started") }
            let staging = tweakStaging(flow)
            let package = try await TweakAnalyzer.analyze(url, into: staging, origin: origin, runner: runner, now: Date())
            let known = flow.tweaks.contains { $0.id == package.id }
            let directory = staging.appendingPathComponent(package.id)
            guard install === flow, !flow.isRunning else {
                if !known { try? FileManager.default.removeItem(at: directory) }
                return .cancelled("the install window closed or started")
            }
            if let problem = Self.mismatchText(DependencyDirectory.check(package, for: dependency)) {
                if !known { try? FileManager.default.removeItem(at: directory) }
                return .problem(problem)
            }
            guard let tweak = flow.tweaks.first(where: { $0.id == tweakID }) else { return .cancelled("the tweak was removed") }
            let plan = DependencyPlacement.plan(tweak: tweak.package, adding: package, devices: flow.deviceIDs.map {
                .init(id: $0, context: draftContext(flow, tweakID, on: $0), tweakOn: tweak.enabledDevices.contains($0))
            })
            let devices = plan.dependencyOn
            if let i = flow.tweaks.firstIndex(where: { $0.id == package.id }) {
                flow.tweaks[i].enabledDevices.formUnion(devices)
            } else if let i = flow.tweaks.firstIndex(where: { $0.package.packageID == package.packageID }) {
                let old = flow.tweaks[i]
                guard !askReplace || confirmReplace(old: old.package, new: package) else {
                    try? FileManager.default.removeItem(at: directory)
                    return .cancelled("replacement not confirmed")
                }
                var draft = TweakDraft(package: package, directory: directory, enabledDevices: old.enabledDevices.union(devices),
                                       force: old.force, verdicts: [:])
                draft.listedDevices = old.listedDevices
                draft.seenDevices = old.seenDevices.union(flow.deviceIDs)
                draft.replacing = old.stored ? old.id : old.replacing
                flow.tweaks[i] = draft
                if !old.stored { try? FileManager.default.removeItem(at: old.directory) }
            } else {
                var draft = TweakDraft(package: package, directory: directory, enabledDevices: devices, force: [], verdicts: [:])
                draft.seenDevices = Set(flow.deviceIDs)
                flow.tweaks.append(draft)
            }
            if let i = flow.tweaks.firstIndex(where: { $0.id == tweakID }) { flow.tweaks[i].enabledDevices.formUnion(plan.tweakTurnedOn) }
            refreshTweakVerdicts(flow)
            return .added(addedNotice(package, on: flow.deviceIDs.filter(devices.contains), tweak: tweak.package,
                                      turnedOn: !plan.tweakTurnedOn.isEmpty, fromKeptCopy: fromKeptCopy), package: package.id)
        case .entry(let key, let tweakID):
            // Checked from a scratch copy first: a wrong one never enters the app's pool.
            let scratch = libraryRoot.appendingPathComponent(AppLibrary.stagingFolder).appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let checked = try await TweakAnalyzer.analyze(url, into: scratch, origin: origin, runner: runner, now: Date())
            if let problem = Self.mismatchText(DependencyDirectory.check(checked, for: dependency)) { return .problem(problem) }
            guard let record = records.first(where: { $0.id == key.recordID }),
                  let tweak = record.tweaks?.first(where: { $0.id == tweakID }) else { return .cancelled("the app or tweak is gone") }
            // The devices whose list has the tweak (on, or off because it was ❌), the shown one first.
            let lists = tweakLists(record)
            var listing = lists.filter { $0.value.contains { $0.id == tweakID } }.map(\.key).sorted()
            if let i = listing.firstIndex(of: key.deviceID) { listing.insert(listing.remove(at: i), at: 0) }
            let plan = DependencyPlacement.plan(tweak: tweak, adding: checked, devices: listing.map { id in
                .init(id: id, context: entryContext(record, tweakID, on: id),
                      tweakOn: lists[id]?.contains { $0.id == tweakID && $0.enabled } == true)
            })
            let (package, replacing) = try await library.addTweak(url, origin: origin, recordID: key.recordID,
                                                                  deviceIDs: listing.filter(plan.dependencyOn.contains),
                                                                  runner: runner, now: Date())
            if let replacing {
                guard !askReplace || confirmReplace(old: replacing, new: package) else {
                    await reloadRecords()
                    return .cancelled("replacement not confirmed")
                }
                try await library.replaceTweak(replacing.id, with: package, recordID: key.recordID)
            }
            await reloadRecords()
            // The tweak it unblocks goes on there (a converted one asks first, as in Mes apps).
            var turnedOn = false
            for id in listing where plan.tweakTurnedOn.contains(id) {
                guard let current = currentEntry(JobKey(recordID: key.recordID, deviceID: id)) else { continue }
                await setTweak(tweakID, enabled: true, for: current)
                turnedOn = true
            }
            return .added(addedNotice(package, on: listing.filter(plan.dependencyOn.contains), tweak: tweak, turnedOn: turnedOn,
                                      fromKeptCopy: fromKeptCopy), package: package.id)
        }
    }

    /// « Cephei 1.17.1 ajoutée, activée sur iPhone. XSide Test Cephei y est maintenant activé. »
    /// From the kept copy: « Cephei 1.17.1 ajoutée depuis la copie gardée, activée sur iPhone. »
    private func addedNotice(_ package: TweakPackage, on deviceIDs: [String], tweak: TweakPackage, turnedOn: Bool,
                             fromKeptCopy: Bool = false) -> String {
        let name = package.name + (package.version.map { " " + $0 } ?? "")
        let names = deviceIDs.map { id in devices.first { $0.id == id }?.name ?? L("popover.unknownDevice") }
        var text = names.isEmpty ? L(fromKeptCopy ? "deps.added.kept.nowhere" : "deps.added.nowhere", name)
            : L(fromKeptCopy ? "deps.added.kept" : "deps.added", name, names.joined(separator: ", "))
        if turnedOn { text += " " + L("deps.added.tweakOn", tweak.name) }
        return text
    }

    /// « Téléchargement depuis Chariz… 208 Ko », or the kept copy.
    private static func downloadingText(_ source: DependencySource) -> String {
        guard let size = source.size else { return L("deps.progress.cached") }
        return L("deps.progress.downloading", source.repoName, fileSize(Int64(size)))
    }

    // MARK: Dependency cards

    /// The tweaks of the window (step ③) or of the app's pool (Mes apps) that `dependency` is a
    /// dependency of.
    func dependents(of dependency: TweakPackage, target: DependencyTarget) -> [TweakPackage] {
        DependencyRows.dependents(of: dependency, among: pool(target))
    }

    private func pool(_ target: DependencyTarget) -> [TweakPackage] {
        switch target {
        case .draft: install?.tweaks.map(\.package) ?? []
        case .entry(let key, _): records.first { $0.id == key.recordID }?.tweaks ?? []
        }
    }

    /// « Mettre à jour » on a dependency card: only now is the trusted repo asked. A newer version
    /// that still satisfies what needs it is confirmed, downloaded and put in its place, on the
    /// same devices; otherwise the card says it is up to date.
    func updateDependency(_ package: TweakPackage, target: DependencyTarget) async {
        let wanted = dependents(of: package, target: target).lazy.flatMap { $0.depends.joined() }
            .first { $0.package == package.packageID || package.provides.contains($0.package) }
        let dependency = wanted.map { DebDependency(package: package.packageID, relation: $0.relation, version: $0.version) }
            ?? DebDependency(package: package.packageID)
        let repoName = DependencySources.name(for: package.packageID)
        dependencyLineOwners[dependency.package] = package.id
        await addingDependency(dependency, target: target, updating: true) {
            let work = self.libraryRoot.appendingPathComponent(AppLibrary.stagingFolder).appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: work) }
            let downloader = DependencyDownloader(library: self.library,
                                                  client: RepoClient(fetcher: self.repoFetcher, runner: self.runner, workDir: work))
            self.dependencyProgress[dependency.package] = L("deps.progress.looking", repoName)
            let offer: DependencySource?
            do {
                offer = try await downloader.update(dependency, installed: package.version ?? "0",
                                                    preferredArchitecture: package.architecture)
            } catch {
                throw DependencyFailure(text: Self.downloadErrorText(error, dependency: dependency, repoName: repoName))
            }
            guard let source = offer else { return .added(L("deps.upToDate", package.name, package.version ?? "?")) }
            guard self.confirmDownload(source, dependency: dependency) else { return .cancelled("update not confirmed") }
            self.dependencyProgress[dependency.package] = Self.downloadingText(source)
            let fetched: (file: URL, origin: TweakOrigin)
            do {
                fetched = try await downloader.fetch(source)
            } catch {
                throw DependencyFailure(text: Self.downloadErrorText(error, dependency: dependency, repoName: repoName))
            }
            // Placed like the version it replaces (the card's own id as the « tweak »).
            let outcome = try await self.addDependency(fetched.file, origin: fetched.origin, for: dependency,
                                                       target: target, askReplace: false)
            if case .added(_, let added) = outcome { return .added(L("deps.updated", package.name, source.version), package: added) }
            return outcome
        }
    }

    /// « Retirer » on a dependency a tweak still uses: says which tweak becomes ❌ where, and asks.
    /// True to go on.
    func confirmRemovingDependency(_ package: TweakPackage, target: DependencyTarget) -> Bool {
        var broken: [(tweak: String, device: String)] = []
        switch target {
        case .draft:
            guard let flow = install else { return true }
            for id in flow.deviceIDs {
                guard flow.tweaks.contains(where: { $0.id == package.id && $0.enabledDevices.contains(id) }) else { continue }
                let enabled = flow.tweaks.filter { $0.isEnabled(on: id) || $0.id == package.id }.map(\.package)
                for t in DependencyRows.brokenByRemoving(package, enabled: enabled, context: draftContext(flow, package.id, on: id)) {
                    broken.append((t.name, deviceName(id)))
                }
            }
        case .entry(let key, _):
            guard let record = records.first(where: { $0.id == key.recordID }) else { return true }
            let on = Set((tweakLists(record)[key.deviceID] ?? []).filter(\.enabled).map(\.id))
            let enabled = (record.tweaks ?? []).filter { on.contains($0.id) }
            guard on.contains(package.id) else { return true }
            for t in DependencyRows.brokenByRemoving(package, enabled: enabled, context: entryContext(record, package.id, on: key.deviceID)) {
                broken.append((t.name, deviceName(key.deviceID)))
            }
        }
        guard !broken.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = L("deps.remove.title", package.name)
        alert.informativeText = broken.map { L("deps.remove.breaks", $0.tweak, $0.device) }.joined(separator: "\n")
        alert.addButton(withTitle: L("tweaks.remove"))
        alert.addButton(withTitle: L("install.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The green result lines that still hold (retest, G1): one whose tweak was removed, or whose
    /// copy left the pool (or the install window), is no longer shown.
    var liveDependencyNotices: [String: String] {
        dependencyNotices.filter { key, _ in
            guard let (target, subject) = dependencyNoticeSubjects[key] else { return true }
            let present: Set<String>
            switch target {
            case .draft:
                present = Set(install?.tweaks.map(\.id) ?? [])
            case .entry(let job, _):
                guard let record = records.first(where: { $0.id == job.recordID }) else { return false }
                let listed = Set(tweakLists(record).values.flatMap { $0.map(\.id) })
                present = Set((record.tweaks ?? []).map(\.id)).intersection(listed)
            }
            return subject.holds(present: present)
        }
    }

    func deviceName(_ id: String) -> String {
        devices.first { $0.id == id }?.name ?? L("popover.unknownDevice")
    }

    // MARK: Settings > Mes apps > « Dépendances téléchargées »

    func loadDownloadUsage() async {
        downloadUsage = await library.downloadUsage()
    }

    /// « Désinstaller… » (Settings > Tweaks, device round 3): off the chosen installations' lists
    /// from their next signing; there, the tweaks it leaves without what they need are turned off
    /// with the reason. The file goes once no installation lists it.
    func uninstallDownload(_ usage: DownloadUsage, from keys: Set<DownloadInstallation.Key>) async {
        var disabling: [DownloadInstallation.Key: Set<String>] = [:]
        for key in keys {
            guard let record = records.first(where: { $0.id == key.recordID }) else { continue }
            let list = tweakLists(record)[key.deviceID] ?? []
            let listed = Set(list.map(\.id)), on = Set(list.filter(\.enabled).map(\.id))
            let pool = record.tweaks ?? []
            let removed = pool.filter { p in
                guard listed.contains(p.id), case .downloaded(_, _, let sha) = p.origin else { return false }
                return sha.lowercased() == usage.sha256
            }
            let enabled = pool.filter { on.contains($0.id) || removed.contains($0) }
            disabling[key] = Set(DependencyRows.disabledByUninstalling(removed, enabled: enabled,
                                                                       context: entryContext(record, "", on: key.deviceID)).map(\.id))
        }
        // Its usual name (« Cephei »), else the name its package gives.
        var name = DependencyNames.display(usage.packageID)
        if name == usage.packageID, let stored = records.lazy.compactMap({ r in
            r.tweaks?.first { if case .downloaded(_, _, let s) = $0.origin { s.lowercased() == usage.sha256 } else { false } }
        }).first {
            name = stored.name
        }
        do {
            let deleted = try await library.uninstallDownload(sha256: usage.sha256, from: keys, disabling: disabling, name: name)
            Self.logger.notice("kept download \(usage.sha256) uninstalled from \(keys.count) installation(s), "
                               + "\(disabling.values.reduce(0) { $0 + $1.count }) tweak(s) turned off, file \(deleted ? "deleted" : "kept")")
        } catch {
            Self.logger.error("kept download \(usage.sha256) not uninstalled: \(String(describing: error))")
        }
        await reloadRecords()
        await loadDownloadUsage()
    }

    private static func mismatchText(_ match: DependencyMatch) -> String? {
        switch match {
        case .matches: nil
        case .wrongPackage(let found, let wanted): L("deps.wrongPackage", found, wanted)
        case .tooOld(let found, let needed): L("deps.tooOld", found, needed)
        case .tooNew(let found, let needed): L("deps.tooNew", found, needed)
        case .unsuitable(let found, let needed): L("deps.unsuitable", found, needed)
        }
    }
}

/// « 208 Ko » / « 208 KB », in the app's language.
func fileSize(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file).locale(Locale(identifier: AppLanguage.current.resolvedCode)))
}
