import SwiftUI
import XSideCore

enum AppSettingsWindow {
    static let id = "appSettings"
}

/// "Réglages XSide…" from an app row's menu: the XSide-in-app options of that app on that device,
/// with where the device stands. Changes are stamped by the Mac and reach the app at its next
/// check-in or signing; "Rafraîchissement automatique" pauses or resumes it right away on the Mac.
struct AppSettingsWindowRoot: View {
    let model: AppModel
    let key: JobKey?
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

    private var entry: AppEntry? {
        guard let key, let record = model.records.first(where: { $0.id == key.recordID }),
              let installation = record.installations.first(where: { $0.deviceID == key.deviceID }) else { return nil }
        return AppEntry(record: record, installation: installation)
    }

    var body: some View {
        Group {
            if let entry {
                AppSettingsContent(model: model, entry: entry)
            } else {
                Text(L("appSettings.gone"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(KeepWindowOnScreen())
        .navigationTitle(L("appSettings.window"))
        .id(language)
    }
}

private struct AppSettingsContent: View {
    let model: AppModel
    let entry: AppEntry
    @State private var contentHeight: CGFloat = 300

    private var appName: String { entry.record.options.displayName ?? entry.record.displayName }
    private var deviceName: String {
        model.devices.first { $0.id == entry.installation.deviceID }?.name ?? L("popover.unknownDevice")
    }
    private var settings: InAppSettings {
        entry.installation.seededInApp(reminder: AppModel.setting(AppModel.deviceReminderKey), at: entry.installation.installedAt)
    }
    private var hasFeatures: Bool {
        !entry.record.options.resolvedWithoutXSideFeatures(default: AppModel.withoutXSideFeaturesByDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    InAppSettingsSection(
                        settings: settings, appName: appName,
                        hasFeatures: Binding(get: { hasFeatures }, set: { on in
                            Task { await model.setWithoutXSideFeatures(!on, recordID: entry.record.id) }
                        }),
                        edit: { change in Task { await model.editInApp(entry.id, change) } },
                        setAutoRefresh: { on in
                            Task {
                                if on {
                                    await model.resumeRefreshing(entry)
                                } else if AppRowAlerts.confirmStopRefreshing(app: appName, device: deviceName) {
                                    // Asked as from the row's "Arrêter de rafraîchir".
                                    await model.stopRefreshing(entry)
                                }
                            }
                        },
                        statuses: [DeviceSyncLine(deviceID: entry.installation.deviceID, deviceName: deviceName,
                                                  installation: entry.installation)],
                        isDisabled: !model.canManage(entry))
                    Text(L("appSettings.note"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, max(240, (NSScreen.main?.visibleFrame.height ?? 800) - 200)))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIconView(icon: model.icons.image(for: entry.record), isPaused: entry.installation.refreshPaused, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(appName)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(L("appSettings.subtitle", deviceName))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .background {
            Theme.brand.ignoresSafeArea(edges: .top)
        }
    }
}
