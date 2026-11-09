import AppKit
import SwiftUI
import XSideCore

/// A change to XSide-in-app settings, stamped by whoever applies it (see `InAppSettings.setting`).
typealias InAppEdit = @Sendable (InAppSettings) -> InAppSettings

/// The XSide-in-app options, each explained, with a preview where there's something to see:
/// what the install window's step ④ and Settings > Mes apps show. Every change
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
    /// Right under the features card (Mes apps: the change waits for the next refresh).
    var featuresNotice: AnyView?
    var isDisabled = false
    /// Two columns (features, status and where to find them | the options): the install window.
    var columns = false

    @State private var confirmingNoFeatures = false

    var body: some View {
        Group {
            if columns {
                // The install window: side by side, so step ④ fits without scrolling.
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        featuresPart
                        greyedWithoutFeatures(WhereBox(appName: appName))
                    }
                    .frame(maxWidth: .infinity)
                    greyedWithoutFeatures(InAppOptionsCard(settings: settings, edit: edit, setAutoRefresh: setAutoRefresh))
                        .frame(maxWidth: .infinity)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    featuresPart
                    greyedWithoutFeatures(VStack(alignment: .leading, spacing: 10) {
                        WhereBox(appName: appName)
                        InAppOptionsCard(settings: settings, edit: edit, setAutoRefresh: setAutoRefresh)
                    })
                }
            }
        }
        .disabled(isDisabled)
        .sheet(isPresented: $confirmingNoFeatures) {
            NoFeaturesConfirmation(appName: appName) {
                hasFeatures = false
            }
        }
    }

    /// Without features the rest stays visible, greyed: the values come back with them.
    private func greyedWithoutFeatures<V: View>(_ view: V) -> some View {
        view.disabled(!hasFeatures).opacity(hasFeatures ? 1 : 0.45)
    }

    /// The features switch with why one would turn it off, and the per-device status.
    @ViewBuilder private var featuresPart: some View {
        card {
            InAppRow(symbol: "puzzlepiece.extension.fill", title: L("inApp.features"), note: L("inApp.features.note")) {
                Toggle(L("inApp.features"), isOn: Binding(get: { hasFeatures }, set: { on in
                    if on { hasFeatures = true } else { confirmingNoFeatures = true }
                }))
                .labelsHidden()
                .toggleStyle(.xside)
                .controlSize(.small)
            }
            // Why one would turn it off, said where it can't be missed (device feedback 2026-11-08).
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .accessibilityHidden(true)
                Text(L("inApp.features.tip"))
                    .font(.system(size: 11.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .systemOrange).opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            if let featuresNotice { featuresNotice }
        }
        if !hasFeatures {
            Label(L("inApp.features.off"), systemImage: "minus.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
        // Never greyed: without features it says so instead of what reaches the app.
        if !statuses.isEmpty { DeviceSyncList(lines: statuses, hasFeatures: hasFeatures) }
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
        XSidePopup(title: level.label, accessibilityLabel: L("inApp.messages"),
                   choices: [MessageLevel.all, .essentials, .none], selected: level, label: \.label, pick: pick)
    }
}

struct LanguagePicker: View {
    let language: MessageLanguage
    let pick: (MessageLanguage) -> Void

    var body: some View {
        XSidePopup(title: language.label, accessibilityLabel: L("inApp.language"),
                   choices: [MessageLanguage.automatic, .fr, .en], selected: language, label: \.label, pick: pick)
    }
}

/// XSide's popup menu (device feedback 2026-11-08: the system's grey popup looked foreign next
/// to the brand switches): the current choice, then a small brand-gradient box with the chevrons,
/// like `XSideSwitch`. The menu itself is the system's, with a checkmark on the current choice.
struct XSidePopup<Choice: Hashable>: View {
    let title: String
    let accessibilityLabel: String
    let choices: [Choice]
    let selected: Choice
    let label: KeyPath<Choice, String>
    let pick: (Choice) -> Void

    var body: some View {
        Menu {
            ForEach(choices, id: \.self) { choice in
                Button {
                    pick(choice)
                } label: {
                    if choice == selected { Label(choice[keyPath: label], systemImage: "checkmark") }
                    else { Text(choice[keyPath: label]) }
                }
            }
        } label: {
            Text(title)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(XSidePopupStyle())
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(title)
    }
}

/// The look of `XSidePopup`: a soft rounded field, the label, and the brand chevron box.
struct XSidePopupStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                .accessibilityHidden(true)
        }
        .padding(.leading, 9)
        .padding(.trailing, 3)
        .frame(minHeight: 22)
        .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Theme.violet.opacity(0.3), lineWidth: 0.5))
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

/// Where to change these settings later on the iPhone, highlighted: the long press on the app's
/// icon and the Settings path ("Réglages > Apps > YouTube > Réglages XSide"), the two ways shown
/// alike (device feedback 2026-11-08). `appName`: the app's name, or `inApp.where.anyApp`.
struct WhereBox: View {
    let appName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("inApp.where.title"))
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            way(symbol: "hand.tap.fill", text: L("inApp.where.alt"))
            way(symbol: "gearshape.fill", text: L("inApp.where", appName))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.violet.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }

    private func way(symbol: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
