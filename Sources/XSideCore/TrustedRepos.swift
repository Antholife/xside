import Foundation

/// A package repository XSide may download a missing tweak dependency from.
public struct TrustedRepo: Equatable, Sendable {
    public let id: String
    public let name: String
    /// `https`, ends with "/". `Filename` entries of its index must resolve under it.
    public let base: URL
    /// Folder of `Release` and the `Packages` index, relative to `base`; "" for flat repos.
    public let indexPath: String
    /// Package ids XSide offers from it (nothing else is ever looked up there).
    public let packages: Set<String>
}

/// The allowlist. Adding a repo is a code change with a review, never a setting: XSide trusts what
/// these hosts serve over HTTPS, checked through the Release -> Packages -> .deb hash chain
/// (`Release.gpg` is not checked: macOS has no GPG).
public enum TrustedRepos {
    public static let all: [TrustedRepo] = [
        // Cephei's official repo (checked 2026-11-09: Release has SHA512 and MD5, no SHA256).
        TrustedRepo(id: "chariz", name: "Chariz", base: URL(string: "https://repo.chariz.com/")!, indexPath: "",
                    packages: ["ws.hbang.common"]),
        // AltList's author's repo (checked 2026-11-09).
        TrustedRepo(id: "opa334", name: "opa334", base: URL(string: "https://opa334.github.io/")!, indexPath: "",
                    packages: ["com.opa334.altlist"]),
    ]

    public static func offering(_ packageID: String) -> [TrustedRepo] {
        let id = packageID.lowercased()
        return all.filter { $0.packages.contains(id) }
    }
}
