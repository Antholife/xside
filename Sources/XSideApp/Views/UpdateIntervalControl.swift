import SwiftUI
import XSideCore

/// A unit for a custom update-check interval.
enum IntervalUnit: String, CaseIterable, Identifiable {
    case minutes, hours, days, months
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .minutes: 60
        case .hours: 3_600
        case .days: 86_400
        case .months: 2_592_000 // 30 days
        }
    }
    var label: String { L("update.interval.unit.\(rawValue)") }
}

/// Compact labels for an interval in seconds, used in the menus and summaries.
enum IntervalLabel {
    /// "6 h", "1 j", "1 sem.", "90 min", "2 mois", or "Jamais (manuel)" for `<= 0`.
    static func short(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return L("update.interval.never") }
        let m = Int((seconds / 60).rounded())
        if m % (60 * 24 * 30) == 0 { return "\(m / (60 * 24 * 30)) \(L("update.interval.unit.months"))" }
        if m % (60 * 24 * 7) == 0 { return L("update.interval.week", m / (60 * 24 * 7)) }
        if m % (60 * 24) == 0 { return "\(m / (60 * 24)) j" }
        if m % 60 == 0 { return "\(m / 60) h" }
        return "\(m) min"
    }

    /// The largest unit that divides the interval evenly, for seeding the custom editor.
    static func decompose(_ seconds: TimeInterval) -> (value: Int, unit: IntervalUnit) {
        let s = max(seconds, 60)
        for unit in [IntervalUnit.months, .days, .hours] where Int(s) % Int(unit.seconds) == 0 {
            return (Int(s / unit.seconds), unit)
        }
        return (max(1, Int(s / 60)), .minutes)
    }
}

/// Picks an update-check cadence: the presets, « Personnalisé » (a value + unit), and — for a
/// per-app override — « Réglage global » (`nil`) and « Jamais ». Binds to seconds (`nil` = global).
struct UpdateIntervalControl: View {
    @Binding var seconds: TimeInterval?
    var allowsGlobalDefault = false
    var allowsNever = false
    var globalDefaultSeconds: TimeInterval = UpdateSchedule.interval

    @State private var custom = false
    @State private var value = 1
    @State private var unit = IntervalUnit.days

    private static let presets: [TimeInterval] = [21_600, 86_400, 604_800] // 6 h, 1 day, 1 week

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                if allowsGlobalDefault {
                    Button(L("update.interval.global", IntervalLabel.short(globalDefaultSeconds))) { set(nil) }
                    Divider()
                }
                ForEach(Self.presets, id: \.self) { p in
                    Button(IntervalLabel.short(p)) { set(p) }
                }
                if allowsNever {
                    Button(L("update.interval.never")) { set(0) }
                }
                Divider()
                Button(L("update.interval.custom")) { startCustom() }
            } label: {
                Text(menuLabel).font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if custom {
                TextField("", value: $value, format: .number)
                    .frame(width: 44)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onChange(of: value) { _, _ in applyCustom() }
                Menu(unit.label) {
                    ForEach(IntervalUnit.allCases) { u in Button(u.label) { unit = u; applyCustom() } }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .onAppear { syncCustomState() }
    }

    private var menuLabel: String {
        if seconds == nil && allowsGlobalDefault { return L("update.interval.global", IntervalLabel.short(globalDefaultSeconds)) }
        return IntervalLabel.short(seconds ?? globalDefaultSeconds)
    }

    private func set(_ s: TimeInterval?) {
        custom = false
        seconds = s
    }

    private func startCustom() {
        custom = true
        let base = seconds ?? globalDefaultSeconds
        let d = IntervalLabel.decompose(base > 0 ? base : UpdateSchedule.interval)
        value = d.value
        unit = d.unit
        applyCustom()
    }

    private func applyCustom() {
        let v = max(1, value)
        if value != v { value = v }
        seconds = TimeInterval(v) * unit.seconds
    }

    /// On appear, show the custom editor when the current value isn't a preset / global / never.
    private func syncCustomState() {
        guard let s = seconds else { custom = false; return }
        if s <= 0 { custom = false; return }
        if Self.presets.contains(s) { custom = false; return }
        custom = true
        let d = IntervalLabel.decompose(s)
        value = d.value
        unit = d.unit
    }
}
