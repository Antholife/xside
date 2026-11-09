import Foundation

/// One entry of a `Depends:` alternative group, e.g. `firmware (>= 15.0)`.
public struct DebDependency: Codable, Equatable, Sendable {
    /// Lowercased, architecture qualifier removed.
    public var package: String
    /// One of `>=`, `<=`, `>>`, `<<`, `=`; nil when any version will do.
    public var relation: String?
    public var version: String?

    public init(package: String, relation: String? = nil, version: String? = nil) {
        self.package = package
        self.relation = relation
        self.version = version
    }

    public func isSatisfied(by installed: String) -> Bool {
        guard let relation, let version else { return true }
        let c = DebVersion.compare(installed, version)
        switch relation {
        case ">=": return c != .orderedAscending
        case "<=": return c != .orderedDescending
        case ">>": return c == .orderedDescending
        case "<<": return c == .orderedAscending
        case "=": return c == .orderedSame
        default: return true
        }
    }
}

public enum ControlLimits {
    public static let maxFields = 256
    public static let maxFieldBytes = 32 * 1024
    public static let maxGroups = 512
    public static let maxAlternatives = 64
    public static let maxProvides = 512
    public static let maxFilterStrings = 512
    public static let maxFilterStringBytes = 1024
}

/// The fields of a `.deb` control file (or of one stanza of a repo `Packages` file) that XSide uses.
public struct DebControl: Codable, Equatable, Sendable {
    public var package: String
    public var name: String?
    public var version: String?
    /// Name only: `Jane <j@x.y>` becomes `Jane`.
    public var author: String?
    public var architecture: String?
    /// AND of ORs: each inner array is one group of alternatives.
    public var depends: [[DebDependency]]
    public var provides: [String]

    public init(package: String, name: String? = nil, version: String? = nil, author: String? = nil,
                architecture: String? = nil, depends: [[DebDependency]] = [], provides: [String] = []) {
        self.package = package
        self.name = name
        self.version = version
        self.author = author
        self.architecture = architecture
        self.depends = depends
        self.provides = provides
    }

    public static func parse(_ text: String) throws -> DebControl {
        guard text.utf8.count <= DebLimits.maxControlFileBytes else { throw DebError.tooLarge }
        // A control file is a single stanza; ignore anything after the first blank line.
        let fields = try stanzas(text, maxStanzas: 50_000, firstOnly: true).first ?? [:]
        return try make(fields)
    }

