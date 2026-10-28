import SwiftUI

/// Minimal settings until the real window (later task): only the language picker, so the
/// French / English switch can be checked.
struct SettingsPlaceholderView: View {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

    var body: some View {
        Form {
            Picker(L("settings.language"), selection: $language) {
                Text(L("settings.language.system")).tag(AppLanguage.system.rawValue)
                Text(L("settings.language.en")).tag(AppLanguage.en.rawValue)
                Text(L("settings.language.fr")).tag(AppLanguage.fr.rawValue)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(L("popover.settings"))
        .id(language)
    }
}
