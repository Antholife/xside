import Testing
@testable import XSideCore

@Suite struct BackupVersionLabelTests {
    @Test func versionLabel_showsVWhenPresent_nilWhenAbsent() {
        #expect(BackupSnapshot.versionLabel("1.2.0") == "v1.2.0")
        #expect(BackupSnapshot.versionLabel(nil) == nil)
        #expect(BackupSnapshot.versionLabel("") == nil)
    }
}
