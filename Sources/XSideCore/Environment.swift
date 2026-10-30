import Foundation

public struct SigningEnvironment: Equatable, Sendable {
    public let developerDir: URL
    public let identitySHA1: String
    public let identityName: String
    public let teamID: String

    public init(developerDir: URL, identitySHA1: String, identityName: String, teamID: String) {
        self.developerDir = developerDir
        self.identitySHA1 = identitySHA1
        self.identityName = identityName
        self.teamID = teamID
    }
}

public struct EnvironmentProbe: Sendable {
    private let runner: CommandRunning
    private let fileExists: @Sendable (String) -> Bool
    /// Xcode's saved accounts (`DVTDeveloperAccountManagerAppleIDLists`), nil when unreadable.
    /// An undocumented key: when it's missing or unreadable, the account check is skipped.
    private let xcodeAccounts: @Sendable () -> Any?

    public init(runner: CommandRunning,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                xcodeAccounts: @escaping @Sendable () -> Any? = EnvironmentProbe.savedXcodeAccounts) {
        self.runner = runner
        self.fileExists = fileExists
        self.xcodeAccounts = xcodeAccounts
    }

    public static let savedXcodeAccounts: @Sendable () -> Any? = {
        // Xcode writes its preferences from another process: drop our cached copy first.
        CFPreferencesAppSynchronize("com.apple.dt.Xcode" as CFString)
        return CFPreferencesCopyAppValue("DVTDeveloperAccountManagerAppleIDLists" as CFString, "com.apple.dt.Xcode" as CFString)
    }

    /// Xcode's teams (`IDEProvisioningTeamByIdentifier`), nil when unreadable.
    public static let savedXcodeTeams: @Sendable () -> Any? = {
        CFPreferencesAppSynchronize("com.apple.dt.Xcode" as CFString)
        return CFPreferencesCopyAppValue("IDEProvisioningTeamByIdentifier" as CFString, "com.apple.dt.Xcode" as CFString)
    }

    /// The team to create a certificate for, with no certificate to read it from: the free
    /// "Personal Team" first, else the first team. `{account: [{teamID, isFreeProvisioningTeam…}]}`.
    public static func personalTeamID(_ teams: Any?) -> String? {
        guard let byAccount = teams as? [String: Any] else { return nil }
        let all = byAccount.values.flatMap { $0 as? [[String: Any]] ?? [] }
        let free = all.first { $0["isFreeProvisioningTeam"] as? Bool == true }
        return (free ?? all.first)?["teamID"] as? String
    }

    /// The Apple ID e-mail in a certificate name: "Apple Development: me@icloud.com (AB12CD34EF)".
    public static func appleID(fromIdentityName name: String) -> String? {
        guard let colon = name.firstIndex(of: ":") else { return nil }
        var rest = name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if let paren = rest.range(of: " (", options: .backwards) { rest = String(rest[..<paren.lowerBound]) }
        return rest.contains("@") ? rest : nil
    }

    /// The Personal Team's name ("Jane Appleseed"), shown when no certificate gives the e-mail.
    /// Xcode's preferences hold no e-mail (the account `identifier` is an internal UUID).
    public static func personalTeamName(_ teams: Any?) -> String? {
        guard let byAccount = teams as? [String: Any] else { return nil }
        let all = byAccount.values.flatMap { $0 as? [[String: Any]] ?? [] }
        let free = all.first { $0["isFreeProvisioningTeam"] as? Bool == true }
        return (free ?? all.first)?["teamName"] as? String
    }

    /// True when Xcode lists at least one account: `{"IDE.Identifiers.Prod": [{identifier: …}]}`,
    /// false when every list is empty, nil (unknown) when the key is missing or isn't a dictionary.
    public static func hasSignedInAccount(_ accounts: Any?) -> Bool? {
        guard let lists = accounts as? [String: Any] else { return nil }
        return lists.values.contains { ($0 as? [Any])?.isEmpty == false }
    }

