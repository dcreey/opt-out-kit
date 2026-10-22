import SwiftUI
import OptOutKitCore

/// Shown before anything is opted out for a person whose current address (or legal name, or the household email) is missing. It cannot
/// be finished until those are in, and it asks for as many previous addresses as the person can remember, because brokers list old
/// addresses too and a request with the wrong address finds nothing.
struct ProfileGateView: View {
    @EnvironmentObject var model: AppModel
    @State private var askedAboutPrevious = false
    @State private var askNow = false

    private var person: Person? { model.selectedPerson }
    private var ready: Bool { person.map(model.isReady) ?? false }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                banner
                if let person {
                    PersonEditorView(person: person)
                        .id(person.id)
                } else {
                    Text("Add a person first.")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { model.profileGateFinished(completed: false) }.accessibilityIdentifier("profile-gate-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { finish() }.disabled(!ready).accessibilityIdentifier("profile-gate-continue")
                }
            }
            .interactiveDismissDisabled(true)
            .confirmationDialog("Add previous addresses?", isPresented: $askNow, titleVisibility: .visible) {
                Button("Add more addresses") { }.accessibilityIdentifier("profile-gate-add-previous")
                Button("Continue without them") { model.profileGateFinished(completed: true) }.accessibilityIdentifier("profile-gate-skip-previous")
            } message: {
                Text("Brokers keep old addresses on file. The more places you have lived, the more listings we can find and remove. Scroll down to Previous addresses and add as many as you can remember.")
            }
        }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Before we opt anyone out", systemImage: "mappin.and.ellipse").font(.subheadline.bold())
            if let reason = model.incompleteReason {
                Text(reason).font(.footnote)
            } else {
                Text("Your details are in. Add your previous addresses below, as many as you can, then continue.").font(.footnote)
            }
            Text("We need the current address and legal name because every broker form asks for them. Previous addresses are optional but they find more listings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.accentColor.opacity(0.12))
        .accessibilityIdentifier("profile-gate-banner")
    }

    private func finish() {
        guard let person else { return }
        // Only the current address is on file: prompt once for the earlier ones before carrying on.
        if person.addresses.count < 2, !askedAboutPrevious {
            askedAboutPrevious = true
            askNow = true
        } else {
            model.profileGateFinished(completed: true)
        }
    }
}
