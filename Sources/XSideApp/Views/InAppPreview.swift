import AppKit
import SwiftUI
import XSideCore

/// ⓘ next to an option: a popover with what it looks like on the iPhone.
struct PreviewButton: View {
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
