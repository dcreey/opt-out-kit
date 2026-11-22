import Foundation
import OptOutKitCore

extension Person {
    /// A name, phone, email or earlier address that was added and left empty is dropped when saving, so an accidental tap on "Add" leaves nothing behind.
    func prunedForSave() -> Person {
        var p = self
        func blank(_ s: String?) -> Bool { (s ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        p.names.removeAll { $0.kind != .legal && blank($0.name) }
        p.phones.removeAll { blank($0) }
        p.emails.removeAll { blank($0) }
        if blank(p.linkedIn) { p.linkedIn = nil }
        if p.addresses.count > 1 {
            p.addresses = [p.addresses[0]] + p.addresses.dropFirst().filter { !(blank($0.street) && blank($0.city) && blank($0.state) && blank($0.zip)) }
        }
        return p
    }
}
