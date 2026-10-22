import Foundation

/// The app's own words for strings that are built in code (status messages, labels, explanations). SwiftUI literals such as
/// `Text("Next")` are localized by SwiftUI itself from the environment's locale; this does the same for everything else, in the
/// language the person chose. The English wording is the key. Placeholders are `%@`, filled in order.
enum Loc {
    nonisolated(unsafe) static var language = "en"

    private static func bundle() -> Bundle {
        let base = language.split(separator: "-").first.map(String.init) ?? language
        if let path = Bundle.main.path(forResource: base, ofType: "lproj"), let b = Bundle(path: path) { return b }
        return Bundle.main
    }

    static func t(_ key: String) -> String { bundle().localizedString(forKey: key, value: key, table: nil) }

    static func f(_ key: String, _ args: Any...) -> String {
        let format = t(key)
        return String(format: format, locale: Locale(identifier: language), arguments: arguments(for: format, args))
    }

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

    static func date(_ d: Date, time: Bool = false) -> String {
        d.formatted(Date.FormatStyle(date: .abbreviated, time: time ? .shortened : .omitted).locale(Locale(identifier: language)))
    }
}
