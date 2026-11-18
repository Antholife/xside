import Foundation

extension SettingsSection {
    /// The "Réglages XSide" section (spec §2 and its corrections; on its own page, opened from one
    /// row of the app's page, see `SettingsBundle`), with fr and en texts. Dates and
    /// other values come formatted (Mac locale): the dylib rewrites them at each launch in the
    /// device's. The toggles and choices start at `inApp`'s values (the installation's), else the
    /// defaults. Row keys, read and written by the dylib in the app's defaults under
    /// `io.github.xside.settings.<key>`:
    /// refreshOnLaunch (boolean action: the dylib turns it back off and refreshes at launch);
    /// (then a new group, `section.status`, under XSide's footer)
    /// validUntil, refreshedOn, version, installedOn, connection, lastRefresh (read-only text);
    /// showValidity, alertLate, refreshCard, reminder (booleans; "Messages XSide" is derived from
    /// them, see `InAppSettings.derivedLevel`),
    /// language (automatic|fr|en), autoRefresh (boolean).
    /// Titles are plain text in `language` ("fr" or "en", see `SettingsSection.plainText(in:)`).
    public static func xside(validUntil: String, refreshedOn: String, version: String, installedOn: String,
                             connection: String = "—", lastRefresh: String = "—",
                             inApp: InAppSettings? = nil, updateRepo: String? = nil,
                             updateFrequency: UpdateFrequency = .global, customFrequencyLabel: String? = nil,
                             dataBackups: [(id: String, label: String)] = [],
                             language: String = "en") -> SettingsSection {
        let s = inApp ?? InAppSettings.defaults(reminder: true, at: Date())
        let p = SettingsBundle.keyPrefix
        func title(_ name: String) -> String { p + "title." + name }
        func choice(_ name: String, _ values: [String], _ current: String) -> Row {
            .choice(titleKey: title(name), key: name, titleKeys: values.map { p + "\(name).\($0)" },
                    values: values, defaultValue: current)
        }
        // Master-detail (spec §2 corrections, maquette validée): a menu with « Statut » at the top,
        // then « Rafraîchissement » and « Affichage dans l'app », each opening a sub-page of its own.
        // iOS shows a child-pane row as a plain title and a chevron (no right-side summary).

        // Statut: the read-only rows the dylib rewrites in the device's locale at launch.
        let statusPage = SettingsSection(
            titleKey: title("menu.status"), footerKey: nil,
            rows: [.value(titleKey: title("validUntil"), key: "validUntil", defaultValue: validUntil),
                   .value(titleKey: title("refreshedOn"), key: "refreshedOn", defaultValue: refreshedOn),
                   .value(titleKey: title("version"), key: "version", defaultValue: version),
                   .value(titleKey: title("installedOn"), key: "installedOn", defaultValue: installedOn),
                   .value(titleKey: title("connection"), key: "connection", defaultValue: connection),
                   .value(titleKey: title("lastRefresh"), key: "lastRefresh", defaultValue: lastRefresh)],
            strings: texts)

        // Rafraîchissement: the "refresh at next launch" action (alone, with its footer saying what
        // it does), then automatic refresh. The action is a switch the app turns back off at its
        // next launch, asking XSide for a refresh; never synced with the Mac.
        let refreshPage = SettingsSection(
            titleKey: title("menu.refresh"), footerKey: p + "footer.refreshOnLaunch",
            rows: [.toggle(titleKey: title("refreshOnLaunch"), key: "refreshOnLaunch", defaultValue: false),
                   .group(key: "refresh.auto", footerKey: nil),
                   .toggle(titleKey: title("autoRefresh"), key: "autoRefresh", defaultValue: s.autoRefresh.value)],
            strings: texts)

        // Mises à jour (only when the app has a GitHub source): the tracked repo (read-only, changed
        // on the Mac), then « Quand une version sort » (notify / install on its own), synced like the
        // other settings. The frequency and « Vérifier maintenant » follow later.
        let updatesPage: Row? = updateRepo.map { repo in
            // « Vérifier » : an editable choice for the standard presets, a read-only line when the
            // Mac set a custom interval (changed from the Mac, as the footer says).
            let frequencyRow: Row = updateFrequency == .custom
                ? .value(titleKey: title("updateFrequency"), key: "updateFreq.custom",
                         defaultValue: customFrequencyLabel ?? (p + "updateFrequency.custom"))
                : choice("updateFrequency", UpdateFrequency.choices.map(\.rawValue), updateFrequency.rawValue)
            return .childPane(titleKey: title("menu.updates"), key: "pane.updates", fileSuffix: "updates",
                              page: SettingsSection(
                                titleKey: title("menu.updates"), footerKey: p + "footer.updates",
                                rows: [.value(titleKey: title("updates.repo"), key: "updates.repo", defaultValue: repo),
                                       choice("updateMode", ["notify", "auto"], s.updateMode.value.rawValue),
                                       frequencyRow,
                                       // An action (iOS Settings can't run one now): a switch the app
                                       // turns back off and acts on at its next launch, like refresh-on-launch.
                                       .group(key: "updates.action", footerKey: p + "footer.checkUpdates"),
                                       .toggle(titleKey: title("checkUpdates"), key: "checkUpdatesOnLaunch", defaultValue: false)],
                                strings: texts))
        }

        // Compatibilité: the per-device install options (the Duo fix, the signed-out-iCloud shim),
        // which take effect at the next refresh (re-sign), synced like the other settings.
        let compatPage = SettingsSection(
            titleKey: title("menu.compat"), footerKey: p + "footer.compat",
            rows: [.toggle(titleKey: title("duoCompatibility"), key: "duoCompatibility", defaultValue: s.duoCompatibility.value),
                   .toggle(titleKey: title("iCloudSignedOut"), key: "iCloudSignedOut", defaultValue: s.iCloudSignedOut.value)],
            strings: texts)

        // Données: the data snapshots XSide keeps. « Sauvegarder maintenant » (an action, at the next
        // launch) and « Restaurer depuis… » (pick a snapshot; DESTRUCTIVE, said in the footer), both
        // at the app's next launch like the other actions. Export/import stay on the Mac.
        var dataRows: [Row] = [
            .value(titleKey: title("data.count"), key: "data.count", defaultValue: "\(dataBackups.count)"),
            .group(key: "data.backup", footerKey: p + "footer.backupNow"),
            .toggle(titleKey: title("backupNow"), key: "backupNowOnLaunch", defaultValue: false)]
        if !dataBackups.isEmpty {
            dataRows.append(.group(key: "data.restore", footerKey: p + "footer.restore"))
            dataRows.append(.choice(titleKey: title("restoreFrom"), key: "restoreFrom",
                                    titleKeys: [p + "data.none"] + dataBackups.map(\.label),
                                    values: [""] + dataBackups.map(\.id), defaultValue: ""))
        }
        let dataPage = SettingsSection(titleKey: title("menu.data"), footerKey: p + "footer.data",
                                       rows: dataRows, strings: texts)

        // Affichage dans l'app: how XSide shows up in the app ("Messages XSide" is derived from the
        // four switches, see InAppSettings.derivedLevel) and the messages' language.
        let displayPage = SettingsSection(
            titleKey: title("menu.display"), footerKey: nil,
            rows: [.toggle(titleKey: title("showValidity"), key: "showValidity", defaultValue: s.showValidity.value),
                   .toggle(titleKey: title("alertLate"), key: "alertLate", defaultValue: s.alertLate.value),
                   .toggle(titleKey: title("refreshCard"), key: "refreshCard", defaultValue: s.refreshCard.value),
                   .toggle(titleKey: title("reminder"), key: "reminder", defaultValue: s.reminder.value),
                   choice("language", ["automatic", "fr", "en"], s.language.value.rawValue)],
            strings: texts)

        // The menu: « Statut » alone at the top, then the rest (Rafraîchissement, Mises à jour when
        // there is a source, Affichage), the "installed with XSide" footer below.
        var rest: [Row] = [.group(key: "menu.rest", footerKey: p + "footer"),
                           .childPane(titleKey: title("menu.refresh"), key: "pane.refresh", fileSuffix: "refresh", page: refreshPage)]
        if let updatesPage { rest.append(updatesPage) }
        rest.append(.childPane(titleKey: title("menu.compat"), key: "pane.compat", fileSuffix: "compat", page: compatPage))
        rest.append(.childPane(titleKey: title("menu.data"), key: "pane.data", fileSuffix: "data", page: dataPage))
        rest.append(.childPane(titleKey: title("menu.display"), key: "pane.display", fileSuffix: "display", page: displayPage))
        let menu = SettingsSection(
            titleKey: title("group"), footerKey: nil,
            rows: [.childPane(titleKey: title("menu.status"), key: "pane.status", fileSuffix: "status", page: statusPage)] + rest,
            strings: texts)
        return menu.plainText(in: language)
    }