    /// Builds a control from one stanza returned by `stanzas`.
    public static func make(_ fields: [String: String]) throws -> DebControl {
        guard let package = fields["package"]?.lowercased(), !package.isEmpty else {
            throw DebError.malformed("control has no Package")
        }
        func nonEmpty(_ key: String) -> String? {
            guard let v = fields[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
            return v
        }
        var author = nonEmpty("author")
        if let a = author, let lt = a.firstIndex(of: "<") {
            let n = a[..<lt].trimmingCharacters(in: .whitespaces)
            author = n.isEmpty ? nil : n
        }
        return DebControl(package: package, name: nonEmpty("name"), version: nonEmpty("version"),
                          author: author, architecture: nonEmpty("architecture"),
                          depends: parseDepends(fields["depends"] ?? ""),
                          provides: parseProvides(fields["provides"] ?? ""))
    }

    /// Splits RFC 822-style stanzas separated by blank lines. Keys are lowercased; continuation
    /// lines (leading space or tab) are joined with a newline; control and format characters are
    /// stripped. Caps: `maxStanzas`, fields per stanza, bytes per field; extra fields are dropped.
    public static func stanzas(_ text: String, maxStanzas: Int = 50_000) throws -> [[String: String]] {
        try stanzas(text, maxStanzas: maxStanzas, firstOnly: false)
    }

    private static func stanzas(_ text: String, maxStanzas: Int, firstOnly: Bool) throws -> [[String: String]] {
        var result: [[String: String]] = []
        var current: [String: String] = [:]
        var lastKey: String?
        func flush() throws {
            if !current.isEmpty {
                if result.count >= maxStanzas { throw DebError.tooLarge }
                result.append(current)
            }
            current = [:]
            lastKey = nil
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = Substring(sanitized(String(rawLine.prefix(ControlLimits.maxFieldBytes))))
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                try flush()
                if firstOnly, !result.isEmpty { return result }
                continue
            }
            if line.hasPrefix("#") { continue }
            if line.first == " " || line.first == "\t" {
                if let key = lastKey, let old = current[key], old.utf8.count < ControlLimits.maxFieldBytes {
                    current[key] = old + "\n" + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { lastKey = nil; continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, !key.contains(" ") else { lastKey = nil; continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if current[key] == nil && current.count >= ControlLimits.maxFields { lastKey = nil; continue }
            if current[key] == nil { current[key] = value }
            lastKey = current[key] == value ? key : nil
        }
        try flush()
        return result
    }

    /// Tabs become spaces; other control, format and line/paragraph separator characters go.
    private static func sanitized(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u == "\t" || u == " " { out.append(u); continue }
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                continue
            default: out.append(u)
            }
        }
        return String(out)
    }

    static func parseDepends(_ value: String) -> [[DebDependency]] {
        var groups: [[DebDependency]] = []
        for part in value.replacingOccurrences(of: "\n", with: " ").split(separator: ",") {
            if groups.count >= ControlLimits.maxGroups { break }
            var alternatives: [DebDependency] = []
            for alt in part.split(separator: "|") {
                if alternatives.count >= ControlLimits.maxAlternatives { break }
                if let dep = parseDependency(String(alt)) { alternatives.append(dep) }
            }
            if !alternatives.isEmpty { groups.append(alternatives) }
        }
        return groups
    }

    private static func parseDependency(_ s: String) -> DebDependency? {
        var rest = s.trimmingCharacters(in: .whitespaces)
        var constraint: String?
        if let o = rest.firstIndex(of: "(") {
            if let c = rest[o...].firstIndex(of: ")") {
                constraint = String(rest[rest.index(after: o)..<c]).trimmingCharacters(in: .whitespaces)
            }
            rest = String(rest[..<o])
        }
        // Drop [arch] restrictions glued to the name.
        if let o = rest.firstIndex(of: "[") { rest = String(rest[..<o]) }
        var name = rest.trimmingCharacters(in: .whitespaces).lowercased()
        if let colon = name.firstIndex(of: ":") { name = String(name[..<colon]) }
        guard !name.isEmpty, !name.contains(" ") else { return nil }
        guard let constraint, !constraint.isEmpty else { return DebDependency(package: name) }
        let ops = [">=", "<=", ">>", "<<", "=", ">", "<"]
        guard let op = ops.first(where: { constraint.hasPrefix($0) }) else { return DebDependency(package: name) }
        let version = constraint.dropFirst(op.count).trimmingCharacters(in: .whitespaces)
        guard !version.isEmpty, !version.contains(" ") else { return DebDependency(package: name) }
        // Deprecated single-character forms mean "or equal".
        let relation = op == ">" ? ">=" : op == "<" ? "<=" : op
        return DebDependency(package: name, relation: relation, version: version)
    }

    static func parseProvides(_ value: String) -> [String] {
        var out: [String] = []
        for part in value.replacingOccurrences(of: "\n", with: " ").split(separator: ",") {
            if out.count >= ControlLimits.maxProvides { break }
            var n = part.trimmingCharacters(in: .whitespaces).lowercased()
            if let o = n.firstIndex(of: "(") { n = String(n[..<o]).trimmingCharacters(in: .whitespaces) }
            if let colon = n.firstIndex(of: ":") { n = String(n[..<colon]) }
            if !n.isEmpty, !n.contains(" ") { out.append(n) }
        }
        return out
    }

    /// The iOS range a package asks for through `firmware (>= x)` / `firmware (<< y)`. When several
    /// bounds appear the tightest wins. `<=` and `>>` bounds are not representable and are ignored.
    public static func firmwareRange(_ depends: [[DebDependency]]) -> (min: String?, belowMax: String?) {
        var min: String?, belowMax: String?
        for group in depends where group.count == 1 {
            let d = group[0]
            guard d.package == "firmware", let rel = d.relation, let v = d.version else { continue }
            if rel == ">=" || rel == "=" {
                if min == nil || DebVersion.compare(v, min!) == .orderedDescending { min = v }
            }
            if rel == "<<" {
                if belowMax == nil || DebVersion.compare(v, belowMax!) == .orderedAscending { belowMax = v }
            }
        }
        return (min, belowMax)
    }
}

/// A tweak's `.plist` filter: which bundles, executables or classes it hooks.
public struct TweakFilter: Codable, Equatable, Sendable {
    public var bundles: [String]
    public var executables: [String]
    public var classes: [String]
    /// `Mode = Any`: the tweak loads when any one of the entries matches (default is all).
    public var anyMode: Bool

    public init(bundles: [String] = [], executables: [String] = [], classes: [String] = [], anyMode: Bool = false) {
        self.bundles = bundles
        self.executables = executables
        self.classes = classes
        self.anyMode = anyMode
    }

    /// Reads XML, binary or OpenStep plists. nil when too large or not a dictionary; non-string
    /// entries are skipped and each list is capped.
    public static func parse(_ data: Data) -> TweakFilter? {
        guard data.count <= DebLimits.maxPlistBytes,
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        let filter = root["Filter"] as? [String: Any] ?? [:]
        func strings(_ key: String) -> [String] {
            guard let list = filter[key] as? [Any] else { return [] }
            var out: [String] = []
            for item in list {
                guard let s = item as? String, s.utf8.count <= ControlLimits.maxFilterStringBytes else { continue }
                out.append(s)
                if out.count >= ControlLimits.maxFilterStrings { break }
            }
            return out
        }
        let mode = (filter["Mode"] as? String)?.lowercased()
        return TweakFilter(bundles: strings("Bundles"), executables: strings("Executables"),
                           classes: strings("Classes"), anyMode: mode == "any")
    }
}

/// What XSide knows about packages tweaks commonly depend on.
public enum KnownDependency: Equatable, Sendable {
    /// Substrate-style hooking frameworks: satisfied by XSide's own hooking layer.
    case hooking
    /// Dependencies with nothing to install (`firmware`, `cy+…`, `gsc.…`).
    case ignored
    /// PreferenceLoader: handled by turning the tweak's preferences into a settings page.
    case settings
    /// Needs a jailbreak; the string is its display name.
    case jailbreakOnly(String)
    /// A library the user can supply (or XSide embeds); the string is its display name.
    case library(String)

    public static func role(of package: String) -> KnownDependency? {
        let p = package.lowercased()
        if p.hasPrefix("cy+") || p.hasPrefix("gsc.") { return .ignored }
        switch p {
        case "mobilesubstrate", "com.saurik.substrate", "org.coolstar.libhooker", "com.ex.substitute",
             "com.ex.libsubstitute", "ellekit": return .hooking
        case "firmware": return .ignored
        case "preferenceloader": return .settings
        case "com.rpetrich.rocketbootstrap": return .jailbreakOnly("RocketBootstrap")
        case "libactivator": return .jailbreakOnly("Activator")
        case "com.muirey03.libmryipc": return .jailbreakOnly("libMRYIPC")
        case "applist": return .jailbreakOnly("AppList")
        case "com.opa334.libsandy": return .jailbreakOnly("libSandy")
        case "ws.hbang.common": return .library("Cephei")
        case "com.opa334.altlist": return .library("AltList")
        case "libroot", "com.opa334.libroot": return .library("libroot")
        case "com.mrgcgamer.libgcuniversal": return .library("libGCUniversal")
        default: return nil
        }
    }
}
