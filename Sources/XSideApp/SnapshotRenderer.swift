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
                    }
                }
                .padding(20).frame(width: InstallWindow.width).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("install-step2-\(language)-\(scheme).png"))
                render(InstallSummaryView(model: model, flow: flow)
                        .padding(20).frame(width: InstallWindow.width).background(Color(nsColor: .windowBackgroundColor)),
                       dark: dark, to: out.appendingPathComponent("install-summary-\(language)-\(scheme).png"))
                model.settingsPane = .apps
            }
        }
        print("snapshots written to \(out.path)")
        return 0
    }

    /// The Duo option: recommended (own scene delegate), not a Duo, already compatible, recommended
    /// with the compatibility module; then iCloud: recommended, useful, not needed.
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
            }
            CompatibilityFixCard {
                ICloudOptionRow(state: .recommended, appName: "Notes+", deviceName: "recommended", isOn: off)
                Divider().padding(.leading, 48)
                ICloudOptionRow(state: .useful, appName: "YouTube", deviceName: "useful", isOn: off)
                Divider().padding(.leading, 48)
                ICloudOptionRow(state: .notNeeded, appName: "Duolingo", deviceName: "notNeeded", isOn: off)
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

        /// An install of `legacyApp` on both devices, Duo compatibility on for the iPhone.
        @MainActor func flow() -> InstallFlow {
            let flow = InstallFlow(ipa: URL(fileURLWithPath: "/tmp/Instagram.ipa"))
            flow.info = AppInfo(bundleID: legacyApp.originalBundleID, name: legacyApp.displayName, version: "412.0",
                                executable: "Instagram", sdkVersion: "26.0", duo: legacyApp.duo, icloud: legacyApp.icloud)
            flow.deviceIDs = deviceIDs
            flow.duoDevices = [deviceIDs[0]]
            return flow
        }

        init(now: Date, library: URL) {
            let iPad = Device(id: "snapshot-ipad", udid: nil, name: "Anthony's iPad Air 5", model: "iPad Air (5th generation)",
                              kind: .iPad, transport: .network, isPaired: true, isAvailable: true, developerModeEnabled: true)
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
            // No scene support of its own: the Duo option brings the compatibility module.
            var photos = record(2, "Instagram", [installation(iPhone, days: 1.3, version: "412.0", paused: true)])
            photos.duo = DuoAppInfo(sdkVersion: "26.0", adoptsScenes: false, sceneDelegateClass: nil)
            photos.icloud = ICloudAppInfo(declaresICloud: true, containers: ["iCloud.com.example.app2"])
            let lessons = record(3, "Duolingo: Language Lessons", [installation(iPhone, days: 6.1, version: "6.9.0",
                                                                               checkIn: 2 * 86_400)])
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
