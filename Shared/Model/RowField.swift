import SwiftUI

/// A binding to one field of the row at index `i` of a list that survives the row being deleted. SwiftUI can still ask a row it is about to remove for its
/// value (or hand it one to store) after the array has already shrunk, and `list[i]` then traps ("Index out of range") and ends the app; this gives the
/// default and ignores the store instead.
enum RowField {
    static func binding<E, T>(_ list: Binding<[E]>, _ i: Int, _ kp: WritableKeyPath<E, T>, default d: T) -> Binding<T> {
        Binding(get: { list.wrappedValue.indices.contains(i) ? list.wrappedValue[i][keyPath: kp] : d },
                set: { if list.wrappedValue.indices.contains(i) { list.wrappedValue[i][keyPath: kp] = $0 } })
    }
}
