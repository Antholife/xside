import AppKit
import SwiftUI
import XSideCore

/// A change to XSide-in-app settings, stamped by whoever applies it (see `InAppSettings.setting`).
typealias InAppEdit = @Sendable (InAppSettings) -> InAppSettings

/// The XSide-in-app options, each explained, with a preview where there's something to see:
/// what the install window's step ③ and the per-app "Réglages XSide…" window show. Every change
/// goes through `edit`, stamped by the Mac now.
struct InAppSettingsSection: View {
    let settings: InAppSettings
    /// The app's name for "where to find it on the iPhone".
    let appName: String
    /// "Fonctionnalités XSide dans cette app" (on = has them). Turning it off asks first.
    @Binding var hasFeatures: Bool
    let edit: (@escaping InAppEdit) -> Void
    /// "Rafraîchissement automatique": nil uses `edit` (a draft); the per-app window pauses or
    /// resumes the installation instead.
    var setAutoRefresh: ((Bool) -> Void)?
    /// Per-device status lines, under the box.
    var statuses: [DeviceSyncLine] = []
    var isDisabled = false

    @State private var confirmingNoFeatures = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            card {
                InAppRow(symbol: "puzzlepiece.extension.fill", title: L("inApp.features"), note: L("inApp.features.note")) {
                    Toggle(L("inApp.features"), isOn: Binding(get: { hasFeatures }, set: { on in
                        if on { hasFeatures = true } else { confirmingNoFeatures = true }
                    }))
                    .labelsHidden()
                    .toggleStyle(.xside)
                    .controlSize(.small)
                }
            }
            if !hasFeatures {
                Label(L("inApp.features.off"), systemImage: "minus.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            // Never greyed: without features it says so instead of what reaches the app.
            if !statuses.isEmpty { DeviceSyncList(lines: statuses, hasFeatures: hasFeatures) }
            // Without features the rest stays visible, greyed: the values come back with them.
            Group {
                WhereBox(appName: appName)
                InAppOptionsCard(settings: settings, edit: edit, setAutoRefresh: setAutoRefresh)
            }
            .disabled(!hasFeatures)
            .opacity(hasFeatures ? 1 : 0.45)
        }
        .disabled(isDisabled)
        .sheet(isPresented: $confirmingNoFeatures) {
            NoFeaturesConfirmation(appName: appName) { hasFeatures = false }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The level menu, the four switches, the language and automatic refresh, in one card.
private struct InAppOptionsCard: View {
    let settings: InAppSettings
    let edit: (@escaping InAppEdit) -> Void
    let setAutoRefresh: ((Bool) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InAppRow(symbol: "text.bubble.fill", title: L("inApp.messages"),
                     note: settings.derivedLevel.note) {
                MessagesMenu(level: settings.derivedLevel) { level in
                    edit { $0.applying(level: level, at: Date(), by: .mac) }
                }
            }
            divider
            switchRow(.showValidity, \.showValidity)
            divider
            switchRow(.alertLate, \.alertLate)
            divider
            switchRow(.refreshCard, \.refreshCard)
            divider
            switchRow(.reminder, \.reminder)
            divider
            InAppRow(symbol: "globe", title: L("inApp.language"), note: L("inApp.language.note")) {
                LanguagePicker(language: settings.language.value) { language in
                    edit { $0.setting(\.language, to: language, at: Date(), by: .mac) }
                }
            }
            divider
            InAppRow(symbol: "arrow.triangle.2.circlepath", title: L("inApp.autoRefresh"), note: L("inApp.autoRefresh.note")) {
                Toggle(L("inApp.autoRefresh"), isOn: Binding(get: { settings.autoRefresh.value }, set: { on in
                    if let setAutoRefresh { setAutoRefresh(on) } else {
                        edit { $0.setting(\.autoRefresh, to: on, at: Date(), by: .mac) }
                    }
                }))
                .labelsHidden()
                .toggleStyle(.xside)
                .controlSize(.small)
            }
        }
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var divider: some View { Divider().padding(.leading, 48) }

    private func switchRow(_ option: InAppOption, _ keyPath: WritableKeyPath<InAppSettings, Field<Bool>> & Sendable) -> some View {
        InAppRow(symbol: option.symbol, title: option.title, note: option.note, preview: option.preview) {
            Toggle(option.title, isOn: Binding(get: { settings[keyPath: keyPath].value }, set: { on in
                edit { $0.setting(keyPath, to: on, at: Date(), by: .mac) }
            }))
            .labelsHidden()
            .toggleStyle(.xside)
            .controlSize(.small)
        }
    }
}

/// The four switches: their icon, texts and preview.
enum InAppOption: CaseIterable {
    case showValidity, alertLate, refreshCard, reminder

    var symbol: String {
        switch self {
        case .showValidity: "timer"
        case .alertLate: "exclamationmark.triangle.fill"
        case .refreshCard: "rectangle.bottomthird.inset.filled"
        case .reminder: "bell.badge.fill"
        }
    }

    var title: String {
        switch self {
        case .showValidity: L("inApp.showValidity")
        case .alertLate: L("inApp.alertLate")
        case .refreshCard: L("inApp.refreshCard")
        case .reminder: L("inApp.reminder")
        }
    }

    var note: String {
        switch self {
        case .showValidity: L("inApp.showValidity.note")
        case .alertLate: L("inApp.alertLate.note")
        case .refreshCard: L("inApp.refreshCard.note")
        case .reminder: L("inApp.reminder.note")
        }
    }

    var preview: InAppPreview.Kind {
        switch self {
        case .showValidity: .pill
        case .alertLate: .latePill
        case .refreshCard: .card
        case .reminder: .notification
        }
    }
}

extension MessageLevel {
    var label: String {
        switch self {
        case .all: L("inApp.level.all")
        case .essentials: L("inApp.level.essentials")
        case .none: L("inApp.level.none")
        case .custom: L("inApp.level.custom")
        }
    }

    var note: String {
        switch self {
        case .all: L("inApp.level.all.note")
        case .essentials: L("inApp.level.essentials.note")
        case .none: L("inApp.level.none.note")
        case .custom: L("inApp.level.custom.note")
        }
    }
}

extension MessageLanguage {
    var label: String {
        switch self {
        case .automatic: L("inApp.language.automatic")
        case .fr: "Français"
        case .en: "English"
        }
    }
}

/// "Messages XSide": shows the level the switches add up to; picking Tous, Essentiels or Aucun
/// sets the four switches ("Personnalisé" is only ever shown, never picked).
struct MessagesMenu: View {
    let level: MessageLevel
    let pick: (MessageLevel) -> Void

    var body: some View {
        Menu(level.label) {
            ForEach([MessageLevel.all, .essentials, .none], id: \.self) { choice in
                Button {
                    pick(choice)
                } label: {
                    if choice == level { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                }
            }
        }
        .fixedSize()
        .controlSize(.small)
    }
}

struct LanguagePicker: View {
    let language: MessageLanguage
    let pick: (MessageLanguage) -> Void

    var body: some View {
        Picker(L("inApp.language"), selection: Binding(get: { language }, set: { pick($0) })) {
            ForEach([MessageLanguage.automatic, .fr, .en], id: \.self) { Text($0.label).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
    }
}

/// One option: brand icon tile, title, its one-line explanation, an optional ⓘ preview, and the
/// control on the right.
struct InAppRow<Accessory: View>: View {
    let symbol: String
    let title: String
    let note: String?
    var preview: InAppPreview.Kind?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 13))
                    if let preview { PreviewButton(kind: preview) }
                }
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// "Modifiable ensuite sur l'iPhone : Réglages > Apps > <app> > Réglages XSide", highlighted.
struct WhereBox: View {
    let appName: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("inApp.where", appName))
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("inApp.where.alt"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.violet.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }
}
