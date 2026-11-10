#if DEBUG
import AppKit
import SwiftUI
import XSideCore

/// Debug-only: `XSIDE_SNAPSHOTS=<folder>` renders the panel, Settings > Mes apps and Créer &
/// contribuer, the compatibility fixes in every state (`fixes-*`), the install window's step ② and
/// step ① summary with made-up apps on two devices (long names) to PNGs in that folder, in English and French, light and
/// dark, then quits; nothing of the app starts. It runs only in a copy whose bundle id ends in
/// ".snapshot", so its preferences are its own, and its library is a folder inside the output:
/// the person's XSide, preferences and apps are never read or written. To look at a layout
/// without a device (device feedback 5, G2):
///
///     cp -R build/XSide-debug.app /tmp/x/XSide-snapshot.app
///     plutil -replace CFBundleIdentifier -string io.github.xside.XSide.snapshot /tmp/x/XSide-snapshot.app/Contents/Info.plist
///     codesign --force --deep -s - /tmp/x/XSide-snapshot.app
///     XSIDE_SNAPSHOTS=/tmp/x/shots /tmp/x/XSide-snapshot.app/Contents/MacOS/XSide
enum SnapshotRenderer {
    static let folder = ProcessInfo.processInfo.environment["XSIDE_SNAPSHOTS"]

