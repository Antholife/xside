/// The actions Settings > Mes apps offers on the app shown (its header's « ⋯ » menu, and the
/// zone at the bottom of « Module XSide »): the panel row's own, in the order of the approved
/// mockup, why they're greyed, and which app the page shows once that one is gone.
public enum AppManagement {
    public enum Item: Equatable, Sendable {
        case refresh, pause, stop, resume, separator, ipaContent, removeFromList, uninstall
    }

    /// Why the row's actions are greyed (`AppModel.canManage` is false).
    public enum Block: Equatable, Sendable {
        /// The app is being uninstalled from its device.
        case uninstalling
        /// A refresh, a reinstall or another action runs on the row.
        case jobRunning
        /// The device is being removed from XSide.
        case removingDevice
    }

    /// « Rafraîchir maintenant », « Mettre en pause ▸ » and « Arrêter de rafraîchir » while it
    /// refreshes, « Reprendre » instead of both once it's stopped or paused; then « Contenu de
    /// l'IPA… »; then « Retirer de la liste » and « Désinstaller de … ».
    public static func menu(isPaused: Bool) -> [Item] {
        (isPaused ? [.refresh, .resume] : [.refresh, .pause, .stop])
            + [.separator, .ipaContent, .separator, .removeFromList, .uninstall]
    }

    /// The reason, nil when nothing blocks. The device's removal first (it ends every row of
    /// it), then an uninstall (which claims the row too, so it is named rather than « a job »).
    public static func block(jobRunning: Bool, uninstalling: Bool, removingDevice: Bool) -> Block? {
        if removingDevice { return .removingDevice }
        if uninstalling { return .uninstalling }
        return jobRunning ? .jobRunning : nil
    }

    /// The app shown once `id` is gone from its device's list `ids`: the one after it, else the
    /// one before, nil when it was the device's only app. Not in the list (reloaded meanwhile):
    /// the device's first.
    public static func selection<ID: Equatable>(afterRemoving id: ID, from ids: [ID]) -> ID? {
        guard let index = ids.firstIndex(of: id) else { return ids.first }
        if index + 1 < ids.count { return ids[index + 1] }
        return index > 0 ? ids[index - 1] : nil
    }
}
