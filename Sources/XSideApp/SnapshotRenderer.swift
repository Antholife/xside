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
                for (name, key) in sample.selections {
                    model.settingsApp = key
                    render(SettingsView(model: model).background(Color(nsColor: .windowBackgroundColor)),
                           dark: dark, to: out.appendingPathComponent("myapps-\(name)-\(language)-\(scheme).png"))
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
                    InstallTweaksSection(model: model, flow: flow)
                }
                .padding(20).frame(width: InstallWindow.width).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("install-step2-\(language)-\(scheme).png"))
                render(InstallSummaryView(model: model, flow: flow)
                        .padding(20).frame(width: InstallWindow.width).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("install-summary-\(language)-\(scheme).png"))
                // The tweaks on two devices: ✅ on both; 🔧 with every change and a note; ❌ needs a
                // jailbreak; ✅ on one and ❌ iOS on the other; made for another app, forced on one.
                render(InstallTweaksSection(model: model, flow: flow)
                        .padding(20).frame(width: InstallWindow.width).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("tweaks-\(language)-\(scheme).png"))
                // « Dépendances »: every status, then missing ones with each kind of action (a known
                // page and a trusted repo with the last add's error, a known page only, two searches
                // while a .deb is checked, an id too odd to search for).
                let names = Dictionary(uniqueKeysWithValues: sample.devices.map { ($0.id, $0.name) })
                render(Self.dependencies([sample.deviceIDs[0], sample.deviceIDs[1]], names: names)
                        .background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("deps-\(language)-\(scheme).png"))
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

    /// The iPhone has Alderis and the iPad doesn't: per-device lines for it.
    @MainActor private static func dependencies(_ deviceIDs: [String], names: [String: String]) -> some View {
        func row(_ i: Int, _ id: String, _ relation: String? = nil, _ version: String? = nil,
                 is status: (DebDependency) -> DependencyStatus, added: String? = nil) -> DependencyRow {
            let dep = DebDependency(package: id, relation: relation, version: version)
            return DependencyRow(id: i, statuses: [DependencyDeviceStatus(deviceID: nil, dependency: dep, status: status(dep),
                                                                          addedVersion: added)])
        }
        let alderis = DebDependency(package: "com.hbang.alderis", relation: ">=", version: "1.1")
        let rows = [
            row(0, "ws.hbang.common", ">=", "1.16", is: { _ in .providedByXSide("Cephei") }),
            DependencyRow(id: 1, statuses: [
                DependencyDeviceStatus(deviceID: deviceIDs[0], dependency: alderis, status: .addedByYou("Alderis"), addedVersion: "1.2.1"),
                DependencyDeviceStatus(deviceID: deviceIDs[1], dependency: alderis, status: .missing(alderis), addedVersion: nil),
            ]),
            row(2, "libroot", is: { _ in .builtIntoTweak("libroot") }),
            row(3, "mobilesubstrate", is: { _ in .notNeeded }),
            row(4, "com.rpetrich.rocketbootstrap", is: { _ in .jailbreakOnly("RocketBootstrap") }),
            row(5, "com.opa334.altlist", ">=", "1.0", is: { .missing($0) }),
            row(6, "com.mrgcgamer.libgcuniversal", is: { .missing($0) }),
            row(7, "com.example.libfancy", ">>", "2.0", is: { .missing($0) }),
            row(8, "lib_odd name", is: { .missing($0) }),
        ]
        return TweakDependenciesView(tweakName: "InstaPlus Reborn", rows: rows, deviceNames: names,
                                     errors: ["com.opa334.altlist": L("deps.tooNew", "2.1", "< 2.0")],
                                     beingAdded: ["com.example.libfancy"], maxListHeight: .infinity,
                                     open: { _ in }, addDeb: { _, _ in }, download: { _ in }, done: {})
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
            let converted = TweakVerdict.converted([.hookingLibrary, .jailbreakPaths, .dependency("Alderis"),
                                                    .dependencyAdded("Cephei")])
            flow.tweaks = [
                draft(Self.tweak(1, "Dark Mode Pro", version: "1.4", author: "Lumen", bundles: [legacyApp.originalBundleID]),
                      on: both, [iPhone: .compatible, iPad: .compatible]),
                draft(Self.tweak(2, "InstaPlus Reborn", version: "3.2.1", author: "Alex Rivera", bundles: [legacyApp.originalBundleID],
                                 notes: [.settingsNotConverted]),
                      on: both, [iPhone: converted, iPad: converted]),
                draft(Self.tweak(3, "Spotlight Shortcuts", version: "2.0", author: nil, bundles: ["com.apple.springboard"]),
                      on: [], [iPhone: .incompatible(.needsJailbreak("com.apple.springboard")),
                               iPad: .incompatible(.needsJailbreak("com.apple.springboard"))]),
                draft(Self.tweak(4, "Swipe Speed", version: "0.9", author: "kb", bundles: nil),
                      on: [iPhone], [iPhone: .compatible, iPad: .incompatible(.iOSVersion(required: "≥ 18.0", device: "17.5"))]),
                draft(Self.tweak(5, "ReelsBlock", version: "1.0", author: "Nora", bundles: ["com.burbn.instagram"]),
                      on: [iPhone], [iPhone: .incompatible(.madeForAnotherApp(["com.burbn.instagram"])),
                                     iPad: .incompatible(.madeForAnotherApp(["com.burbn.instagram"]))],
                      forced: [iPhone: .compatible, iPad: .compatible], force: [iPhone]),
            ]
            flow.tweakErrors = [L("tweaks.error.unreadable", "Broken-Tweak.deb")]
            return flow
        }

        /// A made-up tweak: one entry (or, `entry: false`, a library) for `bundles` (nil: a
        /// dropped .dylib, made for this app).
        static func tweak(_ n: Int, _ name: String, version: String, author: String?, bundles: [String]?,
                          notes: [TweakNote] = [], entry: Bool = true) -> TweakPackage {
            let file = (entry ? "Library/MobileSubstrate/DynamicLibraries/" : "usr/lib/") + name.replacingOccurrences(of: " ", with: "") + ".dylib"
            let binary = TweakBinary(path: file, isEntry: entry, filter: bundles.map { TweakFilter(bundles: $0) },
                                     slices: [TweakSlice(arch: "arm64", platform: 2, minOS: "15.0")],
                                     linked: ["/usr/lib/libobjc.A.dylib"], mentionsJailbreakPaths: false,
                                     imageName: (file as NSString).lastPathComponent)
            return TweakPackage(id: String(format: "5a5a%012lx", n), kind: .deb, origin: .added,
                                packageID: "com.example.tweak\(n)", name: name, version: version, author: author,
                                files: [file], binaries: [binary], notes: notes, addedAt: Date(timeIntervalSince1970: 1_800_000_000))
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
            video.tweaks = [ok, other, lib, added]
            video.installations[1].tweaks = [TweakUse(id: ok.id), TweakUse(id: other.id, force: true), TweakUse(id: lib.id),
                                             TweakUse(id: added.id)]
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
