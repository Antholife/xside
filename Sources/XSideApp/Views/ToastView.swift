import SwiftUI

/// The success banner at the bottom of a surface: non-interactive, it never blocks a click.
private struct ToastOverlay: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            ZStack {
                if let toast = model.toast {
                    Label(toast.text, systemImage: "checkmark.circle.fill")
                        .labelStyle(ToastLabelStyle())
                        .id(toast.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 16)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.25), value: model.toast?.id)
        }
    }
}

private struct ToastLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(.green)
            configuration.title
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}

extension View {
    func appToast(_ model: AppModel) -> some View { modifier(ToastOverlay(model: model)) }
}
