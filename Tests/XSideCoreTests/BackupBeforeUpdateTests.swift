import Testing
import Foundation
@testable import XSideCore

@Suite struct BackupBeforeUpdateTests {
    @Test func shouldBackUpBeforeUpdate_overrideElseDefault() {
        #expect(AppManagement.shouldBackUpBeforeUpdate(override: nil, default: true))
        #expect(!AppManagement.shouldBackUpBeforeUpdate(override: nil, default: false))
        #expect(!AppManagement.shouldBackUpBeforeUpdate(override: false, default: true))
        #expect(AppManagement.shouldBackUpBeforeUpdate(override: true, default: false))
    }

    @Test func optionsWithoutTheKeyStillLoad() throws {
        let o = try JSONDecoder().decode(InstallOptions.self, from: Data("{}".utf8))
        #expect(o.backupBeforeUpdate == nil)
    }
}