    @MainActor static func run() -> Int32 {
        guard let folder, Bundle.main.bundleIdentifier?.hasSuffix(".snapshot") == true else {
            FileHandle.standardError.write(Data("XSIDE_SNAPSHOTS runs only in a copy whose bundle id ends in .snapshot\n".utf8))
            return 1
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        UserDefaults.standard.set(true, forKey: JourneyStep.completedKey)

        SettingsView.snapshotScreenHeight = 3_200
        let model = AppModel(startsServices: false)
        let now = Date()
        let sample = Sample(now: now, library: out.appendingPathComponent("library", isDirectory: true))
        model.showSnapshot(records: sample.records, devices: sample.devices, live: sample.live, now: now)
        // Duolingo stopped at launch on the iPhone two hours ago: its row's crash box and badge.
        let crash = CrashDiagnosis(cause: .noSceneSupport, duoCompatibilityOn: true, date: now.addingTimeInterval(-2 * 3600),
                                   appVersion: "6.9.0", exceptionType: "EXC_BREAKPOINT", signal: "SIGTRAP")
        model.showSnapshotCrash(CrashFinding(diagnosis: crash, log: "", fileName: "Duolingo-snapshot.ips"), on: sample.crashed)

        for language in ["en", "fr"] {
            UserDefaults.standard.set(language, forKey: AppLanguage.storageKey)
            for dark in [false, true] {
                let scheme = dark ? "dark" : "light"
                model.settingsPane = .apps
                render(PopoverView(model: model).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("panel-\(language)-\(scheme).png"))
                // The install window's banner when the check after the install found the crash.
                render(CrashBanner(app: "Duolingo", device: "iPhone Duo de Anthony", diagnosis: crash,
                                   action: CrashAction.suggested(for: crash),
                                   onWhy: {}, onAction: { _ in })
                        .padding(20)
                        .frame(width: InstallWindow.width)
                        .background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("install-crash-\(language)-\(scheme).png"))
                // « Désactiver ce tweak »: running (with its step), done, failed.
                let tweakCrash = CrashDiagnosis(cause: .tweak, subject: "XSTestTweakCrash.dylib", date: now,
                                                exceptionType: "EXC_BREAKPOINT", signal: "SIGTRAP")
                render(VStack(spacing: 10) {
                    ForEach(Array([CrashFixState.running(.disableTweak, subject: "XSide Test Crash"),
                                   .done(.disableTweak, subject: "XSide Test Crash", opened: false),
                                   .done(.disableTweak, subject: "XSide Test Crash", opened: true),
                                   .failed(.disableTweak, subject: "XSide Test Crash",
                                           message: L("error.deviceUnavailable"))].enumerated()), id: \.offset) { i, fix in
                        CrashBanner(app: "XSide Tweak Test", device: "iPhone", diagnosis: tweakCrash, action: .disableTweak,
                                    isFixing: i == 0, fix: fix, stage: i == 0 ? .step(.signing) : nil,
                                    onWhy: {}, onAction: { _ in })
                    }
                }
                .padding(20).frame(width: InstallWindow.width).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("crash-fix-\(language)-\(scheme).png"))
                for (name, key) in sample.selections {
                    model.settingsApp = key
                    // The YouTube iPhone page on each tab (device round 3, R3-1), the others on the first.
                    for tab in name == "iphone" ? AppSettingsTab.allCases : [.module] {
                        UserDefaults.standard.set(tab.rawValue, forKey: AppSettingsTab.storageKey)
                        render(SettingsView(model: model).background(Color(nsColor: .windowBackgroundColor)),
                               dark: dark, to: out.appendingPathComponent("myapps-\(name)\(tab == .module ? "" : "-" + tab.rawValue)-\(language)-\(scheme).png"))
                    }
                }
                UserDefaults.standard.set(AppSettingsTab.module.rawValue, forKey: AppSettingsTab.storageKey)
                // The pending bar's states (R3-2): pending, running (its step), done, failed.
                if let youtube = model.records.first, let phone = youtube.installations.first(where: { $0.deviceID == sample.deviceIDs[0] }) {
                    let entry = AppEntry(record: youtube, installation: phone)
                    func bar() -> some View {
                        PendingChangesBar(model: model, entry: entry, appName: "YouTube", deviceName: "iPhone Duo de Anthony")
                    }
                    render(bar().padding(20).frame(width: 600).background(Color(nsColor: .windowBackgroundColor)),
                           dark: dark, to: out.appendingPathComponent("pending-bar-\(language)-\(scheme).png"))
                    model.showSnapshotJob(entry.id, stage: .step(.signing))
                    render(bar().padding(20).frame(width: 600).background(Color(nsColor: .windowBackgroundColor)),
                           dark: dark, to: out.appendingPathComponent("pending-bar-running-\(language)-\(scheme).png"))
                    model.showSnapshotJob(entry.id, stage: nil)
                    model.refreshResults[entry.id] = .done(now)
                    render(bar().padding(20).frame(width: 600).background(Color(nsColor: .windowBackgroundColor)),
                           dark: dark, to: out.appendingPathComponent("pending-bar-done-\(language)-\(scheme).png"))
                    model.refreshResults[entry.id] = .failed(L("popover.unreachableHint"))
                    render(bar().padding(20).frame(width: 600).background(Color(nsColor: .windowBackgroundColor)),
                           dark: dark, to: out.appendingPathComponent("pending-bar-failed-\(language)-\(scheme).png"))
                    model.refreshResults[entry.id] = nil
                    // Its refreshes stopped: said, with « Reprendre » (mega review U2).
                    var paused = sample.records
                    if let r = paused.firstIndex(where: { $0.id == youtube.id }),
                       let i = paused[r].installations.firstIndex(where: { $0.deviceID == phone.deviceID }) {
                        paused[r].installations[i].refreshPaused = true
                    }
                    model.showSnapshot(records: paused, devices: sample.devices, live: sample.live, now: now)
                    render(bar().padding(20).frame(width: 600).background(Color(nsColor: .windowBackgroundColor)),
                           dark: dark, to: out.appendingPathComponent("pending-bar-paused-\(language)-\(scheme).png"))
                    model.showSnapshot(records: sample.records, devices: sample.devices, live: sample.live, now: now)
                }
                render(LicencesView(onClose: {}).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("licences-\(language)-\(scheme).png"))
                model.settingsPane = .build
                render(SettingsView(model: model).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("build-\(language)-\(scheme).png"))
                // Every state of the compatibility fixes, as step ② shows them.
                render(fixStates.padding(20).frame(width: InstallWindow.width).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("fixes-\(language)-\(scheme).png"))
                // The install window's step ② and step ① summary for an app without scenes, both devices.
                let flow = sample.flow()
                render(VStack(alignment: .leading, spacing: 14) {
                    InstallOptionsSection(model: model, flow: flow)
                    CompatibilityFixesSection {
                        DuoOptionsCard(model: model, flow: flow)
                        ICloudOptionsCard(model: model, flow: flow)
                        CompatibilityFixCard { Legacy32InfoRow(appName: flow.appDisplayName, applied: flow.info?.hasLegacy32) }
                    }
                }
                .padding(20).frame(width: InstallWindow.width).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("install-step2-\(language)-\(scheme).png"))
                render(InstallSummaryView(model: model, flow: flow)
                        .padding(20).frame(width: InstallWindow.width).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("install-summary-\(language)-\(scheme).png"))
                // The summary with a tweak « À régler »: the footer says why Install waits (mega review U5).
                let summary = sample.flow()
                summary.reviewsSteps = false
                summary.phase = .editing(error: nil)
                model.showSnapshotFlow(summary)
                render(InstallSheet(model: model, flow: summary, close: {})
                    .frame(width: InstallWindow.width).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("install-summary-blocked-\(language)-\(scheme).png"))
                // Step ③ as the approved mockup (A): two devices, then one; empty (B); the kept
                // downloads (C).
                // « -shared »: AltList's download failed; its line is on Rocket's card, uYouPlus says « voir … ».
                for (suffix, ids) in [("", sample.deviceIDs), ("-single", [sample.deviceIDs[0]]), ("-shared", sample.deviceIDs)] {
                    let step = sample.flow()
                    step.deviceIDs = ids
                    step.step = 2
                    model.showSnapshotFlow(step)
                    if suffix == "-shared" {
                        model.dependencyErrors = [DependencyLineKey(scope: .window, package: "com.opa334.altlist"): L("deps.error.notFound.github", "AltList")]
                    }
                    // The whole window: the footer says why « Suivant » waits (device round 2, items 3 and 6).
                    step.phase = .editing(error: nil)
                    render(InstallSheet(model: model, flow: step, close: {})
                        .frame(width: InstallWindow.width).background(Color(nsColor: .windowBackgroundColor)),
                           dark: dark, to: out.appendingPathComponent("tweaks\(suffix)-\(language)-\(scheme).png"))
                }
                let empty = sample.flow()
                empty.tweaks = []
                empty.tweakErrors = []
                empty.step = 2
                model.showSnapshotFlow(empty)
                render(VStack(alignment: .leading, spacing: 14) {
                    StepBar(flow: empty)
                    InstallTweaksSection(model: model, flow: empty)
                }
                .padding(20).frame(width: InstallWindow.width).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("tweaks-empty-\(language)-\(scheme).png"))
                model.showSnapshotFlow(nil)
                render(DownloadedDependenciesTable(usage: sample.downloads, deviceName: { id in
                    DeviceShortName.short(sample.devices.first { $0.id == id }?.name ?? id)
                }, uninstall: { _ in }, done: {})
                    .background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("downloads-\(language)-\(scheme).png"))
                // « Désinstaller Cephei 1.17.1 ? »: everything checked, then the iPad only, then
                // one app of the iPhone (device round 3, R3-3).
                let cephei = sample.downloads[0]
                let iPadOnly = Set(cephei.installations.filter { $0.deviceID == sample.deviceIDs[1] }.map(\.key))
                let oneApp = Set(cephei.installations.filter { $0.deviceID == sample.deviceIDs[0] }.prefix(1).map(\.key))
                for (suffix, checked) in [("all", nil), ("ipad", iPadOnly), ("oneapp", oneApp)] as [(String, Set<DownloadInstallation.Key>?)] {
                    render(UninstallDependencySheet(usage: cephei, device: { id in
                        let d = sample.devices.first { $0.id == id }
                        return (d?.name ?? id, d?.kind == .iPad)
                    }, checked: checked, confirm: { _ in }, cancel: {})
                        .background(Color(nsColor: .windowBackgroundColor)),
                           dark: dark, to: out.appendingPathComponent("uninstall-\(suffix)-\(language)-\(scheme).png"))
                }
                // Settings > Tweaks: every app's downloads, on their own page (device round 2, item 8).
                model.downloadUsage = sample.downloads
                model.settingsPane = .tweaks
                render(SettingsView(model: model).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("settings-tweaks-\(language)-\(scheme).png"))
                model.settingsPane = .apps
                // The menu-bar icon: plain, then with its red dot (device round 2, item 13).
                if let glyph = MenuBarLabel.glyph {
                    render(HStack(spacing: 24) {
                        Image(nsImage: glyph).resizable().frame(width: 72, height: 72)
                        Image(nsImage: MenuBarLabel.badged(glyph)).resizable().frame(width: 72, height: 72)
                        Text(model.attentionDescription).font(.system(size: 12)).frame(width: 260, alignment: .leading)
                    }
                    .padding(20).background(Color(nsColor: .windowBackgroundColor)),
                           dark: dark, to: out.appendingPathComponent("menubar-badge-\(language)-\(scheme).png"))
                }
                // The panel's hover bubbles where they land (device round 2, items 11 and 14).
                render(bubbles.background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("panel-bubbles-\(language)-\(scheme).png"))
                // One device, no tweak: « Aucun ».
                let single = sample.flow()
                single.deviceIDs = [sample.deviceIDs[1]]
                single.tweaks = []
                render(InstallSummaryView(model: model, flow: single)
                        .padding(20).frame(width: InstallWindow.width).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("install-summary-single-\(language)-\(scheme).png"))
                model.settingsPane = .apps
            }
        }
        print("snapshots written to \(out.path)")
        return 0
    }

    /// The panel's tiles as outlines and each one's bubble where `PanelBubble` puts it: « Tout
    /// rafraîchir » below its tile, the footer's above theirs, all inside the 340 pt panel.
    @MainActor private static var bubbles: some View {
        let tiles: [(String, CGRect, HorizontalAlignment, Bool)] = [
            (L("popover.tile.refreshAll.help", 3), CGRect(x: 96, y: 12, width: 76, height: 54), .trailing, true),
            (L("popover.settings"), CGRect(x: 12, y: 150, width: 32, height: 28), .leading, false),
            (L("whatsNew.window"), CGRect(x: 50, y: 150, width: 32, height: 28), .center, false),
            (L("settings.github"), CGRect(x: 88, y: 150, width: 32, height: 28), .center, false),
            (L("popover.reportBug"), CGRect(x: 126, y: 150, width: 32, height: 28), .center, false),
            (L("popover.about"), CGRect(x: 164, y: 150, width: 32, height: 28), .center, false),
            (L("popover.quit"), CGRect(x: 296, y: 150, width: 32, height: 28), .trailing, false),
        ]
        return VStack(spacing: 12) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                let (text, rect, alignment, below) = tile
                ZStack(alignment: .topLeading) {
                    Rectangle().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: PanelBubble.panelWidth, height: 110)
                    RoundedRectangle(cornerRadius: 8).fill(Theme.violet.opacity(0.25))
                        .frame(width: rect.width, height: 28)
                        .offset(x: rect.minX, y: below ? 10 : 70)
                    PanelBubble.label(text)
                        .fixedSize()
                        .alignmentGuide(.leading) { d in
                            let desired: CGFloat = alignment == .leading ? rect.minX
                                : alignment == .trailing ? rect.maxX - d.width : rect.midX - d.width / 2
                            return -(desired + PanelBubble.shift(text, anchor: rect, alignment: alignment))
                        }
                        .offset(y: below ? 44 : 30)
                }
                .frame(width: PanelBubble.panelWidth, height: 110, alignment: .topLeading)
                .clipped()
            }
        }
        .padding(20)
    }

    /// The Duo option: recommended (own scene delegate), not a Duo, already compatible, recommended
    /// with the compatibility module, not available (a build without that module); then iCloud:
    /// recommended, useful, not needed; then the 32-bit removal: applied, not applied, not known.
    @MainActor private static var fixStates: some View {
        let off = Binding.constant(false)
        return CompatibilityFixesSection {
            CompatibilityFixCard {
                DuoOptionRow(state: .recommended, appName: "YouTube", deviceName: "recommended", isOn: off)
                Divider().padding(.leading, 48)
                DuoOptionRow(state: .notADuo, appName: "YouTube", deviceName: "notADuo", isOn: off)
                Divider().padding(.leading, 48)
                DuoOptionRow(state: .alreadySupported, appName: "YouTube", deviceName: "alreadySupported", isOn: off)
                Divider().padding(.leading, 48)
                DuoOptionRow(state: .recommended, appName: "Instagram", deviceName: "legacy module", isOn: .constant(true),
                             needsModule: true)
                Divider().padding(.leading, 48)
                DuoOptionRow(state: .unavailable, appName: "Instagram", deviceName: "unavailable (no module in this build)",
                             isOn: off, needsModule: true)
            }
            CompatibilityFixCard {
                ICloudOptionRow(state: .recommended, appName: "Notes+", deviceName: "recommended", isOn: off)
                Divider().padding(.leading, 48)
                ICloudOptionRow(state: .useful, appName: "YouTube", deviceName: "useful", isOn: off)
                Divider().padding(.leading, 48)
                ICloudOptionRow(state: .notNeeded, appName: "Duolingo", deviceName: "notNeeded", isOn: off)
            }
            CompatibilityFixCard {
                Legacy32InfoRow(appName: "Instagram", applied: true)
                Divider().padding(.leading, 48)
                Legacy32InfoRow(appName: "YouTube", applied: false)
                Divider().padding(.leading, 48)
                Legacy32InfoRow(appName: "Duolingo", applied: nil)
            }
        }
    }

    /// Lays the view out in an off-screen window at its own size, lets SwiftUI settle (pages report
    /// their height a turn later), and saves what it draws.
    @MainActor private static func render(_ view: some View, dark: Bool, to url: URL) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, dark ? .dark : .light)))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }

    /// Two devices with long names; one app on the iPad, three on the iPhone (one paused, one
    /// open there now), YouTube on both.
    private struct Sample {
        let devices: [Device]
        let records: [AppRecord]
        let live: Set<JobKey>
        let selections: [(String, JobKey)]
        /// The installation shown as stopped at launch.
        let crashed: JobKey
        /// The app without scene support, for the install window's renders.
        let legacyApp: AppRecord
        let deviceIDs: [String]

        /// Cephei used by three tweaks in two apps, AltList by none.
        var downloads: [DownloadUsage] {
            let (iPhone, iPad) = (deviceIDs[0], deviceIDs[1])
            return [
                DownloadUsage(sha256: String(repeating: "c", count: 64), packageID: "ws.hbang.common", version: "1.17.1",
                              repo: "chariz", repoName: "Chariz", size: 208_096, downloadedAt: Date(timeIntervalSince1970: 1_800_000_000),
                              apps: ["Tweak Test", "YouTube"],
                              users: [DownloadUser(app: "Tweak Test", tweaks: [.init(name: "XSide Test Cephei", deviceIDs: [iPhone])]),
                                      DownloadUser(app: "YouTube", tweaks: [.init(name: "uYouPlus", deviceIDs: [iPhone, iPad]),
                                                                            .init(name: "YouPiP", deviceIDs: [iPhone])])],
                              installations: [
                                  DownloadInstallation(recordID: records[0].id, app: "YouTube", deviceID: iPad, tweaks: ["uYouPlus"]),
                                  DownloadInstallation(recordID: records[1].id, app: "Instagram", deviceID: iPhone, tweaks: ["Rocket"]),
                                  DownloadInstallation(recordID: records[0].id, app: "YouTube", deviceID: iPhone,
                                                       tweaks: ["uYouPlus", "YouPiP"]),
                              ]),
                DownloadUsage(sha256: String(repeating: "a", count: 64), packageID: "com.opa334.altlist", version: "1.0.4",
                              repo: "github:opa334/AltList", repoName: "GitHub opa334/AltList", size: 61_440, downloadedAt: Date(timeIntervalSince1970: 1_800_000_000),
                              apps: []),
                DownloadUsage(sha256: String(repeating: "b", count: 64), packageID: "com.hbang.alderis", version: "1.2.1",
                              repo: "chariz", repoName: "Chariz", size: 96_000, downloadedAt: Date(timeIntervalSince1970: 1_800_000_000),
                              apps: ["YouTube"], users: [DownloadUser(app: "YouTube", tweaks: [.init(name: "Return YouTube Dislike",
                                                                                                   deviceIDs: [iPhone])])],
                              installations: [DownloadInstallation(recordID: records[0].id, app: "YouTube", deviceID: iPhone,
                                                                   tweaks: ["Return YouTube Dislike"])]),
            ]
        }

        /// An install of `legacyApp` on both devices, Duo compatibility on for the iPhone.
        @MainActor func flow() -> InstallFlow {
            let flow = InstallFlow(ipa: URL(fileURLWithPath: "/tmp/Instagram.ipa"))
            flow.info = AppInfo(bundleID: legacyApp.originalBundleID, name: legacyApp.displayName, version: "412.0",
                                executable: "Instagram", sdkVersion: "26.0", duo: legacyApp.duo, icloud: legacyApp.icloud,
                                hasLegacy32: true)
            flow.deviceIDs = deviceIDs
            flow.duoDevices = [deviceIDs[0]]
            let (iPhone, iPad) = (deviceIDs[0], deviceIDs[1])
            let both = Set(deviceIDs)
            func draft(_ p: TweakPackage, on: Set<String>, _ verdicts: [String: TweakVerdict],
                       forced: [String: TweakVerdict] = [:], force: Set<String> = []) -> TweakDraft {
                TweakDraft(package: p, directory: URL(fileURLWithPath: "/tmp/\(p.id)"), enabledDevices: on, force: force,
                           verdicts: verdicts, forcedVerdicts: forced, seenDevices: both)
            }
            let converted = TweakVerdict.converted([.hookingLibrary, .jailbreakPaths, .dependencyAdded("Cephei 2.0")])
            let altlistNeed = DebDependency(package: "com.opa334.altlist", relation: ">=", version: "1.0")
            let app = legacyApp.originalBundleID
            flow.tweaks = [
                draft(Self.tweak(1, "YouPiP", version: "1.8.6", author: "PoomSmart", bundles: [app]),
                      on: both, [iPhone: .compatible, iPad: .compatible]),
                draft(Self.tweak(2, "uYouPlus", version: "3.0.5", author: "MiRO92", bundles: [app], notes: [.settingsNotConverted],
                                 depends: [[altlistNeed]], cFunctionHooks: ["MSHookFunction"]),
                      on: [iPhone], [iPhone: converted, iPad: converted]),
                draft(Self.tweak(3, "AltList", version: "1.0.4", author: "opa334", bundles: nil, entry: false,
                                 packageID: "com.opa334.altlist",
                                 origin: .downloaded(repo: "github:opa334/AltList",
                                                     url: "https://github.com/opa334/AltList/releases/download/v1.0.4/com.opa334.altlist_1.0.4_iphoneos-arm64.deb",
                                                     sha256: String(repeating: "a", count: 64))),
                      on: [iPhone], [iPhone: .compatible, iPad: .compatible]),
                draft(Self.tweak(4, "Rocket for Instagram", version: "2.4", author: "Rocket", bundles: [app],
                                 depends: [[DebDependency(package: "ws.hbang.common", relation: ">=", version: "1.11")],
                                           [DebDependency(package: "libroot")], [altlistNeed]]),
                      on: both, [iPhone: .compatible, iPad: .compatible]),
                draft(Self.tweak(5, "ReelsBlock", version: "1.0", author: "Nora", bundles: ["com.burbn.instagram"]),
                      on: [], [iPhone: .incompatible(.madeForAnotherApp(["com.burbn.instagram"])),
                               iPad: .incompatible(.madeForAnotherApp(["com.burbn.instagram"]))],
                      forced: [iPhone: .compatible, iPad: .compatible]),
                draft(Self.tweak(6, "Spotlight Shortcuts", version: "2.0", author: nil, bundles: ["com.apple.springboard"]),
                      on: [], [iPhone: .incompatible(.needsJailbreak("com.apple.springboard")),
                               iPad: .incompatible(.needsJailbreak("com.apple.springboard"))]),
            ]
            flow.tweaks[3].missingDependencies = [iPad: ["com.opa334.altlist"]] // AltList is on the iPhone only
            flow.tweakErrors = [L("tweaks.error.unreadable", "Broken-Tweak.deb")]
            return flow
        }

        /// A made-up tweak: one entry (or, `entry: false`, a library) for `bundles` (nil: a
        /// dropped .dylib, made for this app).
        static func tweak(_ n: Int, _ name: String, version: String, author: String?, bundles: [String]?,
                          notes: [TweakNote] = [], entry: Bool = true, depends: [[DebDependency]] = [],
                          packageID: String? = nil, origin: TweakOrigin = .added, cFunctionHooks: [String] = []) -> TweakPackage {
            let file = (entry ? "Library/MobileSubstrate/DynamicLibraries/" : "usr/lib/") + name.replacingOccurrences(of: " ", with: "") + ".dylib"
            let binary = TweakBinary(path: file, isEntry: entry, filter: bundles.map { TweakFilter(bundles: $0) },
                                     slices: [TweakSlice(arch: "arm64", platform: 2, minOS: "15.0")],
                                     linked: ["/usr/lib/libobjc.A.dylib"], mentionsJailbreakPaths: false,
                                     imageName: (file as NSString).lastPathComponent, cFunctionHooks: cFunctionHooks)
            return TweakPackage(id: String(format: "5a5a%012lx", n), kind: .deb, origin: origin,
                                packageID: packageID ?? "com.example.tweak\(n)", name: name, version: version, author: author,
                                depends: depends, files: [file], binaries: [binary], notes: notes,
                                addedAt: Date(timeIntervalSince1970: 1_800_000_000))
        }

        init(now: Date, library: URL) {
            let iPad = Device(id: "snapshot-ipad", udid: nil, name: "Anthony's iPad Air 5", model: "iPad Air (5th generation)",
                              kind: .iPad, transport: .network, isPaired: true, isAvailable: true, developerModeEnabled: true,
                              osVersion: "17.5")
            let iPhone = Device(id: "snapshot-iphone", udid: nil, name: "iPhone Duo de Anthony", model: "iPhone",
                                kind: .iPhone, transport: .usb, isPaired: true, isAvailable: true, developerModeEnabled: true,
                                productType: "iPhone19,4")
            devices = [iPad, iPhone]
            func installation(_ device: Device, days: Double, version: String, paused: Bool = false,
                              checkIn: TimeInterval? = nil) -> Installation {
                Installation(deviceID: device.id, installedAt: now.addingTimeInterval(-(7 - days) * 86_400),
                             expiresAt: now.addingTimeInterval(days * 86_400), refreshPaused: paused,
                             appVersion: version,
                             inApp: InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-86_400))
                                 .setting(\.autoRefresh, to: !paused, at: now.addingTimeInterval(-3600), by: .mac),
                             pausedBy: paused ? .mac : nil, channelSecret: Data(repeating: 7, count: 32),
                             lastCheckIn: checkIn.map { now.addingTimeInterval(-$0) })
            }
            func record(_ n: Int, _ name: String, _ installations: [Installation]) -> AppRecord {
                AppRecord(id: UUID(uuidString: String(format: "5A5A5A5A-0000-0000-0000-%012d", n))!, displayName: name,
                          originalBundleID: "com.example.app\(n)", signedBundleID: "com.example.app\(n)", ipaPath: "",
                          options: InstallOptions(), installations: installations, teamID: "")
            }
            var video = record(1, "YouTube", [installation(iPad, days: 5.2, version: "20.45.3", checkIn: 3 * 3600),
                                              installation(iPhone, days: 3.6, version: "20.45.3", checkIn: 4)])
            video.duo = DuoAppInfo(sdkVersion: "26.4", adoptsScenes: false, sceneDelegateClass: "YTSceneDelegate")
            video.icloud = ICloudAppInfo(declaresICloud: false, linksCloudKit: true)
            video.legacy32 = false
            // The iPhone's copy was signed with the module and without Duo or iCloud; the choices since:
            // the module off for the app, Duo and signed-out iCloud on. All three wait for a refresh.
            video.options.withoutXSideFeatures = true
            video.installations[1].duoCompatibility = true
            video.installations[1].iCloudSignedOut = true
            video.installations[1].signedChoices = SigningChoices(withoutXSideFeatures: false, duoCompatibility: false,
                                                                  iCloudSignedOut: false)
            // The iPhone's tweaks (Settings > Mes apps): one in the app, one forced that had no room,
            // a library no enabled tweak used, and one added since (pending).
            let ok = Self.tweak(11, "Return YouTube Dislike", version: "1.11", author: "Lillie", bundles: [video.originalBundleID])
            let other = Self.tweak(12, "Shorts Remover", version: "2.0", author: nil, bundles: ["com.google.ios.youtube"])
            let lib = Self.tweak(13, "Alderis", version: "1.2", author: "hbang", bundles: nil, entry: false)
            let added = Self.tweak(14, "YouPiP", version: "1.8", author: "PoomSmart", bundles: [video.originalBundleID])
            // « À régler »: AltList missing; « Pas compatibles »: SpringBoard only.
            let needs = Self.tweak(15, "YTLite", version: "5.0", author: "dayanch96", bundles: [video.originalBundleID],
                                   depends: [[DebDependency(package: "com.opa334.altlist", relation: ">=", version: "1.0")]])
            let springboard = Self.tweak(16, "Spotlight Shortcuts", version: "2.0", author: nil, bundles: ["com.apple.springboard"])
            // Off because AltList was uninstalled from here (device round 3): « Prêts », with its note.
            let reborn = Self.tweak(17, "YouTube Reborn", version: "4.2", author: "LillieH", bundles: [video.originalBundleID],
                                    depends: [[DebDependency(package: "com.opa334.altlist")]])
            video.tweaks = [ok, other, lib, added, needs, springboard, reborn]
            video.installations[1].tweaks = [TweakUse(id: ok.id), TweakUse(id: other.id, force: true), TweakUse(id: lib.id),
                                             TweakUse(id: added.id), TweakUse(id: needs.id), TweakUse(id: springboard.id, enabled: false),
                                             TweakUse(id: reborn.id, enabled: false, removedDependency: "AltList")]
            video.installations[1].signedChoices?.tweaks = [ok.id, other.id, lib.id]
            video.installations[1].signedChoices?.forcedTweaks = [other.id]
            video.installations[1].tweakResults = [ok.id: .injected(converted: false), other.id: .skipped(.noRoom)]
            video.installations[0].withoutXSideFeatures = true // the iPad: already signed that way, nothing pending
            video.installations[0].signedChoices = SigningChoices(withoutXSideFeatures: true, duoCompatibility: false,
                                                                  iCloudSignedOut: false)
            // No scene support of its own: the Duo option brings the compatibility module.
            var photos = record(2, "Instagram", [installation(iPhone, days: 1.3, version: "412.0", paused: true)])
            photos.duo = DuoAppInfo(sdkVersion: "26.0", adoptsScenes: false, sceneDelegateClass: nil)
            photos.icloud = ICloudAppInfo(declaresICloud: true, containers: ["iCloud.com.example.app2"])
            photos.legacy32 = true
            var lessons = record(3, "Duolingo: Language Lessons", [installation(iPhone, days: 6.1, version: "6.9.0",
                                                                               checkIn: 2 * 86_400)])
            // The long-named app has two tweaks in it, one converted: the panel row's caption and badge.
            lessons.installations[0].tweakResults = ["a": .injected(converted: false), "b": .injected(converted: true)]
            records = [video, photos, lessons]
            live = [JobKey(recordID: video.id, deviceID: iPhone.id)]
            crashed = JobKey(recordID: lessons.id, deviceID: iPhone.id)
            legacyApp = photos
            deviceIDs = [iPhone.id, iPad.id]
            selections = [("iphone", JobKey(recordID: video.id, deviceID: iPhone.id)),
                          ("ipad", JobKey(recordID: video.id, deviceID: iPad.id)),
                          ("paused", JobKey(recordID: photos.id, deviceID: iPhone.id))]
            // Icons where the library keeps them: white symbols on colored squares.
            let icons = library.appendingPathComponent("icons", isDirectory: true)
            try? FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
            for (r, symbol, color) in [(video, "play.fill", NSColor.systemRed), (photos, "camera.fill", NSColor.systemPink),
                                       (lessons, "bubble.left.and.text.bubble.right.fill", NSColor.systemGreen)] {
                let image = NSImage(size: NSSize(width: 120, height: 120), flipped: false) { rect in
                    color.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 27, yRadius: 27).fill()
                    let config = NSImage.SymbolConfiguration(pointSize: 54, weight: .semibold)
                        .applying(.init(paletteColors: [.white]))
                    if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                        let s = glyph.size
                        glyph.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2,
                                              width: s.width, height: s.height))
                    }
                    return true
                }
                if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: icons.appendingPathComponent("\(r.id.uuidString).png"))
                }
            }
        }
    }
}
#endif
