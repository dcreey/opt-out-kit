import Foundation

/// Everything the app knows about a person that can be put into a form box, grouped the way a person looks for it.
/// The "My data" entry in every flow's … menu lists these; tapping one copies it so it can be pasted into any box.
public enum DetailKind: String, CaseIterable, Sendable { case name, email, phone, address, birthdate }

public struct DetailGroup: Equatable, Sendable {
    public let kind: DetailKind
    /// The values to offer, in the order to show them; each is exactly what is typed into the box. Never empty, never repeated.
    public let values: [String]
}

public enum DetailChoices {
    /// - Parameter email: the address the person uses for forms (the household's), offered first.
    public static func groups(for person: Person, email: String? = nil) -> [DetailGroup] {
        var out: [DetailGroup] = []
        func add(_ kind: DetailKind, _ values: [String]) {
            var seen = Set<String>(); var list: [String] = []
            for v in values.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !v.isEmpty && seen.insert(v.lowercased()).inserted { list.append(v) }
            if !list.isEmpty { out.append(DetailGroup(kind: kind, values: list)) }
        }

        // Name: the full legal name only.
        var names = [person.legalName]
        if names.allSatisfy({ $0.isEmpty }) { names = [person.displayName] }
        add(.name, names)

        add(.email, [email ?? ""] + person.emails)
        add(.phone, person.phones)

        var addresses: [String] = []
        for a in person.addresses {
            let street = a.street ?? ""
            let region = [a.state, a.zip ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            addresses.append([street, a.city, region].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        add(.address, addresses)

        if let b = person.birthdate, b.count == 10 {
            let p = b.split(separator: "-").map(String.init)
            if p.count == 3 { add(.birthdate, ["\(p[1])/\(p[2])/\(p[0])"]) }
        }
        return out
    }
}
