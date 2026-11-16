import Testing
@testable import XSideCore

@Suite struct RestoreVersionWarningTests {
    @Test func warnsOnlyWhenBothKnownAndDiffer() {
        #expect(BackupSnapshot.restoreVersionWarning(snapshot: "1.2.0", installed: "1.1.0"))
        #expect(!BackupSnapshot.restoreVersionWarning(snapshot: "1.2.0", installed: "1.2.0"))
        #expect(!BackupSnapshot.restoreVersionWarning(snapshot: nil, installed: "1.2.0"))
        #expect(!BackupSnapshot.restoreVersionWarning(snapshot: "1.2.0", installed: nil))
        #expect(!BackupSnapshot.restoreVersionWarning(snapshot: nil, installed: nil))
        #expect(!BackupSnapshot.restoreVersionWarning(snapshot: "", installed: "1.2.0"))
        #expect(!BackupSnapshot.restoreVersionWarning(snapshot: "1.2.0", installed: ""))
    }
}
