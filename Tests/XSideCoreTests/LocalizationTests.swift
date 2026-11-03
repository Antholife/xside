import Foundation
import Testing

/// The app's texts, checked against the source: every `L("key")` written in the code exists in
/// both languages, and a key takes the same arguments in English and in French (a missing key
/// shows its raw name on screen, a mismatched placeholder crashes or garbles the text).
struct LocalizationTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func table(_ language: String) throws -> [String: String] {
        let resources = root.appendingPathComponent("App/Resources/\(language).lproj")
        let data = try Data(contentsOf: resources.appendingPathComponent("Localizable.strings"))
        var table = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] ?? [:]
        let plurals = try Data(contentsOf: resources.appendingPathComponent("Localizable.stringsdict"))
        for key in (try PropertyListSerialization.propertyList(from: plurals, format: nil) as? [String: Any] ?? [:]).keys {
            table[key] = table[key] ?? "%ld" // plural entries take one count
        }
        return table
    }

    /// The literal keys passed to `L("…")` in the app's sources.
    private static func keysInCode() throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: #"\bL\("([A-Za-z0-9_.]+)""#)
        var keys: Set<String> = []
        let sources = root.appendingPathComponent("Sources")
        let walk = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = walk?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { keys.insert(String(text[range])) }
            }
        }
        return keys
    }

    /// The format specifiers of a text, in argument order ("%1$@ %2$d" -> ["@", "d"]).
    private static func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(?:l{0,2})([@dfsu])"#)
        let ns = text.replacingOccurrences(of: "%%", with: "") as NSString
        let matches = regex.matches(in: ns as String, range: NSRange(location: 0, length: ns.length))
        var positional: [(Int, String)] = []
        for (index, match) in matches.enumerated() {
            let number = match.range(at: 1).location == NSNotFound ? nil : Int(ns.substring(with: match.range(at: 1)))
            positional.append((number ?? index + 1, ns.substring(with: match.range(at: 2))))
        }
        return positional.sorted { $0.0 < $1.0 }.map(\.1)
    }

    @Test func everyKeyInTheCodeExistsInBothLanguages() throws {
        let en = try Self.table("en"), fr = try Self.table("fr")
        let keys = try Self.keysInCode()
        #expect(keys.count > 100) // the scan found the code
        #expect(keys.subtracting(en.keys).sorted() == [], "missing in English")
        #expect(keys.subtracting(fr.keys).sorted() == [], "missing in French")
    }

    @Test func bothLanguagesTakeTheSameArguments() throws {
        let en = try Self.table("en"), fr = try Self.table("fr")
        let mismatched = en.keys.filter { key in
            guard let french = fr[key] else { return false }
            return Self.placeholders(en[key]!) != Self.placeholders(french)
        }
        #expect(mismatched.sorted() == [])
    }
}
