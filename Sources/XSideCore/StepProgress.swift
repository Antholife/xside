import Foundation

/// How far the running step is (0...1), for the tools that can tell: the unzip and the signing
/// (`Resigner`). The transfer to the device can't: devicectl reports nothing until it's done.
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
}
