import Foundation

/// How far the running step is (0...1), for the tools that can tell: the unzip and the signing
/// (`Resigner`), the transfer to the device (`Installer`, from `devicectl`'s own percentage).
/// Set by whoever shows it, for the job's task; nil (the default) reports nothing.
public enum StepProgress {
    @TaskLocal public static var report: (@Sendable (Double) -> Void)?

    /// Runs `body` with its progress mapped into `range` of the current one: a step made of parts.
    public static func within<T>(_ range: ClosedRange<Double>, _ body: () async throws -> T) async rethrows -> T {
        guard let outer = report else { return try await body() }
        return try await $report.withValue({ outer(range.lowerBound + (range.upperBound - range.lowerBound) * min(max($0, 0), 1)) }) {
            try await body()
        }
    }

    /// The last percentage in `text` ("Copying 42%" -> 0.42), nil when there is none.
    public static func lastPercent(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)\s?%"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let r = Range(match.range(at: 1), in: text), let value = Double(text[r]), value <= 100 else { return nil }
        return value / 100
    }
}

/// Lets a command's caller see its output as it comes (devicectl's progress), not only at the end.
public enum CommandOutput {
    @TaskLocal public static var onChunk: (@Sendable (String) -> Void)?
}
