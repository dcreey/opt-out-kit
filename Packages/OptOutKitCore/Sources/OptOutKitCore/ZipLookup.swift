import Foundation

/// The place a US ZIP code belongs to, from a table bundled with the app (so what is typed never leaves the phone). Data: GeoNames postal codes,
/// geonames.org, Creative Commons Attribution 4.0; 40,977 ZIP codes of the fifty states and DC (military and territory codes are left out).
public enum ZipLookup {
    public struct Place: Equatable, Sendable { public let city: String; public let state: String }

    private static let table: [String: Place] = {
        guard let url = Bundle.module.url(forResource: "zips-us", withExtension: "tsv"), let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var t = [String: Place](minimumCapacity: 41_000)
        for line in text.split(separator: "\n") {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false)
            if c.count == 3 { t[String(c[0])] = Place(city: String(c[1]), state: String(c[2])) }
        }
        return t
    }()

    /// The city and state of a ZIP code ("62701", or "62701-1234"), nil when it is not five digits or is not in the table.
    public static func place(for zip: String) -> Place? {
        let t = zip.trimmingCharacters(in: .whitespaces)
        guard t.range(of: "^[0-9]{5}(-?[0-9]{4})?$", options: .regularExpression) != nil else { return nil }
        return table[String(t.prefix(5))]
    }
}
