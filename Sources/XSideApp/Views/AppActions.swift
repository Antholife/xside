import SwiftUI
import XSideCore

/// An app's actions on its device, with their confirmations (`AppRowAlerts`): the panel row's
/// menu and Settings > Mes apps (its header's « ⋯ » and the bottom of « Module XSide ») run the
/// same ones. `present` shows each alert: the panel closes itself first (see
/// `PopoverView.afterClosing`), Settings shows it once the menu has closed. `done` runs after the
/// app is gone from the list (Settings then shows the device's next app).
@MainActor
enum AppActions {
    typealias Present = (@escaping @MainActor () -> Void) -> Void

    /// In a window: the alert once the menu that asked for it has closed.
    static let inWindow: Present = { alert in DispatchQueue.main.async { alert() } }

    private static func name(_ entry: AppEntry) -> String { entry.record.options.displayName ?? entry.record.displayName }

    /// Confirmed first; on failure (device out of reach, devicectl error) the alert offers to stop
    /// refreshing (pause) instead, unless it's already paused.
    static func uninstall(_ entry: AppEntry, deviceName: String, model: AppModel, present: @escaping Present,
                          done: @escaping @MainActor () -> Void = {}) {
        let app = name(entry)
        present {
            guard AppRowAlerts.confirmUninstall(app: app, device: deviceName) else { return }
            Task {
                do {
                    try await model.uninstall(entry)
                    // Not uninstalled when the row was busy meanwhile: still listed then.
                    if model.currentEntry(entry.id) == nil { done() }
                } catch {
                    present {
                        guard AppRowAlerts.uninstallFailed(app: app, device: deviceName, error: error,
                                                           offerPause: !entry.installation.refreshPaused) else { return }
                        Task { await model.stopRefreshing(entry) }
                    }
                }
            }
        }
    }

    static func stopRefreshing(_ entry: AppEntry, deviceName: String, model: AppModel, present: @escaping Present) {
        let app = name(entry)
        present {
            guard AppRowAlerts.confirmStopRefreshing(app: app, device: deviceName) else { return }
            Task { await model.stopRefreshing(entry) }
        }
    }

    /// No confirmation: undoing it is just stopping again.
    static func resume(_ entry: AppEntry, model: AppModel) {
        Task { await model.resumeRefreshing(entry) }
    }

    /// A pause of a while, without confirmation: it resumes by itself.
    static func pause(_ entry: AppEntry, until: Date, model: AppModel) {
        Task { await model.stopRefreshing(entry, until: until) }
    }

    static func removeFromList(_ entry: AppEntry, deviceName: String, model: AppModel, present: @escaping Present,
                               done: @escaping @MainActor () -> Void = {}) {
        let app = name(entry)
        present {
            guard AppRowAlerts.confirmRemoveFromList(app: app, device: deviceName) else { return }
            Task {
                await model.removeFromList(entry)
                if model.currentEntry(entry.id) == nil { done() }
            }
        }
    }
}

/// « Mettre en pause ▸ »'s durations, like the panel's Pause for this app alone (device feedback
/// 3, E5): 2 hours and 1 day resume by themselves, « Jusqu'à ce que je reprenne » stops (asked).
struct AppPauseDurations: View {
    let onPause: (Date) -> Void
    let onStopRefreshing: () -> Void

    var body: some View {
        Button(L("popover.app.pause.hours")) { onPause(Date().addingTimeInterval(2 * 3600)) }
        Button(L("popover.app.pause.day")) { onPause(Date().addingTimeInterval(86_400)) }
        Button(L("settings.pause.untilResumed"), action: onStopRefreshing)
    }
}

extension AppModel {
    /// Why the app's actions are greyed (`canManage` false), for their hover; nil when they aren't.
    func manageBlockedReason(_ entry: AppEntry) -> String? {
        let block = AppManagement.block(jobRunning: jobs[entry.id] != nil, uninstalling: uninstalling.contains(entry.id),
                                        removingDevice: removingDevices.contains(entry.installation.deviceID))
        switch block {
        case nil: return nil
        case .uninstalling: return L("appSettings.manage.blocked.uninstalling")
        case .jobRunning: return L("appSettings.manage.blocked.job")
        case .removingDevice: return L("appSettings.manage.blocked.removingDevice")
        }
    }
}
