import Testing
import Foundation
@testable import XSideCore

@Suite struct BackupBeforeUpdateTests {
    @Test func shouldBackUpBeforeUpdate_overrideElseDefault() {
        #expect(AppManagement.shouldBackUpBeforeUpdate(override: nil, default: true, backupData: nil))
        #expect(!AppManagement.shouldBackUpBeforeUpdate(override: nil, default: false, backupData: nil))
        #expect(!AppManagement.shouldBackUpBeforeUpdate(override: false, default: true, backupData: nil))
        #expect(AppManagement.shouldBackUpBeforeUpdate(override: true, default: false, backupData: nil))
    }

    @Test func backupDataOptOutRules() {
        #expect(!AppManagement.shouldBackUpBeforeUpdate(override: true, default: false, backupData: false))
        #expect(!AppManagement.shouldBackUpBeforeUpdate(override: true, default: true, backupData: false))
        #expect(!AppManagement.shouldBackUpBeforeUpdate(override: nil, default: true, backupData: false))
        #expect(!AppManagement.shouldBackUpBeforeUpdate(override: false, default: true, backupData: nil))
        #expect(AppManagement.shouldBackUpBeforeUpdate(override: nil, default: true, backupData: nil))
        #expect(AppManagement.shouldBackUpBeforeUpdate(override: nil, default: true, backupData: true))
    }

    @Test func optionsWithoutTheKeyStillLoad() throws {
        let o = try JSONDecoder().decode(InstallOptions.self, from: Data("{}".utf8))
        #expect(o.backupBeforeUpdate == nil)
    }
}
