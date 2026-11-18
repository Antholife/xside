import Testing
import Foundation
@testable import XSideCore

/// `copyTargets` groups a container's files into the fewest devicectl copies: a whole directory in
/// one call wherever no excluded subtree (caches, tmp) lies within it, so an app with hundreds of
/// tiny files is pulled in a handful of calls instead of one per file.
@Suite struct BackupCopyTargetsTests {
    private func file(_ path: String, _ size: Int) -> ContainerEntry {
        ContainerEntry(relativePath: path, isDirectory: false, size: size, modified: nil)
    }
    private func dir(_ path: String) -> ContainerEntry {
        ContainerEntry(relativePath: path, isDirectory: true, size: nil, modified: nil)
    }

    @Test func groupsCleanDirectoriesDescendsExcludedAncestorsKeepsTopLevelFiles() {
        let entries = [
            dir("Documents"), file("Documents/a", 1), file("Documents/sub/b", 2),
            dir("Library"), dir("Library/Preferences"), file("Library/Preferences/p", 3),
            file("Library/Caches/c", 99),  // excluded
            file("tmp/x", 5),              // excluded
            file("top.plist", 7),          // a file directly under the (split) root
        ]
        let targets = BackupService.copyTargets(entries, excluded: ["tmp/", "Library/Caches/"])
        #expect(targets == [
            BackupService.CopyTarget(path: "Documents/", isDirectory: true, files: 2, bytes: 3),
            BackupService.CopyTarget(path: "Library/Preferences/", isDirectory: true, files: 1, bytes: 3),
            BackupService.CopyTarget(path: "top.plist", isDirectory: false, files: 1, bytes: 7),
        ])
    }

    @Test func wholeRootWhenNothingExcludedWithin() {
        // includeCaches on, no tmp in the tree: the root itself has no excluded subtree, one copy.
        let entries = [file("Documents/a", 1), file("Library/Caches/c", 2)]
        let targets = BackupService.copyTargets(entries, excluded: [])
        #expect(targets == [BackupService.CopyTarget(path: "", isDirectory: true, files: 2, bytes: 3)])
    }

    @Test func excludedFilesNeverProduceATarget() {
        let entries = [file("tmp/a", 1), file("Library/Caches/b", 2)]
        #expect(BackupService.copyTargets(entries, excluded: ["tmp/", "Library/Caches/"]).isEmpty)
    }
}
