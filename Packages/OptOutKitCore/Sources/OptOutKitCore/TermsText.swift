import Foundation
import CryptoKit

/// Canonical form of terms text. This MUST match tools/terms_canon.py exactly: both are tested against
/// terms/canonicalization-fixtures.json. Change one and the fixtures fail until the other changes with it.
///
/// Steps: Unicode NFKC and lowercase; curly quotes and dashes to ASCII; whitespace collapsed; any web address becomes
/// {domain}; the site's own name becomes {site}; US state names and the site's short prefix become {state}; four-digit
/// years 1990-2039 become {year}; "(c)" and the copyright sign are dropped.
public enum TermsText {
    static let states = ["alabama", "alaska", "arizona", "arkansas", "california", "colorado", "connecticut", "delaware",
        "district of columbia", "florida", "georgia", "hawaii", "idaho", "illinois", "indiana", "iowa", "kansas", "kentucky",
        "louisiana", "maine", "maryland", "massachusetts", "michigan", "minnesota", "mississippi", "missouri", "montana",
        "nebraska", "nevada", "new hampshire", "new jersey", "new mexico", "new york", "north carolina", "north dakota",
        "ohio", "oklahoma", "oregon", "pennsylvania", "rhode island", "south carolina", "south dakota", "tennessee", "texas",
        "utah", "vermont", "virginia", "washington", "west virginia", "wisconsin", "wyoming"]
    static let suffixes = ["courtrecords", "arrestwarrants", "warrantroundup", "arrests", "arrest", "warrants", "records", "residentdatabase"]
    public static let minWords = 12

    private static func normalize(_ text: String) -> String {
        var t = text.precomposedStringWithCompatibilityMapping.lowercased()
        for (from, to) in [("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2013}", "-"), ("\u{2014}", "-")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        return collapse(t)
    }

    private static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func siteTokens(_ domain: String) -> (names: [String], prefix: String?) {
        let label = domain.lowercased().split(separator: ".").first.map(String.init) ?? domain.lowercased()
        var names: Set<String> = [label]
        var prefix: String?
        for suffix in suffixes where label.hasSuffix(suffix) && label.count > suffix.count {
            prefix = String(label.dropLast(suffix.count))
            names.insert("\(prefix!) \(suffix)")
            break
        }
        return (names.sorted { ($0.count, $1) > ($1.count, $0) }, prefix)
    }

    public static func canonical(_ paragraph: String, domain: String) -> String {
        var t = normalize(paragraph)
        t = t.replacingOccurrences(of: "\\b(?:www\\.)?[a-z0-9][a-z0-9-]*\\.(?:org|com|net|us|gov|edu|io|info)\\b",
                                   with: "{domain}", options: .regularExpression)
        let (names, prefix) = siteTokens(domain)
        for n in names { t = t.replacingOccurrences(of: n, with: "{site}") }
        for st in states.sorted(by: { ($0.count, $0) > ($1.count, $1) }) { t = t.replacingOccurrences(of: st, with: "{state}") }
        if let prefix, prefix.count <= 3 {
            t = t.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: prefix))\\b", with: "{state}", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: "\\b(?:199[0-9]|20[0-3][0-9])\\b", with: "{year}", options: .regularExpression)
        t = t.replacingOccurrences(of: "(c)", with: "").replacingOccurrences(of: "\u{00A9}", with: "")
        t = t.replacingOccurrences(of: "(\\{state\\} ?){2,}", with: "{state} ", options: .regularExpression)
        return collapse(t)
    }

    public static func hash(ofCanonical canonical: String) -> String {
        SHA256.hash(data: Data(canonical.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Paragraphs with at least `minWords` words; shorter lines are menus, buttons and footers.
    public static func substantial(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.split(whereSeparator: { $0.isWhitespace }).count >= minWords }
    }

    /// Hashes of a document's substantial paragraphs, for comparison with a reviewed set.
    public static func paragraphHashes(_ text: String, domain: String) -> Set<String> {
        Set(substantial(text).map { hash(ofCanonical: canonical($0, domain: domain)) })
    }
}
