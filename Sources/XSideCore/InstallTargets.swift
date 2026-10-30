import Foundation

/// Which devices the install window targets. Pure: device ids in, device ids out (in order).
public enum InstallTargets {
    /// When the window opens: the available devices that already have this app, else the first
    /// available device (a new app, or none of its devices reachable).
    public static func defaultSelection(available: [String], installedOn: Set<String>) -> [String] {
        let installed = available.filter(installedOn.contains)
        return installed.isEmpty ? Array(available.prefix(1)) : installed
    }

    /// The selection after the device list changed. Untouched by the user, it follows the default
    /// (keeping a still-available single choice). Edited, it keeps the user's order and only drops
    /// the devices no longer available; if that leaves nothing, the default applies again (a
    /// selection the user emptied stays empty).
    public static func reconcile(_ selection: [String], edited: Bool, available: [String],
                                 installedOn: Set<String>) -> [String] {
        let kept = selection.filter(available.contains)
        if edited {
            return kept.isEmpty && !selection.isEmpty
                ? defaultSelection(available: available, installedOn: installedOn) : kept
        }
        if !available.contains(where: installedOn.contains), !selection.isEmpty, kept == selection {
            return selection
        }
        return defaultSelection(available: available, installedOn: installedOn)
    }
}
