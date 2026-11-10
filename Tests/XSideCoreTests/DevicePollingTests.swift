import Testing
@testable import XSideCore

/// How often devices are listed: fast while the person is looking at them (the panel, or
/// Settings > Mes apps, where « Réessayer » waits for the device to be back), slow otherwise.
struct DevicePollingTests {
    @Test func fastWhileThePanelOrMyAppsShows() {
        #expect(DevicePolling.interval(panelOpen: true, myAppsShown: false) == DevicePolling.fast)
        #expect(DevicePolling.interval(panelOpen: false, myAppsShown: true) == DevicePolling.fast)
        #expect(DevicePolling.interval(panelOpen: true, myAppsShown: true) == DevicePolling.fast)
        #expect(DevicePolling.interval(panelOpen: false, myAppsShown: false) == DevicePolling.slow)
        #expect(DevicePolling.fast == .seconds(15) && DevicePolling.slow == .seconds(60))
    }
}
