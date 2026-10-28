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

    public init(runner: CommandRunning) {
        self.runner = runner
    }

    public func detect() async -> Result<SigningEnvironment, XSideError> {
        // 1. Selected Xcode developer directory.
        guard let xs = try? await runner.run("/usr/bin/xcode-select", ["-p"], cwd: nil), xs.status == 0 else {
            return .failure(.xcodeMissing)
        }
        let dirPath = String(decoding: xs.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dirPath.isEmpty else { return .failure(.xcodeMissing) }

        // 2. First "Apple Development" signing identity.
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

        // 3. Team ID from the certificate subject's OU field.
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

        return .success(SigningEnvironment(
            developerDir: URL(fileURLWithPath: dirPath),
            identitySHA1: identity.sha1,
            identityName: identity.name,
            teamID: team))
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
