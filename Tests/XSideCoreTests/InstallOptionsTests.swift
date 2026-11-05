import Foundation
import Testing
@testable import XSideCore

struct InstallOptionsTests {
    /// Apps installed before the welcome popup existed don't get it, even on their next refresh.
    @Test func welcomePopupIsOffForOldOptionsAndByDefault() throws {
        let old = try JSONDecoder().decode(InstallOptions.self, from: Data(#"{"fileSharing":true}"#.utf8))
        #expect(old.welcomePopup == false)
        #expect(InstallOptions().welcomePopup == false)
        let on = InstallOptions(welcomePopup: true)
        #expect(try JSONDecoder().decode(InstallOptions.self, from: JSONEncoder().encode(on)).welcomePopup)
    }
}
