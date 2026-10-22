import Foundation

public enum USStates {
    private static let names: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California", "CO": "Colorado",
        "CT": "Connecticut", "DE": "Delaware", "DC": "District of Columbia", "FL": "Florida", "GA": "Georgia",
        "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas",
        "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts",
        "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri", "MT": "Montana",
        "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico",
        "NY": "New York", "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma",
        "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota",
        "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont", "VA": "Virginia", "WA": "Washington",
        "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
    ]

    /// Full state name for a two-letter code, or the input back if it is already a name.
    public static func name(for state: String) -> String? {
        let t = state.trimmingCharacters(in: .whitespaces)
        if let n = names[t.uppercased()] { return n }
        return names.values.first { $0.caseInsensitiveCompare(t) == .orderedSame }
    }
}

public extension USStates {
    /// The two-letter code for a full state name ("California" gives "CA"), or nil.
    static func code(for name: String) -> String? {
        let t = name.trimmingCharacters(in: .whitespaces)
        if t.count == 2, Self.name(for: t) != nil { return t.uppercased() }
        return all.first { $0.name.caseInsensitiveCompare(t) == .orderedSame }?.code
    }

    /// Every state and DC, by name, for a picker.
    static var all: [(code: String, name: String)] { names.map { ($0.key, $0.value) }.sorted { $0.1 < $1.1 } }
}
