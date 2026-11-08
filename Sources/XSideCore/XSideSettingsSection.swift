import Foundation

extension SettingsSection {
    /// The "Réglages XSide" section (spec §2 and its corrections; on its own page, opened from one
    /// row of the app's page, see `SettingsBundle`), with fr and en texts. Dates and
    /// other values come formatted (Mac locale): the dylib rewrites them at each launch in the
    /// device's. The toggles and choices start at `inApp`'s values (the installation's), else the
    /// defaults. Row keys, read and written by the dylib in the app's defaults under
    /// `io.github.xside.settings.<key>`:
    /// validUntil, refreshedOn, version, installedOn, connection, lastRefresh (read-only text);
    /// showValidity, alertLate, refreshCard, reminder (booleans; "Messages XSide" is derived from
    /// them, see `InAppSettings.derivedLevel`),
    /// language (automatic|fr|en), autoRefresh (boolean).
    public static func xside(validUntil: String, refreshedOn: String, version: String, installedOn: String,
                             connection: String = "—", lastRefresh: String = "—",
                             inApp: InAppSettings? = nil) -> SettingsSection {
        let s = inApp ?? InAppSettings.defaults(reminder: true, at: Date())
        let p = SettingsBundle.keyPrefix
        func title(_ name: String) -> String { p + "title." + name }
        func choice(_ name: String, _ values: [String], _ current: String) -> Row {
            .choice(titleKey: title(name), key: name, titleKeys: values.map { p + "\(name).\($0)" },
                    values: values, defaultValue: current)
        }
        let rows: [Row] = [
            .value(titleKey: title("validUntil"), key: "validUntil", defaultValue: validUntil),
            .value(titleKey: title("refreshedOn"), key: "refreshedOn", defaultValue: refreshedOn),
            .value(titleKey: title("version"), key: "version", defaultValue: version),
            .value(titleKey: title("installedOn"), key: "installedOn", defaultValue: installedOn),
            .value(titleKey: title("connection"), key: "connection", defaultValue: connection),
            .value(titleKey: title("lastRefresh"), key: "lastRefresh", defaultValue: lastRefresh),
            .toggle(titleKey: title("showValidity"), key: "showValidity", defaultValue: s.showValidity.value),
            .toggle(titleKey: title("alertLate"), key: "alertLate", defaultValue: s.alertLate.value),
            .toggle(titleKey: title("refreshCard"), key: "refreshCard", defaultValue: s.refreshCard.value),
            .toggle(titleKey: title("reminder"), key: "reminder", defaultValue: s.reminder.value),
            .toggle(titleKey: title("autoRefresh"), key: "autoRefresh", defaultValue: s.autoRefresh.value),
            choice("language", ["automatic", "fr", "en"], s.language.value.rawValue),
        ]
        return SettingsSection(titleKey: title("group"), footerKey: p + "footer", rows: rows, strings: texts)
    }

    private static let texts: [String: [String: String]] = {
        let p = SettingsBundle.keyPrefix
        func table(_ pairs: [(String, String)]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: pairs.map { (p + $0.0, $0.1) })
        }
        let fr = table([
            ("title.group", "Réglages XSide"),
            ("title.validUntil", "Valable jusqu'au"), ("title.refreshedOn", "Rafraîchie le"),
            ("title.version", "Version"), ("title.installedOn", "Installée le"),
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
                + "• Tes choix s'appliquent tout de suite sur cet iPhone\n"
                + "• XSide sur ton Mac en est informé à la prochaine connexion "
                + "(« Rafraîchissement automatique » ne change qu'à ce moment-là)\n"
                + "github.com/Antholife/xside"),
        ])
        let en = table([
            ("title.group", "XSide Settings"),
            ("title.validUntil", "Valid until"), ("title.refreshedOn", "Last refreshed"),
            ("title.version", "Version"), ("title.installedOn", "Installed on"),
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
                + "• Your choices apply on this iPhone right away\n"
                + "• XSide on your Mac learns them at the next connection "
                + "(\"Automatic refresh\" only changes then)\n"
                + "github.com/Antholife/xside"),
        ])
        return ["fr": fr, "en": en]
    }()
}
