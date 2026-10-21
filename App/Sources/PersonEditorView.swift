import SwiftUI
import OptOutKitCore

/// Edits one person's profile. Changes save as you type, and everything is stored encrypted on this phone.
struct PersonEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var person: Person
    @State private var confirmDelete = false

    init(person: Person) { _person = State(initialValue: person) }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Stored encrypted on this phone. There is no server and no account; the app contacts only the broker sites you opt out of.",
                          systemImage: "lock.shield")
                    Text("If you lose your phone without a backup, this data is gone. Back up your phone as usual and it comes with it.")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .accessibilityIdentifier("privacy-note")
            }
            Section("Who") {
                TextField("Display name", text: $person.displayName).accessibilityIdentifier("field-display-name")
                if person.relationship != .me {
                    Picker("Relationship", selection: $person.relationship) {
                        ForEach(Relationship.allCases.filter { $0 != .me }, id: \.self) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("field-relationship")
                }
            }
            namesSection
            safetySection
            addressSection
            StringListSection(title: "Emails", hint: "Used for confirmation links. Use this person's own address.",
                              addLabel: "Add email", items: $person.emails, keyboard: .emailAddress)
            if !sharedEmailsForPerson.isEmpty {
                Text("Also used by someone else: \(sharedEmailsForPerson.sorted().joined(separator: ", ")). Some sites allow one opt-out per email.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            StringListSection(title: "Phones", hint: "Optional", addLabel: "Add phone",
                              items: $person.phones, keyboard: .phonePad)
            Section("Birthdate") {
                TextField("YYYY-MM-DD (optional)", text: Binding(
                    get: { person.birthdate ?? "" },
                    set: { person.birthdate = $0.isEmpty ? nil : $0 }))
                    .keyboardType(.numbersAndPunctuation)
                Text("Sent only to sites whose definition asks for it.").font(.footnote).foregroundStyle(.secondary)
            }
            if model.people.count > 1 {
                Section {
                    Button("Delete this person", role: .destructive) { confirmDelete = true }
                        .accessibilityIdentifier("delete-person")
                } footer: {
                    Text("Deletes their profile and progress from this phone.")
                }
            }
        }
        .navigationTitle(person.displayName.isEmpty ? "Profile" : person.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: person) { _, new in model.update(new) }
        .confirmationDialog("Delete \(person.displayName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.remove(person.id); dismiss() }
        }
    }

    /// Minors and public figures are never searched (several sites' terms forbid it). Both default to off.
    private var safetySection: some View {
        Section {
            Toggle("Under 18", isOn: $person.isMinor).accessibilityIdentifier("flag-minor")
            Toggle("Public figure (official or celebrity)", isOn: $person.isPublicFigure).accessibilityIdentifier("flag-public-figure")
            if !person.isMinor, person.isMinorNow() {
                Label("The birthdate says under 18, so this profile is treated as a minor.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Searching")
        } footer: {
            Text("Several people-search sites' terms don't allow searching for minors, public officials or celebrities. For these profiles Opt-Out Kit won't search sites or accept terms; opt-out forms still work.")
        }
    }

    private var sharedEmailsForPerson: Set<String> {
        model.sharedEmails.intersection(Set(person.emails.map { $0.lowercased() }))
    }

    private var namesSection: some View {
        Section {
            ForEach($person.names.indices, id: \.self) { i in
                VStack(alignment: .leading) {
                    Picker("Type", selection: $person.names[i].kind) {
                        ForEach(NameKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    TextField("Name", text: $person.names[i].name)
                        .accessibilityIdentifier("name-\(i)")
                }
            }
            .onDelete { person.names.remove(atOffsets: $0) }
            Button("Add name", systemImage: "plus") { person.names.append(NameEntry(kind: .nickname)) }
                .accessibilityIdentifier("add-name")
        } header: {
            Text("Names")
        } footer: {
            Text("Add every name you have been listed under: nicknames, previous legal names, maiden names, spelling variants. Add a relative by adding them as a person.")
        }
    }

    private var addressSection: some View {
        Section {
            ForEach($person.addresses.indices, id: \.self) { i in
                VStack(alignment: .leading) {
                    TextField("Street (optional)", text: Binding(
                        get: { person.addresses[i].street ?? "" },
                        set: { person.addresses[i].street = $0.isEmpty ? nil : $0 }))
                    HStack {
                        TextField("City", text: $person.addresses[i].city)
                        TextField("State", text: $person.addresses[i].state).frame(maxWidth: 70)
                    }
                    HStack {
                        TextField("From year", value: $person.addresses[i].fromYear, format: .number.grouping(.never))
                        TextField("To year", value: $person.addresses[i].toYear, format: .number.grouping(.never))
                    }.keyboardType(.numberPad)
                }
            }
            .onDelete { person.addresses.remove(atOffsets: $0) }
            Button("Add address", systemImage: "plus") { person.addresses.append(Address(city: "", state: "")) }
                .accessibilityIdentifier("add-address")
        } header: {
            Text("Addresses")
        } footer: {
            Text("Current first, then previous. City and state are enough; add a street only if you want it sent.")
        }
    }
}

/// A list of free-text values with add and swipe-to-delete.
struct StringListSection: View {
    let title: String
    let hint: String
    let addLabel: String
    @Binding var items: [String]
    var keyboard: UIKeyboardType = .default

    var body: some View {
        Section {
            ForEach(items.indices, id: \.self) { i in
                TextField(title, text: $items[i]).keyboardType(keyboard)
            }
            .onDelete { items.remove(atOffsets: $0) }
            Button(addLabel, systemImage: "plus") { items.append("") }
        } header: {
            Text(title)
        } footer: {
            Text(hint)
        }
    }
}
