import AppKit
import SwiftUI
import XSideCore

/// Asked before an app (or every app) goes without XSide's features: what's lost, why it's
/// useful, when it applies.
struct NoFeaturesConfirmation: View {
    /// nil: the Mac-wide setting.
    let appName: String?
    /// Offers deleting the app from the device first (an installation of it has XSide's module):
    /// iOS keeps XSide's quick actions across an update, and nothing is left in the app to remove
    /// them. Never for every app at once: one checkbox must not wipe every app's data.
    var offersDeleteFirst = false
    /// Called with the "delete first" choice (always false when not offered).
    let confirm: (_ deleteFirst: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Off by default: deleting loses the app's data on the device.
    @State private var deleteFirst = false

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
            // Mega review Important 1: said whether or not iOS turns out to keep them.
            Text(L("noFeatures.quickStay"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if offersDeleteFirst {
                Toggle(isOn: $deleteFirst) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("noFeatures.deleteFirst")).font(.system(size: 12))
                        Text(L("noFeatures.deleteFirst.note"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button(L("install.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("noFeatures.confirm")) {
                    confirm(offersDeleteFirst && deleteFirst)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
