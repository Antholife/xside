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
                             connection: String = "—", lastRefresh: String = "—", releaseTag: String? = nil,
                             xsideVersion: String? = nil,
                             inApp: InAppSettings? = nil, updateRepo: String? = nil,
                             updateFrequency: UpdateFrequency = .global, customFrequencyLabels: [String: String] = [:],
                             dataBackups: [(id: String, label: String)] = [],
                             language: String = "en") -> SettingsSection {
        let s = inApp ?? InAppSettings.defaults(reminder: true, at: Date())
        let p = SettingsBundle.keyPrefix
        func title(_ name: String) -> String { p + "title." + name }
        // The « custom » frequency title carries a dynamic interval, so it can't be a static key in
        // `texts`. Inject it per language into the strings table under its own key, so iOS shows it in
        // the DEVICE's language (not the Mac's): Anthony saw « Custom » on a French phone. With no
        // labels given, fall back to the static « Personnalisé » key.
        let customFreqKey = p + "updateFrequency.customValue"
        let customFreqTitleKey = customFrequencyLabels.isEmpty ? (p + "updateFrequency.custom") : customFreqKey
        var bundleStrings = texts
        for (lang, label) in customFrequencyLabels { bundleStrings[lang, default: [:]][customFreqKey] = label }
        func choice(_ name: String, _ values: [String], _ current: String) -> Row {
            .choice(titleKey: title(name), key: name, titleKeys: values.map { p + "\(name).\($0)" },
                    values: values, defaultValue: current)
        }
        // Master-detail (spec §2 corrections, maquette validée): a menu with « Statut » at the top,
        // then a sub-page per theme. iOS shows a child-pane row as a plain title and a chevron.
        // Every option sits in its own group so iOS shows an explanatory footer under each one
        // (Anthony: « explique chaque option avec un texte en dessous »).
        func pane(_ name: String, _ items: [(row: Row, footer: String)]) -> Row {
            var rows: [Row] = []
            for (i, item) in items.enumerated() {
                if i > 0 { rows.append(.group(key: "\(name).g\(i)", footerKey: p + "footer." + item.footer)) }
                rows.append(item.row)
            }
            let page = SettingsSection(titleKey: title("menu." + name),
                                       footerKey: items.first.map { p + "footer." + $0.footer },
                                       rows: rows, strings: bundleStrings)
            return .childPane(titleKey: title("menu." + name), key: "pane." + name, fileSuffix: name, page: page)
        }
        func toggle(_ name: String, _ key: String, _ on: Bool) -> Row { .toggle(titleKey: title(name), key: key, defaultValue: on) }
        func value(_ name: String, _ key: String, _ v: String) -> Row { .value(titleKey: title(name), key: key, defaultValue: v) }

        // Statut: read-only rows the dylib rewrites in the device's locale at launch. The three
        // versions sit together (Anthony): the app's own, the tracked release, then XSide's.
        var statusRows: [Row] = [value("validUntil", "validUntil", validUntil), value("refreshedOn", "refreshedOn", refreshedOn),
                                 value("version", "version", version)]
        if let releaseTag, !releaseTag.isEmpty { statusRows.append(value("releaseTag", "releaseTag", releaseTag)) }
        if let xsideVersion, !xsideVersion.isEmpty { statusRows.append(value("xsideVersion", "xsideVersion", xsideVersion)) }
        statusRows.append(contentsOf: [value("installedOn", "installedOn", installedOn),
                                       value("connection", "connection", connection), value("lastRefresh", "lastRefresh", lastRefresh)])
        // No footer here (Anthony: « enlève le texte sous Statut »).
        let statusPage: Row = .childPane(titleKey: title("menu.status"), key: "pane.status", fileSuffix: "status",
            page: SettingsSection(titleKey: title("menu.status"), footerKey: nil,
                rows: statusRows, strings: texts))

        // Rafraîchissement: the "refresh at next launch" action, then automatic refresh.
        let refreshPane = pane("refresh", [
            (toggle("refreshOnLaunch", "refreshOnLaunch", false), "refreshOnLaunch"),
            (toggle("autoRefresh", "autoRefresh", s.autoRefresh.value), "autoRefresh")])

        // Mises à jour (only with a GitHub source): tracked repo, mode, frequency, « Vérifier maintenant ».
        let updatesPane: Row? = updateRepo.map { repo in
            // One stable picker that ALWAYS includes « custom », so the current value (which can reach
            // the phone over the channel before the bundle is re-signed) never lands on a specifier
            // whose values don't list it — that showed an empty row (Anthony: « l'option est vide »).
            // « custom » is a Mac-set interval the phone can't name, so its title is the interval the
            // Mac wrote (« 4 sem. ») or « Personnalisé ».
            let freqValues = UpdateFrequency.choices.map(\.rawValue) + ["custom"]
            let freqTitles = UpdateFrequency.choices.map { p + "updateFrequency.\($0.rawValue)" }
                + [customFreqTitleKey]
            let frequencyRow: Row = .choice(titleKey: title("updateFrequency"), key: "updateFrequency",
                                            titleKeys: freqTitles, values: freqValues, defaultValue: updateFrequency.rawValue)
            return pane("updates", [
                (value("updates.repo", "updates.repo", repo), "updatesRepo"),
                (choice("updateMode", ["notify", "auto"], s.updateMode.value.rawValue), "updateMode"),
                (frequencyRow, "updateFrequency"),
                (toggle("checkUpdates", "checkUpdatesOnLaunch", false), "checkUpdates")])
        }

        // Compatibilité: the per-device install options, applied at the next refresh.
        let compatPane = pane("compat", [
            (toggle("duoCompatibility", "duoCompatibility", s.duoCompatibility.value), "duoCompatibility"),
            (toggle("iCloudSignedOut", "iCloudSignedOut", s.iCloudSignedOut.value), "iCloudSignedOut")])

        // Données: the backup options, « Sauvegarder maintenant », and « Restaurer depuis… » when there
        // are snapshots. The count and the restore list are as of the last refresh (static page).
        var dataItems: [(row: Row, footer: String)] = [
            (value("data.count", "data.count", "\(dataBackups.count)"), "dataCount"),
            (toggle("backupData", "backupData", s.backupData.value), "backupData"),
            (toggle("backupCaches", "backupCaches", s.backupCaches.value), "backupCaches"),
            (toggle("backupBeforeUpdate", "backupBeforeUpdate", s.backupBeforeUpdate.value), "backupBeforeUpdate"),
            (toggle("backupNow", "backupNowOnLaunch", false), "backupNow")]
        if !dataBackups.isEmpty {
            dataItems.append((.choice(titleKey: title("restoreFrom"), key: "restoreFrom",
                                      titleKeys: [p + "data.none"] + dataBackups.map(\.label),
                                      values: [""] + dataBackups.map(\.id), defaultValue: ""), "restore"))
        }
        let dataPane = pane("data", dataItems)

        // Affichage dans l'app: how XSide shows up in the app, and the messages' language.
        let displayPane = pane("display", [
            (toggle("showValidity", "showValidity", s.showValidity.value), "showValidity"),
            (toggle("alertLate", "alertLate", s.alertLate.value), "alertLate"),
            (toggle("refreshCard", "refreshCard", s.refreshCard.value), "refreshCard"),
            (toggle("reminder", "reminder", s.reminder.value), "reminder"),
            (choice("language", ["automatic", "fr", "en"], s.language.value.rawValue), "language")])

        // The menu: « Statut » alone at the top, then the rest, the "installed with XSide" footer below.
        var rest: [Row] = [.group(key: "menu.rest", footerKey: p + "footer"), refreshPane]
        if let updatesPane { rest.append(updatesPane) }
        rest.append(contentsOf: [compatPane, dataPane, displayPane])
        // No note under « Statut » (Anthony: « enlève le texte sous Statut »); the per-option footers
        // already say when each change is taken into account.
        let menu = SettingsSection(titleKey: title("group"), footerKey: nil,
                                   rows: [statusPage] + rest, strings: bundleStrings)
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
            ("title.backupData", "Sauvegarder les données"), ("title.backupCaches", "Inclure les caches"),
            ("title.backupBeforeUpdate", "Sauvegarder avant une mise à jour"),
            ("title.backupNow", "Sauvegarder maintenant"),
            ("footer.backupNow", "📲 À la prochaine ouverture de l'app : crée une sauvegarde des données, puis XSide rafraîchit l'app."),
            ("title.restoreFrom", "Restaurer depuis"),
            ("footer.restore", "📲 À la prochaine ouverture de l'app. ⚠️ Remplace les données actuelles par la sauvegarde choisie."),
            ("footer.data", "L'export et l'import d'archives restent sur ton Mac."),
            ("title.duoCompatibility", "Compatibilité iPhone Duo"), ("title.iCloudSignedOut", "Simuler iCloud déconnecté"),
            ("footer.compat", "Changer une de ces options rafraîchit l'app pour l'appliquer."),
            ("title.updates.repo", "Dépôt suivi"), ("title.updateMode", "Quand une version sort"),
            ("updateMode.notify", "Me prévenir"), ("updateMode.auto", "Installer seul"),
            ("title.updateFrequency", "Vérifier"),
            ("updateFrequency.global", "Réglage global"), ("updateFrequency.sixHours", "Toutes les 6 h"),
            ("updateFrequency.daily", "Chaque jour"), ("updateFrequency.weekly", "Chaque semaine"),
            ("updateFrequency.atRefresh", "À chaque rafraîchissement"), ("updateFrequency.never", "Jamais"),
            ("updateFrequency.custom", "Personnalisé"),
            ("title.checkUpdates", "Vérifier maintenant"),
            ("footer.checkUpdates", "📲 À la prochaine ouverture de l'app : XSide recherche les mises à jour du dépôt suivi."),
            ("footer.intro", "📲 Un changement ici s'applique à la prochaine ouverture de l'app (ou quand tu y reviens) : XSide le lit alors et prévient ton Mac. iOS ne permet pas de le faire pendant que l'app est fermée."),
            ("footer.status", "Rafraîchi par ton Mac. Ces infos sont réécrites dans ta langue à l'ouverture de l'app."),
            ("footer.autoRefresh", "Activé : XSide rafraîchit l'app avant qu'elle expire. Désactivé : elle expirera à sa date."),
            ("footer.updatesRepo", "Le dépôt GitHub d'où viennent les mises à jour. Pour en changer, passe par ton Mac."),
            ("footer.updateMode", "Me prévenir : une notification quand une version sort. Installer seul : XSide l'installe tout seul, après un contrôle du contenu."),
            ("footer.updateFrequency", "À quelle fréquence XSide regarde si une nouvelle version est sortie. La valeur « Personnalisé » se règle depuis XSide sur le Mac : fiche de l'app > Mises à jour."),
            ("footer.duoCompatibility", "Adapte l'app aux deux écrans de l'iPhone Duo. Rafraîchit l'app pour l'appliquer."),
            ("footer.iCloudSignedOut", "Fait croire à l'app qu'iCloud est déconnecté. Rafraîchit l'app pour l'appliquer."),
            ("footer.dataCount", "Sauvegardes gardées sur ton Mac (compte à jour au dernier rafraîchissement de l'app)."),
            ("footer.backupData", "XSide garde une copie des données sur ton Mac, à chaque rafraîchissement si elles ont changé."),
            ("footer.backupCaches", "Inclut les dossiers Caches et tmp dans les sauvegardes."),
            ("footer.backupBeforeUpdate", "Sauvegarde les données juste avant qu'une mise à jour s'installe."),
            ("footer.showValidity", "Affiche combien de temps l'app reste valable, à son ouverture."),
            ("footer.alertLate", "Prévient si XSide n'a pas pu rafraîchir l'app à temps."),
            ("footer.refreshCard", "Affiche une carte dans l'app après un rafraîchissement."),
            ("footer.reminder", "Un rappel avant que l'app expire."),
            ("footer.language", "La langue des messages d'XSide dans l'app."),
            ("title.validUntil", "Valable jusqu'au"), ("title.refreshedOn", "Rafraîchie le"),
            ("title.version", "Version de l'app"), ("title.releaseTag", "Version de la release"),
            ("title.xsideVersion", "Version de XSide"), ("title.installedOn", "Installée le"),
            ("title.refreshOnLaunch", "Rafraîchir à la prochaine ouverture"),
            // Asked at the next launch or return to the app (XSWantsRefreshOnLaunch), the Mac
            // accepts on its own. "cet appareil": the same page is written for an iPad.
            ("footer.refreshOnLaunch", "📲 À la prochaine ouverture de l'app : rafraîchit l'app, sans rien faire sur ton Mac. "
                + "Il suffit qu'XSide soit ouvert sur ton Mac et que cet appareil soit sur le même Wi-Fi ou branché en USB."),
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
            ("title.backupData", "Back up data"), ("title.backupCaches", "Include caches"),
            ("title.backupBeforeUpdate", "Back up before an update"),
            ("title.backupNow", "Back up now"),
            ("footer.backupNow", "📲 Next time you open the app: backs up the data, then XSide refreshes the app."),
            ("title.restoreFrom", "Restore from"),
            ("footer.restore", "📲 Next time you open the app. ⚠️ Replaces the current data with the chosen backup."),
            ("footer.data", "Exporting and importing archives stays on your Mac."),
            ("title.duoCompatibility", "iPhone Duo compatibility"), ("title.iCloudSignedOut", "Simulate signed-out iCloud"),
            ("footer.compat", "Changing one of these refreshes the app to apply it."),
            ("title.updates.repo", "Tracked repo"), ("title.updateMode", "When a version is out"),
            ("updateMode.notify", "Notify me"), ("updateMode.auto", "Install on its own"),
            ("title.updateFrequency", "Check"),
            ("updateFrequency.global", "Global setting"), ("updateFrequency.sixHours", "Every 6 h"),
            ("updateFrequency.daily", "Every day"), ("updateFrequency.weekly", "Every week"),
            ("updateFrequency.atRefresh", "At each refresh"), ("updateFrequency.never", "Never"),
            ("updateFrequency.custom", "Custom"),
            ("title.checkUpdates", "Check now"),
            ("footer.checkUpdates", "📲 Next time you open the app: XSide checks the tracked repo for updates."),
            ("footer.intro", "📲 A change here applies the next time you open the app (or come back to it): XSide reads it then and tells your Mac. iOS can't do it while the app is closed."),
            ("footer.status", "Refreshed by your Mac. These are rewritten in your language when you open the app."),
            ("footer.autoRefresh", "On: XSide refreshes the app before it expires. Off: it will expire on its date."),
            ("footer.updatesRepo", "The GitHub repo updates come from. To change it, use your Mac."),
            ("footer.updateMode", "Notify me: a notification when a version is out. Install on its own: XSide installs it for you, after a content check."),
            ("footer.updateFrequency", "How often XSide checks whether a new version is out. The « Custom » value is set from XSide on your Mac: the app's page > Updates."),
            ("footer.duoCompatibility", "Adapts the app to the iPhone Duo's two screens. Refreshes the app to apply it."),
            ("footer.iCloudSignedOut", "Makes the app think iCloud is signed out. Refreshes the app to apply it."),
            ("footer.dataCount", "Backups kept on your Mac (count as of the app's last refresh)."),
            ("footer.backupData", "XSide keeps a copy of the data on your Mac, at each refresh if it changed."),
            ("footer.backupCaches", "Includes the Caches and tmp folders in the backups."),
            ("footer.backupBeforeUpdate", "Backs up the data just before an update installs."),
            ("footer.showValidity", "Shows how long the app stays valid, when you open it."),
            ("footer.alertLate", "Warns if XSide couldn't refresh the app in time."),
            ("footer.refreshCard", "Shows a card in the app after a refresh."),
            ("footer.reminder", "A reminder before the app expires."),
            ("footer.language", "The language of XSide's messages in the app."),
            ("title.validUntil", "Valid until"), ("title.refreshedOn", "Last refreshed"),
            ("title.version", "App version"), ("title.releaseTag", "Release version"),
            ("title.xsideVersion", "XSide version"), ("title.installedOn", "Installed on"),
            ("title.refreshOnLaunch", "Refresh at next launch"),
            ("footer.refreshOnLaunch", "📲 Next time you open the app: refreshes it, with nothing to do on your Mac. "
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
        // A short reminder under each editable setting that it is registered when the app reopens
        // (Anthony: « des wordings de rappel un peu partout, genre mise à jour »). The intro note says
        // it once at the top; these repeat it per option. Compat/Duo/iCloud and the action toggles
        // already carry their own (« au prochain rafraîchissement » / « À la prochaine ouverture »).
        let syncKeys = ["footer.autoRefresh", "footer.updateMode", "footer.updateFrequency",
                        "footer.showValidity", "footer.alertLate", "footer.refreshCard", "footer.reminder",
                        "footer.language", "footer.backupData", "footer.backupCaches", "footer.backupBeforeUpdate"]
        var frM = fr, enM = en
        for k in syncKeys {
            let key = p + k
            if let v = frM[key] { frM[key] = v + "\n📲 Pris en compte à la prochaine ouverture de l'app." }
            if let v = enM[key] { enM[key] = v + "\n📲 Taken into account next time you open the app." }
        }
        return ["fr": frM, "en": enM]
    }()
}
