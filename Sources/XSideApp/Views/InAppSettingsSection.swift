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
            // Without features the rest stays visible, greyed: the values come back with them.
            Group {
                WhereBox(appName: appName)
                if !statuses.isEmpty { DeviceSyncList(lines: statuses) }
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

/// ⓘ next to an option: a popover with what it looks like on the iPhone.
private struct PreviewButton: View {
    let kind: InAppPreview.Kind
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(L("inApp.preview"))
        .accessibilityLabel(L("inApp.preview"))
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("inApp.preview"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                InAppPreview(kind: kind)
            }
            .padding(14)
            .frame(width: 320)
        }
    }
}

/// Small drawings of what XSide shows in the app: the pill (normal and late), the card after a
/// refresh and the reminder notification. Indicative, drawn on a dark "screen".
struct InAppPreview: View {
    enum Kind { case pill, latePill, card, notification }
    let kind: Kind

    var body: some View {
        ZStack(alignment: kind == .card ? .bottom : .top) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                .frame(minHeight: kind == .card ? 120 : 80)
            content.padding(8)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .pill:
            pill(days: L("inApp.preview.days5"), color: .primary, hint: nil)
        case .latePill:
            pill(days: L("inApp.preview.days1"), color: Color(nsColor: .systemOrange), hint: L("inApp.preview.late"))
        case .card:
            HStack(spacing: 10) {
                logo(size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("inApp.preview.cardTitle")).font(.system(size: 12, weight: .bold))
                    Text(L("inApp.preview.cardText", Self.sampleDate)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .notification:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.brand).frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(L("inApp.preview.notifTitle", "YouTube")).font(.system(size: 11.5, weight: .semibold))
                        Spacer(minLength: 4)
                        Text(L("inApp.preview.now")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text(L("inApp.preview.notifText")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(9)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func pill(days: String, color: Color, hint: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            logo(size: 20)
            VStack(alignment: .leading, spacing: 2) {
                (Text(L("inApp.preview.validFor")) + Text(days).bold().foregroundColor(color))
                    .font(.system(size: 12))
                if let hint {
                    Text(hint).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if hint != nil {
                Text(L("inApp.preview.refresh"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.brand, in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: hint == nil ? 18 : 14, style: .continuous))
    }

    private func logo(size: CGFloat) -> some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private static var sampleDate: String {
        Date().addingTimeInterval(6 * 86_400).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
            .hour().minute().locale(appLocale))
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

/// One device's line: whether the app there talks to XSide, and where the Mac's changes stand.
struct DeviceSyncLine: Identifiable {
    let deviceID: String
    let deviceName: String
    /// nil: not installed there yet (the values go with the install).
    let installation: Installation?
    var id: String { deviceID }
}

struct DeviceSyncList: View {
    let lines: [DeviceSyncLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(L("inApp.status.title"))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(lines) { line in
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        DeviceSyncRow(line: line, now: context.date)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct DeviceSyncRow: View {
    let line: DeviceSyncLine
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(line.deviceName).font(.system(size: 12, weight: .semibold))
            }
            Text(reachability)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 13)
            if let delivery {
                Text(delivery)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 13)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var status: ReachabilityStatus? {
        line.installation.map { ReachabilityStatus.of(installation: $0, now: now) }
    }

    private var dotColor: Color {
        if case .joinable? = status { return Theme.reachable }
        return Theme.unreachable
    }

    private var reachability: String {
        switch status {
        case nil: L("inApp.reach.notInstalled")
        case .joinable?: L("inApp.reach.joinable")
        case .neverConnected?: L("inApp.reach.never")
        case .notSeenSince(let date)?: L("inApp.reach.notSeen", Self.format(date))
        }
    }

    private var delivery: String? {
        guard let installation = line.installation else { return nil }
        switch SettingsDelivery.of(installation: installation) {
        case .nothing: return nil
        case .pending: return L("inApp.delivery.pending", line.deviceName)
        case .sentWithSigning(let date): return L("inApp.delivery.sent", Self.format(date))
        case .applied(let date): return L("inApp.delivery.applied", line.deviceName, Self.format(date))
        }
    }

    static func format(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(appLocale))
    }
}

/// Asked before an app (or every app) goes without XSide's features: what's lost, why it's
/// useful, when it applies.
struct NoFeaturesConfirmation: View {
    /// nil: the Mac-wide setting.
    let appName: String?
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private static let items: [(symbol: String, key: String)] = [
        ("rectangle.portrait.bottomhalf.inset.filled", "noFeatures.item.sheet"),
        ("rectangle.bottomthird.inset.filled", "noFeatures.item.card"),
        ("rectangle.topthird.inset.filled", "noFeatures.item.pill"),
        ("bell.badge.fill", "noFeatures.item.reminder"),
        ("gearshape.fill", "noFeatures.item.settings"),
        ("hand.tap.fill", "noFeatures.item.quick"),
        ("arrow.triangle.2.circlepath", "noFeatures.item.channel"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appName.map { L("noFeatures.titleApp", $0) } ?? L("noFeatures.titleAll"))
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                Text(L(appName == nil ? "noFeatures.lostAll" : "noFeatures.lost"))
                    .font(.system(size: 12, weight: .medium))
                ForEach(Self.items, id: \.key) { item in
                    Label {
                        Text(L(item.key)).font(.system(size: 12))
                    } icon: {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                    }
                }
            }
            Text(L("noFeatures.why"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L(appName == nil ? "noFeatures.whenAll" : "noFeatures.whenApp"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("install.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("noFeatures.confirm")) {
                    confirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
