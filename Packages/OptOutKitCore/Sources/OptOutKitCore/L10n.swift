import Foundation

/// Words the app shows that this package builds (step titles, reasons, labels, what a state's law means). The text lives in
/// `Resources/Localizable.xcstrings`; the English wording in the code is the key. The app sets `language` from the person's choice,
/// and it defaults to English so results never depend on the device (tests included).
///
/// Placeholders are `%@`, filled in order; a translation that needs another order writes `%2$@ ... %1$@`.
public enum L10n {
    /// A language code the package has a translation for ("en", "fr", "es", "de"). Anything else falls back to English.
    nonisolated(unsafe) public static var language = "en"

    public static let supported = ["en", "fr", "es", "de"]

    /// The compiled strings for a language (Xcode turns the catalog into `<lang>.lproj`), or nil when the build kept the raw catalog.
    static func bundle(for code: String) -> Bundle? {
        let base = code.split(separator: "-").first.map(String.init) ?? code
        if let path = Bundle.module.path(forResource: base, ofType: "lproj"), let b = Bundle(path: path) { return b }
        return nil
    }

    /// The raw catalog (`swift build` and `swift test` keep it as it is): key, then language, then text.
    private static let catalog: [String: [String: String]] = {
        guard let url = Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let strings = json["strings"] as? [String: [String: Any]] else { return [:] }
        var out: [String: [String: String]] = [:]
        for (key, entry) in strings {
            let loc = (entry["localizations"] as? [String: [String: Any]]) ?? [:]
            out[key] = loc.compactMapValues { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
        }
        return out
    }()

    /// The text for `key` in the current language, or the English key itself when there is no translation.
    public static func t(_ key: String) -> String {
        let base = language.split(separator: "-").first.map(String.init) ?? language
        if base == "en" { return key }
        if let b = bundle(for: base) {
            let v = b.localizedString(forKey: key, value: nil, table: nil)
            if v != key { return v }
        }
        return catalog[key]?[base] ?? key
    }

    /// Like `t`, with each `%@` replaced by the next argument.
    public static func f(_ key: String, _ args: Any...) -> String {
        let format = t(key)
        return String(format: format, locale: Locale(identifier: language), arguments: arguments(for: format, args))
    }

    /// A field name inside a sentence ("Add your email address"): lowercase, except in German where nouns keep their capital.
    public static func noun(_ key: String) -> String {
        let t = Self.t(key)
        return language.hasPrefix("de") ? t : t.lowercased()
    }

    /// A date for a person in the current language.
    /// Each argument matched to the placeholder that uses it: a whole number fills `%lld`, anything else is written out for `%@`.
    private static func arguments(for format: String, _ args: [Any]) -> [CVarArg] {
        var numeric = Set<Int>()
        var next = 0
        let regex = try! NSRegularExpression(pattern: "%(?:(\\d+)\\$)?(@|lld|ld|d)")
        for m in regex.matches(in: format, range: NSRange(format.startIndex..., in: format)) {
            let position = Range(m.range(at: 1), in: format).flatMap { Int(format[$0]) }.map { $0 - 1 } ?? next
            if Range(m.range(at: 2), in: format).map({ format[$0] != "@" }) == true { numeric.insert(position) }
            next += 1
        }
        // Never read past the arguments: a placeholder with no argument (a bad translation) gets an empty string instead of a crash.
        let wanted = max(next, (regex.matches(in: format, range: NSRange(format.startIndex..., in: format)).compactMap { m in
            Range(m.range(at: 1), in: format).flatMap { Int(format[$0]) } }.max() ?? 0))
        var padded = args
        while padded.count < wanted { padded.append("") }
        return padded.enumerated().map { i, a in
            if numeric.contains(i), let n = a as? Int { return Int64(n) }
            if numeric.contains(i), a is String { return Int64(0) }
            return String(describing: a) as NSString
        }
    }

    public static func date(_ d: Date) -> String {
        d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: language)))
    }
}
