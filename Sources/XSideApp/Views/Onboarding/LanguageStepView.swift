import SwiftUI

/// Step 0: the app language, applied at once to the whole journey (the root re-renders on `language`).
struct LanguageStepView: View {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

    var body: some View {
        JourneyPage(symbol: "globe", title: L("journey.language.title"), subtitle: L("journey.language.subtitle")) {
            VStack(spacing: 10) {
                option(.system, symbol: "gearshape", label: L("settings.language.system"))
                option(.en, symbol: "textformat", label: L("settings.language.en"))
                option(.fr, symbol: "textformat", label: L("settings.language.fr"))
            }
        }
    }

    private func option(_ value: AppLanguage, symbol: String, label: String) -> some View {
        let selected = language == value.rawValue
        return Button { language = value.rawValue } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 40, height: 40)
                    .background(Theme.violet.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(label).font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.primary.opacity(0.25)))
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.primary.opacity(0.06)),
                              lineWidth: selected ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.smooth(duration: 0.2), value: selected)
    }
}
