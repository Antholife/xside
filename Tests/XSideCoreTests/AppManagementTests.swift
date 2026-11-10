import Testing
@testable import XSideCore

/// Settings > Mes apps' « ⋯ » menu and its bottom zone: what they offer, why they're greyed, and
/// which app the page shows once the one shown is uninstalled or removed from the list.
struct AppManagementTests {
    @Test func menuOffersPauseAndStopWhileRefreshing() {
        #expect(AppManagement.menu(isPaused: false)
                == [.refresh, .pause, .stop, .separator, .ipaContent, .separator, .removeFromList, .uninstall])
    }

    @Test func menuOffersResumeOnceStoppedOrPaused() {
        #expect(AppManagement.menu(isPaused: true)
                == [.refresh, .resume, .separator, .ipaContent, .separator, .removeFromList, .uninstall])
    }

    @Test func nothingBlocksAnIdleRow() {
        #expect(AppManagement.block(jobRunning: false, uninstalling: false, removingDevice: false) == nil)
    }

    @Test func uninstallingIsSaidBeforeAnyOtherJob() {
        // An uninstall claims the row too: the reason names it, not "a refresh".
        #expect(AppManagement.block(jobRunning: true, uninstalling: true, removingDevice: false) == .uninstalling)
        #expect(AppManagement.block(jobRunning: false, uninstalling: true, removingDevice: false) == .uninstalling)
        #expect(AppManagement.block(jobRunning: true, uninstalling: false, removingDevice: false) == .jobRunning)
        #expect(AppManagement.block(jobRunning: false, uninstalling: false, removingDevice: true) == .removingDevice)
        #expect(AppManagement.block(jobRunning: true, uninstalling: false, removingDevice: true) == .removingDevice)
    }

    @Test func nextAppOnTheDeviceAfterTheOneGone() {
        #expect(AppManagement.selection(afterRemoving: "b", from: ["a", "b", "c"]) == "c")
        #expect(AppManagement.selection(afterRemoving: "a", from: ["a", "b", "c"]) == "b")
    }

    @Test func theOneBeforeWhenTheLastGoes() {
        #expect(AppManagement.selection(afterRemoving: "c", from: ["a", "b", "c"]) == "b")
    }

    @Test func nothingWhenTheDeviceHasNoOtherApp() {
        #expect(AppManagement.selection(afterRemoving: "a", from: ["a"]) == nil)
        #expect(AppManagement.selection(afterRemoving: "a", from: [String]()) == nil)
    }

    @Test func anAppNotListedLeavesTheFirst() {
        // Already gone from the list (reloaded meanwhile): the device's first app.
        #expect(AppManagement.selection(afterRemoving: "z", from: ["a", "b"]) == "a")
    }
}