    public func detect() async -> Result<SigningEnvironment, XSideError> {
        // 1. Selected Xcode developer directory.
        guard let xs = try? await runner.run("/usr/bin/xcode-select", ["-p"], cwd: nil), xs.status == 0 else {
            return .failure(.xcodeMissing)
        }
        let dirPath = String(decoding: xs.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dirPath.isEmpty else { return .failure(.xcodeMissing) }
        // Command Line Tools alone also answer `xcode-select -p`, but have no xcodebuild.
        guard fileExists(dirPath + "/usr/bin/xcodebuild") else { return .failure(.xcodeMissing) }

        // 2. An account signed in to Xcode. Checked before the certificate: signing out of Xcode
        // leaves the certificate in the keychain, yet nothing can be provisioned anymore.
        // Unknown (key moved in a new Xcode) isn't a failure: the certificate check decides.
        guard Self.hasSignedInAccount(xcodeAccounts()) != false else { return .failure(.xcodeNotSignedIn) }

        // 3. First "Apple Development" signing identity.
        let identity: (sha1: String, name: String)
        switch await signingIdentity() {
        case .success(let found): identity = found
        case .failure(let error): return .failure(error)
        }

        // 4. Team ID from the certificate subject's OU field.
        let command = "/usr/bin/security find-certificate -c \(Self.shellQuote(identity.name)) -p | /usr/bin/openssl x509 -noout -subject"
        let sub: CommandResult
        do {
            sub = try await runner.run("/bin/sh", ["-c", command], cwd: nil)
        } catch {
            return .failure(.commandFailed(tool: "openssl", status: -1))
        }
        guard sub.status == 0 else { return .failure(.commandFailed(tool: "openssl", status: sub.status)) }
        guard let team = Self.teamID(fromSubject: String(decoding: sub.stdout, as: UTF8.self)) else {
            return .failure(.noSigningIdentity)
        }
        LogStore.shared.register(team, as: "team")

        return .success(SigningEnvironment(
            developerDir: URL(fileURLWithPath: dirPath),
            identitySHA1: identity.sha1,
            identityName: identity.name,
            teamID: team))
    }

    /// The first "Apple Development" signing identity in the keychain. Also asked on its own when
    /// the account is signed out, to tell whether the certificate is missing too.
    public func signingIdentity() async -> Result<(sha1: String, name: String), XSideError> {
        let find: CommandResult
        do {
            find = try await runner.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], cwd: nil)
        } catch {
            return .failure(.commandFailed(tool: "security", status: -1))
        }
        guard find.status == 0 else { return .failure(.commandFailed(tool: "security", status: find.status)) }
        let identities = Self.parseIdentities(String(decoding: find.stdout, as: UTF8.self))
        guard let identity = identities.first(where: { $0.name.hasPrefix("Apple Development") }) else {
            return .failure(.noSigningIdentity)
        }
        // Masked before the next command logs the name.
        LogStore.shared.registerIdentity(name: identity.name, sha1: identity.sha1)
        return .success(identity)
    }

    /// Parses lines like `  1) <40-hex> "Name"` from `security find-identity`.
    public static func parseIdentities(_ output: String) -> [(sha1: String, name: String)] {
        var result: [(sha1: String, name: String)] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let paren = trimmed.firstIndex(of: ")"),
                  trimmed[trimmed.startIndex..<paren].allSatisfy(\.isNumber),
                  paren != trimmed.startIndex,
                  let q1 = trimmed.firstIndex(of: "\""),
                  let q2 = trimmed.lastIndex(of: "\""), q1 < q2 else { continue }
            let sha1 = trimmed[trimmed.index(after: paren)..<q1].trimmingCharacters(in: .whitespaces)
            guard !sha1.isEmpty, sha1.allSatisfy(\.isHexDigit) else { continue }
            result.append((sha1: sha1, name: String(trimmed[trimmed.index(after: q1)..<q2])))
        }
        return result
    }

    /// Extracts the `OU=` value from an openssl subject line (comma- or slash-separated).
    public static func teamID(fromSubject subject: String) -> String? {
        guard let r = subject.range(of: "OU=") else { return nil }
        let value = subject[r.upperBound...].prefix { $0 != "," && $0 != "/" && !$0.isNewline }
        let team = value.trimmingCharacters(in: .whitespaces)
        return team.isEmpty ? nil : team
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
