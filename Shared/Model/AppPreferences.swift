import SwiftUI
import OptOutKitCore

/// The preferences the app is running with (rows of its database: `StoredPreferences`), for the few places that are not given the model: the reminders and the
/// guide's `@Preference` flags. `AppModel` sets it when it starts; until then they are in memory.
enum AppPreferences {
    nonisolated(unsafe) static var current: Preferences = MemoryPreferences()
}

/// A flag or small value kept as a preference, the way `@AppStorage` kept it in UserDefaults: read when the view is made, written when it changes, and
/// `$name` is a binding to it.
@propertyWrapper
struct Preference<Value>: DynamicProperty {
    private let key: String
    @State private var value: Value

    init(wrappedValue: Value, _ key: String) {
        self.key = key
        _value = State(initialValue: (AppPreferences.current.object(forKey: key) as? Value) ?? wrappedValue)
    }

    var wrappedValue: Value {
        get { value }
        nonmutating set { value = newValue; AppPreferences.current.set(newValue, forKey: key) }
    }

    var projectedValue: Binding<Value> { Binding(get: { wrappedValue }, set: { wrappedValue = $0 }) }
}