    private static let texts: [String: [String: String]] = {
        let p = SettingsBundle.keyPrefix
        func table(_ pairs: [(String, String)]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: pairs.map { (p + $0.0, $0.1) })
        }
        let fr = table([
            ("title.group", "Réglages XSide"),
            ("title.menu.status", "Statut"), ("title.menu.refresh", "Rafraîchissement"),
            ("title.menu.updates", "Mises à jour"), ("title.menu.compat", "Compatibilité"),
            ("title.menu.data", "Données"), ("title.menu.display", "Affichage dans l'app"),
            ("title.data.count", "Sauvegardes"), ("data.none", "Aucune"),
            ("title.backupNow", "Sauvegarder maintenant"),
            ("footer.backupNow", "Crée une sauvegarde des données à la prochaine ouverture de l'app."),
            ("title.restoreFrom", "Restaurer depuis"),
            ("footer.restore", "⚠️ Remplace les données actuelles de l'app par la sauvegarde choisie, à la prochaine ouverture."),
            ("footer.data", "L'export et l'import d'archives restent sur ton Mac."),
            ("title.duoCompatibility", "Compatibilité iPhone Duo"), ("title.iCloudSignedOut", "Simuler iCloud déconnecté"),
            ("footer.compat", "Ces réglages s'appliquent au prochain rafraîchissement de l'app."),
            ("title.updates.repo", "Dépôt suivi"), ("title.updateMode", "Quand une version sort"),
            ("updateMode.notify", "Me prévenir"), ("updateMode.auto", "Installer seul"),
            ("title.updateFrequency", "Vérifier"),
            ("updateFrequency.global", "Réglage global"), ("updateFrequency.sixHours", "Toutes les 6 h"),
            ("updateFrequency.daily", "Chaque jour"), ("updateFrequency.weekly", "Chaque semaine"),
            ("updateFrequency.atRefresh", "À chaque rafraîchissement"), ("updateFrequency.never", "Jamais"),
            ("updateFrequency.custom", "Personnalisé"),
            ("title.checkUpdates", "Vérifier maintenant"),
            ("footer.checkUpdates", "Lance une recherche de mises à jour à la prochaine ouverture de l'app."),
            ("footer.updates", "Pour changer le dépôt suivi ou la variante, passe par ton Mac."),
            ("title.validUntil", "Valable jusqu'au"), ("title.refreshedOn", "Rafraîchie le"),
            ("title.version", "Version"), ("title.installedOn", "Installée le"),
            ("title.refreshOnLaunch", "Rafraîchir à la prochaine ouverture"),
            // Asked at the next launch or return to the app (XSWantsRefreshOnLaunch), the Mac
            // accepts on its own. "cet appareil": the same page is written for an iPad.
            ("footer.refreshOnLaunch", "Rafraîchit l'app la prochaine fois que tu l'ouvres, sans rien faire sur ton Mac : "
                + "il suffit qu'XSide soit ouvert sur ton Mac et que cet appareil soit sur le même Wi-Fi ou branché en USB."),
            ("title.connection", "Connexion au Mac"), ("title.lastRefresh", "Dernier rafraîchissement"),
            ("title.showValidity", "Afficher la validité à l'ouverture"),
            ("title.alertLate", "Alerter si pas rafraîchie"),
            ("title.refreshCard", "Carte après un rafraîchissement"),
            ("title.reminder", "Rappel avant l'expiration"),
            ("title.autoRefresh", "Rafraîchissement automatique"),
            ("title.language", "Langue des messages XSide"),
            ("language.automatic", "Automatique"), ("language.fr", "Français"), ("language.en", "English"),
            // iOS shows the footer as plain grey text: a list made of lines.
            ("footer", "✦ Installée avec XSide\n"
                + "• Rafraîchie automatiquement depuis ton Mac\n"
                + "• Tes choix s'appliquent tout de suite sur cet appareil\n"
                + "• XSide sur ton Mac en est informé à la prochaine connexion "
                + "(« Rafraîchissement automatique » ne change qu'à ce moment-là)\n"
                + "github.com/Antholife/xside"),
        ])
        let en = table([
            ("title.group", "XSide Settings"),
            ("title.menu.status", "Status"), ("title.menu.refresh", "Refresh"),
            ("title.menu.updates", "Updates"), ("title.menu.compat", "Compatibility"),
            ("title.menu.data", "Data"), ("title.menu.display", "In-app display"),
            ("title.data.count", "Backups"), ("data.none", "None"),
            ("title.backupNow", "Back up now"),
            ("footer.backupNow", "Backs up the data the next time you open the app."),
            ("title.restoreFrom", "Restore from"),
            ("footer.restore", "⚠️ Replaces the app's current data with the chosen backup, at the next launch."),
            ("footer.data", "Exporting and importing archives stays on your Mac."),
            ("title.duoCompatibility", "iPhone Duo compatibility"), ("title.iCloudSignedOut", "Simulate signed-out iCloud"),
            ("footer.compat", "These apply at the app's next refresh."),
            ("title.updates.repo", "Tracked repo"), ("title.updateMode", "When a version is out"),
            ("updateMode.notify", "Notify me"), ("updateMode.auto", "Install on its own"),
            ("title.updateFrequency", "Check"),
            ("updateFrequency.global", "Global setting"), ("updateFrequency.sixHours", "Every 6 h"),
            ("updateFrequency.daily", "Every day"), ("updateFrequency.weekly", "Every week"),
            ("updateFrequency.atRefresh", "At each refresh"), ("updateFrequency.never", "Never"),
            ("updateFrequency.custom", "Custom"),
            ("title.checkUpdates", "Check now"),
            ("footer.checkUpdates", "Runs an update check the next time you open the app."),
            ("footer.updates", "To change the tracked repo or the variant, use your Mac."),
            ("title.validUntil", "Valid until"), ("title.refreshedOn", "Last refreshed"),
            ("title.version", "Version"), ("title.installedOn", "Installed on"),
            ("title.refreshOnLaunch", "Refresh at next launch"),
            ("footer.refreshOnLaunch", "Refreshes the app the next time you open it, with nothing to do on your Mac: "
                + "XSide just needs to be open on your Mac, with this device on the same Wi-Fi or plugged in with USB."),
            ("title.connection", "Connection to the Mac"), ("title.lastRefresh", "Last refresh"),
            ("title.showValidity", "Show validity when opening"),
            ("title.alertLate", "Alert if not refreshed"),
            ("title.refreshCard", "Card after a refresh"),
            ("title.reminder", "Reminder before expiry"),
            ("title.autoRefresh", "Automatic refresh"),
            ("title.language", "XSide messages language"),
            ("language.automatic", "Automatic"), ("language.fr", "Français"), ("language.en", "English"),
            ("footer", "✦ Installed with XSide\n"
                + "• Refreshed automatically from your Mac\n"
                + "• Your choices apply on this device right away\n"
                + "• XSide on your Mac learns them at the next connection "
                + "(\"Automatic refresh\" only changes then)\n"
                + "github.com/Antholife/xside"),
        ])
        return ["fr": fr, "en": en]
    }()
}
