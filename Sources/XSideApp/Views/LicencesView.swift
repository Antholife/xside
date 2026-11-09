import SwiftUI

/// About > « Licences tierces »: `Acknowledgements.txt` from the app's Resources (written by
/// `scripts/bundle.sh`: zstd, ElleKit, Cephei with its « Changes made by XSide », AltList, libroot).
/// Long legal text: scrollable, monospaced, selectable.
struct LicencesView: View {
    let onClose: () -> Void
    var text: String? = LicencesView.acknowledgements()

    /// The file's text, nil when this build has none (or it is empty).
    static func acknowledgements(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "Acknowledgements", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("about.licences.title")).font(.headline)
                Spacer()
                Button(L("about.licences.close"), action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            if let text {
                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            } else {
                Text(L("about.licences.none"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(14)
            }
        }
        .frame(width: 560, height: 480)
    }
}
