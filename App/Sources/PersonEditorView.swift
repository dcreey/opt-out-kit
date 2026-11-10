import SwiftUI
import OptOutKitCore

/// Edits one person's profile. Nothing is saved while editing: the edits are kept in this screen and written once, when the person taps Done or Continue
/// or closes the screen. Everything is stored encrypted on this phone.
struct PersonEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var person: Person
    /// Told the person as typed, on every change, so a host's Done or Continue button can follow it. Cheap: it never writes the model.
    var onDraft: ((Person) -> Void)?
    /// The household email as typed (the owner's profile only); written with the rest when the editor is done.
    var onEmailDraft: ((String) -> Void)?
    @State private var email: String
    @State private var confirmDelete = false
    // The three parts of the legal name are edited separately; the stored name is them joined (see `Person.composeLegalName`).
    @State private var first: String
    @State private var middle: String
    @State private var last: String

    init(person: Person, contactEmail: String = "", onDraft: ((Person) -> Void)? = nil, onEmailDraft: ((String) -> Void)? = nil) {
        self.onDraft = onDraft
        self.onEmailDraft = onEmailDraft
        _email = State(initialValue: contactEmail)
        _person = State(initialValue: person)
        _first = State(initialValue: person.legalFirst)
        _middle = State(initialValue: person.legalMiddle)
        _last = State(initialValue: person.legalLast)
    }

    /// The one write: the profile and, on the owner's profile, the email, in a single save. Does nothing when nothing changed.
    private func commit() {
        let personChanged = model.household.people.first(where: { $0.id == person.id }) != person
        let emailChanged = person.relationship == .me && email != model.contactEmail
        if personChanged || emailChanged { model.saveProfile(person, contactEmail: emailChanged ? email : nil) }
    }

    private var formEmailOK: Bool { person.relationship == .me ? ContactEmail.isValid(email.trimmingCharacters(in: .whitespaces)) : model.formEmail != nil }

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
            StringListSection(title: "Other email addresses", hint: "Optional. Other addresses you have used. A form with more than one email box gets them in order, and any left over are listed in its message box, so a site can find you under any of them.",
                              addLabel: Loc.t("Add email"), items: $person.emails, keyboard: .emailAddress, identifier: "other-email")
            StringListSection(title: "Phones", hint: "Optional. Shown as (773) 633-1564 while you type; forms get plain digits.", addLabel: Loc.t("Add phone"),
                              items: $person.phones, keyboard: .phonePad, format: PhoneFormat.display, identifier: "phone")
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
        #if DEBUG
        // UI tests that fill in a profile do not drive the year menu: they get a birthdate unless a test asks to choose one (`-uitest-require-birthdate`).
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-uitest-reset"), !args.contains("-uitest-require-birthdate"), person.birthdate == nil { person.birthdate = "1985-03-14" }
        }
        #endif
        // The model is written only when the person taps Done or Continue (the host) or leaves the screen: never while typing or on leaving a field
        // (each write rebuilds the plan and saves the encrypted file). The host reads the live draft, so its Done button does not wait for a write.
        .onChange(of: person) { _, new in onDraft?(new) }
        .onChange(of: email) { _, new in if person.relationship == .me { onEmailDraft?(new) } }
        .onAppear { onDraft?(person); if person.relationship == .me { onEmailDraft?(email) } }
        .onDisappear { commit() }
        // Closing or leaving the app (home, the app switcher, a call) saves what is typed, so a first profile is never lost to the app being closed.
        .onChange(of: scenePhase) { _, phase in if phase != .active { commit() } }
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

    private func nameBinding<T>(_ i: Int, _ kp: WritableKeyPath<NameEntry, T>, default d: T) -> Binding<T> { RowField.binding($person.names, i, kp, default: d) }
    private func addressBinding<T>(_ i: Int, _ kp: WritableKeyPath<Address, T>, default d: T) -> Binding<T> { RowField.binding($person.addresses, i, kp, default: d) }

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
                if (person.countryCode ?? "US") == "US" {
                    StatePicker(state: currentAddress(\.state, default: "")).accessibilityIdentifier("current-state")
                } else {
                    TextField("Region (optional)", text: currentAddress(\.state, default: "")).frame(maxWidth: 150).accessibilityIdentifier("current-state")
                }
            }
            TextField((person.countryCode ?? "US") == "US" ? "ZIP code" : "Postal code", text: Binding(
                get: { person.addresses.first?.zip ?? "" },
                set: { v in
                    if person.addresses.isEmpty { person.addresses.append(Address(city: "", state: "")) }
                    person.addresses[0].zip = v.isEmpty ? nil : v
                }))
                .keyboardType(.numbersAndPunctuation).textContentType(.postalCode).accessibilityIdentifier("current-zip")
            BirthdatePicker(birthdate: $person.birthdate)
            if person.relationship == .me { emailRows }
            let missing = person.missingRequiredDetails + (person.relationship == .me && !formEmailOK ? [L10n.noun("Email address")] : [])
            if !missing.isEmpty {
                Label("Still needed: \(missing.joined(separator: ", ")).", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.red).accessibilityIdentifier("missing-details")
            }
        } header: {
            Text("Required: legal name, current address and birthdate")
        } footer: {
            Text("Sites find and remove records by legal name and address, and many ask for a birthdate, so every profile needs all three. Only the fields a site's form asks for are ever sent.")
        }
    }

    /// The household's one email, asked for on the owner's profile. It goes on every form for everyone.
    @ViewBuilder private var emailRows: some View {
        TextField("Your email address", text: $email)
            .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
            .textContentType(.emailAddress).accessibilityIdentifier("contact-email")
        Text(EmailExplainer.text).font(.footnote).foregroundStyle(.secondary)
    }

    // MARK: Other names and previous addresses

    private var otherNamesSection: some View {
        Section {
            ForEach(person.names.indices, id: \.self) { i in
                if person.names.indices.contains(i), person.names[i].kind != .legal {
                    VStack(alignment: .leading) {
                        Picker("Type", selection: nameBinding(i, \.kind, default: .nickname)) {
                            ForEach(NameKind.allCases.filter { $0 != .legal }, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        TextField("Name", text: nameBinding(i, \.name, default: ""))
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
                if i > 0, person.addresses.indices.contains(i) {
                    VStack(alignment: .leading) {
                        TextField("Street (optional)", text: Binding(
                            get: { addressBinding(i, \.street, default: nil).wrappedValue ?? "" },
                            set: { addressBinding(i, \.street, default: nil).wrappedValue = $0.isEmpty ? nil : $0 }))
                        HStack {
                            TextField("City", text: addressBinding(i, \.city, default: ""))
                            if (addressBinding(i, \.country, default: nil).wrappedValue ?? "US").uppercased() == "US" {
                                StatePicker(state: addressBinding(i, \.state, default: "")).accessibilityIdentifier("previous-state-\(i)")
                            } else {
                                TextField("Region", text: addressBinding(i, \.state, default: "")).frame(maxWidth: 110)
                            }
                        }
                        TextField("ZIP code", text: Binding(
                            get: { addressBinding(i, \.zip, default: nil).wrappedValue ?? "" },
                            set: { addressBinding(i, \.zip, default: nil).wrappedValue = $0.isEmpty ? nil : $0 }))
                            .keyboardType(.numbersAndPunctuation).textContentType(.postalCode)
                        HStack {
                            TextField("From year", value: addressBinding(i, \.fromYear, default: nil), format: .number.grouping(.never))
                            TextField("To year", value: addressBinding(i, \.toYear, default: nil), format: .number.grouping(.never))
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
    /// Reshapes what is typed (a phone number's brackets and dash); nil leaves it as typed.
    var format: ((String) -> String)?
    var identifier = ""

    var body: some View {
        Section {
            ForEach(items.indices, id: \.self) { i in
                TextField(title, text: Binding(get: { items.indices.contains(i) ? items[i] : "" },
                                               set: { if items.indices.contains(i) { items[i] = format?($0) ?? $0 } }))
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(keyboard == .emailAddress ? .never : nil)
                    .autocorrectionDisabled(keyboard == .emailAddress)
                    .accessibilityIdentifier(identifier.isEmpty ? "" : "\(identifier)-\(i)")
            }
            .onDelete { items.remove(atOffsets: $0) }
            Button(addLabel, systemImage: "plus") { items.append("") }
                .accessibilityIdentifier(identifier.isEmpty ? "" : "add-\(identifier)")
        } header: {
            Text(title)
        } footer: {
            Text(hint)
        }
    }
}

/// The same words wherever the app asks for the email, so what it does with it is always said the same way.
enum EmailExplainer {
    static let text = Loc.t("We put this one address, exactly as you typed it, on every opt-out form and data-deletion request. Many sites look you up by that exact address, so we never change it. Replies and confirmation links arrive in your normal inbox.")
}


/// The birthdate, chosen year first, then month, then day. Stored as "YYYY-MM-DD". Required: a profile is not complete without it.
struct BirthdatePicker: View {
    @Binding var birthdate: String?

    private var parts: (y: Int?, m: Int?, d: Int?) {
        let p = (birthdate ?? "").split(separator: "-").compactMap { Int($0) }
        return (p.count > 0 ? p[0] : nil, p.count > 1 ? p[1] : nil, p.count > 2 ? p[2] : nil)
    }
    private static let thisYear = Calendar.current.component(.year, from: Date())

    private func daysIn(_ y: Int, _ m: Int) -> Int {
        Calendar.current.range(of: .day, in: .month, for: Calendar.current.date(from: DateComponents(year: y, month: m, day: 1)) ?? Date())?.count ?? 31
    }

    private func set(y: Int?, m: Int?, d: Int?) {
        guard let y else { birthdate = nil; return }
        // A month or day is kept only once the part before it is chosen; a day that the new month does not have becomes its last day.
        guard let m else { birthdate = String(format: "%04d", y); return }
        let day = d.map { min($0, daysIn(y, m)) }
        birthdate = day.map { String(format: "%04d-%02d-%02d", y, m, $0) } ?? String(format: "%04d-%02d", y, m)
    }

    var body: some View {
        let p = parts
        VStack(alignment: .leading, spacing: 8) {
            Text("Birthdate").font(.subheadline.bold())
            // Three equal columns, each showing its own prompt ("Year", "Month", "Day") until chosen, so nothing wraps or floats above its neighbours.
            HStack(spacing: 4) {
                Picker("Year", selection: Binding(get: { p.y ?? 0 }, set: { set(y: $0 == 0 ? nil : $0, m: p.m, d: p.d) })) {
                    Text("Year").tag(0)
                    ForEach((1900...Self.thisYear).reversed(), id: \.self) { Text(String($0)).tag($0) }
                }.labelsHidden().frame(maxWidth: .infinity).accessibilityLabel("Year").accessibilityIdentifier("birth-year")
                Picker("Month", selection: Binding(get: { p.m ?? 0 }, set: { set(y: p.y, m: $0 == 0 ? nil : $0, d: p.d) })) {
                    Text("Month").tag(0)
                    ForEach(1...12, id: \.self) { Text(Calendar.current.monthSymbols[$0 - 1]).tag($0) }
                }.labelsHidden().frame(maxWidth: .infinity).accessibilityLabel("Month").disabled(p.y == nil).accessibilityIdentifier("birth-month")
                Picker("Day", selection: Binding(get: { p.d ?? 0 }, set: { set(y: p.y, m: p.m, d: $0 == 0 ? nil : $0) })) {
                    Text("Day").tag(0)
                    ForEach(1...daysIn(p.y ?? 2000, p.m ?? 1), id: \.self) { Text(String($0)).tag($0) }
                }.labelsHidden().frame(maxWidth: .infinity).accessibilityLabel("Day").disabled(p.m == nil).accessibilityIdentifier("birth-day")
            }
            .pickerStyle(.menu)
            Text("Sent only to sites whose form asks for it.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}


/// A menu of the fifty states and DC (two-letter code stored), with "State" shown until one is chosen. A stored value that is not a code (older data) is shown as it is.
struct StatePicker: View {
    @Binding var state: String

    var body: some View {
        let code = USStates.code(for: state) ?? ""
        Picker("State", selection: Binding(get: { code.isEmpty ? state : code }, set: { state = $0 })) {
            Text("State").tag("")
            if code.isEmpty, !state.isEmpty { Text(state).tag(state) }
            ForEach(USStates.all, id: \.code) { Text("\($0.name) (\($0.code))").tag($0.code) }
        }
        .pickerStyle(.menu).labelsHidden().fixedSize()
        .accessibilityLabel("State")
    }
}


/// A binding to one field of the row at index `i` of a list that survives the row being deleted. SwiftUI can still ask a row it is about to remove for its
/// value (or hand it one to store) after the array has already shrunk, and `list[i]` then traps ("Index out of range") and ends the app; this gives the
/// default and ignores the store instead.
enum RowField {
    static func binding<E, T>(_ list: Binding<[E]>, _ i: Int, _ kp: WritableKeyPath<E, T>, default d: T) -> Binding<T> {
        Binding(get: { list.wrappedValue.indices.contains(i) ? list.wrappedValue[i][keyPath: kp] : d },
                set: { if list.wrappedValue.indices.contains(i) { list.wrappedValue[i][keyPath: kp] = $0 } })
    }
}
