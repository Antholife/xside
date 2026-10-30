import Testing
@testable import XSideCore

@Suite struct InstallTargetsTests {
    @Test func defaultsToDevicesThatHaveTheApp() {
        #expect(InstallTargets.defaultSelection(available: ["A", "B", "C"], installedOn: ["C", "A", "X"]) == ["A", "C"])
    }

    @Test func newAppDefaultsToFirstAvailable() {
        #expect(InstallTargets.defaultSelection(available: ["A", "B"], installedOn: []) == ["A"])
        #expect(InstallTargets.defaultSelection(available: ["A", "B"], installedOn: ["X"]) == ["A"])
        #expect(InstallTargets.defaultSelection(available: [], installedOn: ["X"]) == [])
    }

    @Test func untouchedSelectionFollowsTheDefault() {
        #expect(InstallTargets.reconcile(["A"], edited: false, available: ["A", "B"], installedOn: ["B"]) == ["B"])
        #expect(InstallTargets.reconcile(["B"], edited: false, available: ["A", "B"], installedOn: ["A", "B"]) == ["A", "B"])
    }

    @Test func untouchedSingleChoiceIsKeptWhileAvailable() {
        #expect(InstallTargets.reconcile(["B"], edited: false, available: ["A", "B"], installedOn: []) == ["B"])
        #expect(InstallTargets.reconcile(["B"], edited: false, available: ["A"], installedOn: []) == ["A"])
    }

    @Test func editedSelectionKeepsOrderAndDropsUnavailable() {
        #expect(InstallTargets.reconcile(["C", "A", "B"], edited: true, available: ["A", "C"], installedOn: ["B"]) == ["C", "A"])
    }

    @Test func editedSelectionLeftEmptyFallsBackToDefault() {
        #expect(InstallTargets.reconcile(["B"], edited: true, available: ["A"], installedOn: []) == ["A"])
    }

    @Test func selectionEmptiedByTheUserStaysEmpty() {
        #expect(InstallTargets.reconcile([], edited: true, available: ["A", "B"], installedOn: ["A"]) == [])
    }
}
