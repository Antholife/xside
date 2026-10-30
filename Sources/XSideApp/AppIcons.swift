import AppKit
import Observation
import XSideCore

/// The icon of each app, shown in the popover: the custom icon chosen in the options, else the
/// app's own, kept as `<library>/icons/<record id>.png`. Apps imported before icons were kept get
/// theirs from their stored .ipa, once, in the background.
@MainActor @Observable
final class AppIcons {
    private static let log = Log("icons")

    @ObservationIgnored private let library: AppLibrary
    @ObservationIgnored private let runner: CommandRunning
    /// Bumped when an icon appears: rows read it to load the new file.
    private(set) var revision = 0
    @ObservationIgnored private var images: [URL: NSImage] = [:]
    @ObservationIgnored private var backfilling = false

    init(library: AppLibrary, runner: CommandRunning) {
        self.library = library
        self.runner = runner
    }

    private var directory: URL { library.root.appendingPathComponent("icons", isDirectory: true) }

    private func file(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).png") }

    func image(for record: AppRecord) -> NSImage? {
        _ = revision
        let candidates = [record.options.iconPath.flatMap { $0.isEmpty ? nil : library.root.appendingPathComponent($0) },
                          file(for: record.id)].compactMap { $0 }
        for url in candidates {
            if let cached = images[url] { return cached }
            if let image = NSImage(contentsOf: url) {
                images[url] = image
                return image
            }
        }
        return nil
    }

    /// Keeps the icon extracted when the .ipa was opened.
    func keep(_ extracted: URL, for id: UUID) {
        let destination = file(for: id)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: extracted, to: destination)
            images[destination] = nil
            revision += 1
        } catch {
            Self.log.error("keeping the icon of \(id) failed: \(error)")
        }
    }

    /// Extracts the missing icons from the stored .ipa files, one at a time, and deletes those of
    /// apps no longer in the library. An app without an icon gets one try per launch.
    func backfill(_ records: [AppRecord]) {
        guard !backfilling, !records.isEmpty else { return }
        backfilling = true
        let fm = FileManager.default
        let known = Set(records.map { file(for: $0.id).lastPathComponent })
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where !known.contains(name) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        let missing = records.filter { !fm.fileExists(atPath: file(for: $0.id).path) }
        guard !missing.isEmpty, let helper = Bundle.main.executableURL else { return }
        Task(priority: .utility) {
            for record in missing {
                let ipa = library.root.appendingPathComponent(record.ipaPath)
                let destination = fm.temporaryDirectory.appendingPathComponent("xside-icon-\(UUID().uuidString).png")
                defer { try? fm.removeItem(at: destination) }
                _ = try? await IPAImporter.inspect(ipa: ipa, runner: runner, iconDestination: destination, iconHelper: helper)
                if fm.fileExists(atPath: destination.path) { keep(destination, for: record.id) }
            }
        }
    }
}
