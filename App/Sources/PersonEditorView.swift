import SwiftUI
import OptOutKitCore

/// Edits one person's profile. Changes save as you type, and everything is stored encrypted on this phone.
struct PersonEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var person: Person
    @State private var confirmDelete = false
    // The three parts of the legal name are edited separately; the stored name is them joined (see `Person.composeLegalName`).
    @State private var first: String
    @State private var middle: String
    @State private var last: String

    init(person: Person) {
        _person = State(initialValue: person)
        _first = State(initialValue: person.legalFirst)
        _middle = State(initialValue: person.legalMiddle)
        _last = State(initialValue: person.legalLast)
    }

    private func commit() {
        if model.household.people.first(where: { $0.id == person.id }) != person { model.update(person) }
    }

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
            requiredSection
            safetySection
            otherNamesSection
            previousAddressesSection
            if person.relationship != .me {
                Section("Email") {
                    Text(model.formEmail.map { Loc.f("Opt-out forms for %@ use your address, %@. Replies come to you.", person.displayName, $0) }
                         ?? Loc.t("Opt-out forms use the email address on your own profile. Add it there first."))
                        .font(.footnote)
                }
            }
            StringListSection(title: "Phones", hint: "Optional", addLabel: Loc.t("Add phone"),
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
        // Save once typing pauses, and again on leaving. Saving per keystroke rewrote the encrypted file and rebuilt the plan for every site each time.
        .task(id: person) {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { commit() }
        }
        .onDisappear { commit() }
        .confirmationDialog(Loc.f("Delete %@?", person.displayName), isPresented: $confirmDelete, titleVisibility: .visible) {
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
            Text("Several people-search sites' terms don't allow searching for minors, public officials or celebrities. For these profiles Exnay won't search sites or accept terms; opt-out forms still work.")
        }
    }

    private var sharedEmailsForPerson: Set<String> {
        model.sharedEmails.intersection(Set(person.emails.map { $0.lowercased() }))
    }

    // MARK: Required details

    /// Index of the legal name entry, creating it first if the profile has none (older profiles may not).
    private func legalIndex() -> Int {
        if let i = person.names.firstIndex(where: { $0.kind == .legal }) { return i }
        person.names.insert(NameEntry(kind: .legal), at: 0)
        return 0
    }

    /// One part of the legal name. A middle name is kept out of the stored name until there is a last name, so it is never mistaken for one.
    private func legalBinding(_ get: @escaping () -> String, _ set: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: get, set: { new in
            set(new)
            person.names[legalIndex()].name = Person.composeLegalName(first: first, middle: last.trimmingCharacters(in: .whitespaces).isEmpty ? "" : middle, last: last)
        })
    }

    private func currentAddress<T>(_ keyPath: WritableKeyPath<Address, T>, default value: T) -> Binding<T> {
        Binding(get: { person.addresses.first?[keyPath: keyPath] ?? value },
                set: { new in
                    if person.addresses.isEmpty { person.addresses.append(Address(city: "", state: "")) }
                    person.addresses[0][keyPath: keyPath] = new
                })
    }

    /// Every profile needs a legal name and a current address: sites match on them, and a form cannot be filled without them.
    private var requiredSection: some View {
        Section {
            TextField("Legal first name", text: legalBinding({ first }, { first = $0 }))
                .textContentType(.givenName).accessibilityIdentifier("legal-first")
            TextField("Legal middle name (optional)", text: legalBinding({ middle }, { middle = $0 }))
                .textContentType(.middleName).accessibilityIdentifier("legal-middle")
            TextField("Legal last name", text: legalBinding({ last }, { last = $0 }))
                .textContentType(.familyName).accessibilityIdentifier("legal-last")
            TextField("Street", text: Binding(
                get: { person.addresses.first?.street ?? "" },
                set: { v in
                    if person.addresses.isEmpty { person.addresses.append(Address(city: "", state: "")) }
                    person.addresses[0].street = v.isEmpty ? nil : v
                }))
                .accessibilityIdentifier("current-street")
            Picker("Country", selection: Binding(
                get: { person.countryCode ?? model.ownerCountry ?? "US" },
                set: { code in
                    if person.addresses.isEmpty { person.addresses.append(Address(city: "", state: "")) }
                    person.addresses[0].country = code
                    if code != "US" { person.addresses[0].state = "" }
                })) {
                ForEach(model.countryOptions, id: \.code) { Text($0.name).tag($0.code) }
            }.accessibilityIdentifier("current-country")
            HStack {
                TextField("City", text: currentAddress(\.city, default: "")).accessibilityIdentifier("current-city")
                TextField((person.countryCode ?? "US") == "US" ? "State" : "Region (optional)", text: currentAddress(\.state, default: "")).frame(maxWidth: (person.countryCode ?? "US") == "US" ? 70 : 150).accessibilityIdentifier("current-state")
            }
            TextField((person.countryCode ?? "US") == "US" ? "ZIP code" : "Postal code", text: Binding(
                get: { person.addresses.first?.zip ?? "" },
                set: { v in
                    if person.addresses.isEmpty { person.addresses.append(Address(city: "", state: "")) }
                    person.addresses[0].zip = v.isEmpty ? nil : v
                }))
                .keyboardType(.numbersAndPunctuation).textContentType(.postalCode).accessibilityIdentifier("current-zip")
            if person.relationship == .me { emailRows }
            let missing = person.missingRequiredDetails + (person.relationship == .me && model.formEmail == nil ? [L10n.noun("Email address")] : [])
            if !missing.isEmpty {
                Label("Still needed: \(missing.joined(separator: ", ")).", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.red).accessibilityIdentifier("missing-details")
            }
        } header: {
            Text("Required: legal name and current address")
        } footer: {
            Text("Sites find and remove records by legal name and address, so every profile needs both. Only the fields a site's form asks for are ever sent.")
        }
    }

    /// The household's one email, asked for on the owner's profile. It goes on every form for everyone.
    @ViewBuilder private var emailRows: some View {
        TextField("Your email address", text: Binding(get: { model.contactEmail }, set: { model.setContactEmail($0) }))
            .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
            .textContentType(.emailAddress).accessibilityIdentifier("contact-email")
        Text(EmailExplainer.text).font(.footnote).foregroundStyle(.secondary)
    }

    // MARK: Other names and previous addresses

    private var otherNamesSection: some View {
        Section {
            ForEach(person.names.indices, id: \.self) { i in
                if person.names[i].kind != .legal {
                    VStack(alignment: .leading) {
                        Picker("Type", selection: $person.names[i].kind) {
                            ForEach(NameKind.allCases.filter { $0 != .legal }, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        TextField("Name", text: $person.names[i].name)
                            .accessibilityIdentifier("name-\(i)")
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets.sorted(by: >) where person.names.indices.contains(i) && person.names[i].kind != .legal { person.names.remove(at: i) }
            }
            Button("Add name", systemImage: "plus") {
                _ = legalIndex()
                person.names.append(NameEntry(kind: .nickname))
            }
            .accessibilityIdentifier("add-name")
        } header: {
            Text("Other names")
        } footer: {
            Text("Add every other name you have been listed under: nicknames, previous legal names, maiden names, spelling variants. Add a relative by adding them as a person.")
        }
    }

    private var previousAddressesSection: some View {
        Section {
            ForEach(person.addresses.indices, id: \.self) { i in
                if i > 0 {
                    VStack(alignment: .leading) {
                        TextField("Street (optional)", text: Binding(
                            get: { person.addresses[i].street ?? "" },
                            set: { person.addresses[i].street = $0.isEmpty ? nil : $0 }))
                        HStack {
                            TextField("City", text: $person.addresses[i].city)
                            TextField("State", text: $person.addresses[i].state).frame(maxWidth: 70)
                        }
                        TextField("ZIP code", text: Binding(
                            get: { person.addresses[i].zip ?? "" },
                            set: { person.addresses[i].zip = $0.isEmpty ? nil : $0 }))
                            .keyboardType(.numbersAndPunctuation).textContentType(.postalCode)
                        HStack {
                            TextField("From year", value: $person.addresses[i].fromYear, format: .number.grouping(.never))
                            TextField("To year", value: $person.addresses[i].toYear, format: .number.grouping(.never))
                        }.keyboardType(.numberPad)
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets.sorted(by: >) where i > 0 && person.addresses.indices.contains(i) { person.addresses.remove(at: i) }
            }
            Button("Add previous address", systemImage: "plus") {
                if person.addresses.isEmpty { person.addresses.append(Address(city: "", state: "")) }
                person.addresses.append(Address(city: "", state: ""))
            }
            .accessibilityIdentifier("add-address")
        } header: {
            Text("Previous addresses")
        } footer: {
            Text("Most recent first. City and state are enough; add a street only if you want it sent.")
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

/// The same words wherever the app asks for the email, so what it does with it is always said the same way.
enum EmailExplainer {
    static let text = Loc.t("We put this one address, exactly as you typed it, on every opt-out form and data-deletion request, for you and everyone you add. Many sites look you up by that exact address, so we never change it. Replies and confirmation links arrive in your normal inbox.")
}
