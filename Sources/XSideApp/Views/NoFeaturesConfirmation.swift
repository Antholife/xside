import AppKit
import SwiftUI
import XSideCore

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
