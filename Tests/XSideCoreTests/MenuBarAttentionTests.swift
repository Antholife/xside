import Foundation
import Testing
@testable import XSideCore

/// Device round 2, item 13: the menu-bar dot says something needs a look, and why.
struct MenuBarAttentionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func inst(_ dev: String = "D1", expiresIn: TimeInterval, error: String? = nil, paused: Bool = false,
                      results: [String: TweakResult]? = nil) -> Installation {
        Installation(deviceID: dev, installedAt: now.addingTimeInterval(-day), expiresAt: now.addingTimeInterval(expiresIn),
                     lastErrorKey: error, refreshPaused: paused, tweakResults: results)
    }

    private func record(_ installs: [Installation]) -> AppRecord {
        AppRecord(id: UUID(), displayName: "App", originalBundleID: "com.x", signedBundleID: "com.x.t",
                  ipaPath: "a.ipa", options: InstallOptions(), installations: installs, teamID: "T")
    }

    private func reasons(_ records: [AppRecord], crashes: Int = 0, environment: MenuBarAttention.Environment = .ok,
                         libraryIssue: Bool = false) -> [MenuBarAttention.Reason] {
        MenuBarAttention.reasons(records: records, now: now, threshold: 2 * day, flaggedCrashes: crashes,
                                 environment: environment, libraryIssue: libraryIssue)
    }

    @Test func nothingWrongNoDot() {
        #expect(reasons([record([inst(expiresIn: 6 * day)])]).isEmpty)
        #expect(MenuBarAttention.level(of: []) == nil)
    }

    @Test func eachReasonIsNamedOnceAndClearedWhenResolved() {
        let failed = record([inst(expiresIn: 6 * day, error: "deviceLocked")])
        #expect(reasons([failed]) == [.refreshFailed])
        let soon = record([inst(expiresIn: 1 * day, error: "deviceLocked")])
        #expect(reasons([soon]) == [.expiringSoon, .refreshFailed])
        let expired = record([inst(expiresIn: -60)])
        #expect(reasons([expired]) == [.expired])
        #expect(MenuBarAttention.level(of: [.expired]) == .critical)
        let skipped = record([inst(expiresIn: 6 * day,
                                   results: ["a": .skipped(.incompatible(.missingDependency("Cephei"))), "b": .injected(converted: false)])])
        #expect(reasons([skipped]) == [.tweakProblem])
        #expect(reasons([], crashes: 2) == [.crash])
        #expect(reasons([], environment: .certificate) == [.certificate])
        #expect(MenuBarAttention.level(of: [.certificate]) == .critical)
        #expect(reasons([], environment: .checkFailed, libraryIssue: true) == [.setupCheck, .libraryIssue])
        #expect(MenuBarAttention.level(of: [.crash]) == .warning)
        // Resolved: the next signing injected it, the refresh succeeded.
        #expect(reasons([record([inst(expiresIn: 6 * day, results: ["a": .injected(converted: true)])])]).isEmpty)
    }

    @Test func aPausedInstallationIsTheGivenUpOnes() {
        let paused = record([inst(expiresIn: -60, error: "x", paused: true,
                                  results: ["a": .skipped(.failed)])])
        #expect(reasons([paused]).isEmpty)
    }
}
