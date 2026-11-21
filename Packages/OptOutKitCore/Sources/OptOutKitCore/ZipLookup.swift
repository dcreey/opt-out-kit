import Foundation

/// The place a US ZIP code belongs to, from the table compiled into the app's catalog (`Catalog`, the `zips` table: found by key, none held in memory),
/// so what is typed never leaves the phone. Data: GeoNames postal codes, geonames.org, Creative Commons Attribution 4.0; 40,977 ZIP codes of the fifty
/// states and DC (military and territory codes are left out). The source is data/zips-us.tsv.
public enum ZipLookup {
    public struct Place: Equatable, Sendable {
        public let city: String
        public let state: String
        public init(city: String, state: String) { self.city = city; self.state = state }
    }

    /// The city and state of a ZIP code ("62701", or "62701-1234"), nil when it is not five digits or is not in the table.
    public static func place(for zip: String) -> Place? {
        let t = zip.trimmingCharacters(in: .whitespaces)
        guard t.range(of: "^[0-9]{5}(-?[0-9]{4})?$", options: .regularExpression) != nil else { return nil }
        return Catalog.zip(String(t.prefix(5))).map { Place(city: $0.city, state: $0.state) }
    }
}
