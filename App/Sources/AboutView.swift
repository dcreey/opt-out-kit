import SwiftUI
import OptOutKitCore

struct AboutView: View {
    @EnvironmentObject var model: AppModel
    @State private var showApproval = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Replay the walkthrough", systemImage: "play.circle") { model.showWalkthrough() }
                        .accessibilityIdentifier("show-walkthrough")
                }
                Section("How it works") {
                    Text("Pick a site, follow its step cards in your own browser, and mark each step done. You do any CAPTCHA, phone or ID step yourself. The app never submits anything for you.")
                    Text("Brokers re-list people, so check back on opted-out sites.")
                }
                Section("Privacy") {
                    Text("Your information never leaves this phone, except to the sites you opt out of. There is no Opt-Out Kit server, no account, no analytics and no tracking.")
                    Text("What you enter is stored encrypted on this phone. If you lose your phone without a backup, it is gone. A normal iPhone backup carries it.")
                }
                if let lib = model.termsLibrary {
                    termsSection(lib)
                }
                Section("Open source") {
                    Text("Anyone can audit exactly what this app does.")
                    Link("View the code on GitHub", destination: AppInfo.repoURL)
                    Text("The repository is private until the pre-release checks finish.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Good to know") {
                    Text("Opt-Out Kit is not affiliated with any data broker and is not legal advice. Broker pages change often, so a step may need updating.")
                }
            }
            .accessibilityIdentifier("about-list")
            .navigationTitle("About")
        }
    }
}

extension AboutView {
    @ViewBuilder
    fileprivate func termsSection(_ lib: TermsLibrary) -> some View {
        Section {
            if model.termsActive, let approval = model.termsApproval {
                Label("On, since \(approval.approvedAt.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark.shield")
                    .accessibilityIdentifier("terms-status")
                Text("Opt-Out Kit presses \"I agree\" for you only when every paragraph of a site's terms is on a list a person reviewed.")
                    .font(.footnote)
                NavigationLink("Acceptance log (\(model.consentLog.count))") { ConsentLogView() }
                Button("Turn off", role: .destructive) { model.revokeTerms() }.accessibilityIdentifier("terms-off")
            } else if model.termsReviewedCount > 0 {
                Label("Off", systemImage: "shield").accessibilityIdentifier("terms-status")
                Button("Review and allow…") { showApproval = true }.accessibilityIdentifier("terms-review")
            } else {
                Label("Off", systemImage: "shield").accessibilityIdentifier("terms-status")
                Text("None of the \(lib.paragraphs.count) terms paragraphs we have collected has been reviewed by a person yet, so nothing can be accepted for you. Sites that need terms accepted stay in your hands.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Accepting site terms for you")
        } footer: {
            Text("Off unless you turn it on. It never accepts terms that ban automated access, and every acceptance is logged here on this phone.")
        }
        .sheet(isPresented: $showApproval) { TermsApprovalView() }
    }
}

struct TermsApprovalView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Some people-search sites show an \"I agree to our terms\" prompt before results. If you allow this, Opt-Out Kit presses that button for you, but only when every paragraph of the prompt and of the terms pages it links to is on a list that a person has read and judged acceptable.")
                    Text("Reviewed paragraphs: \(model.termsReviewedCount) of \(model.termsLibrary?.paragraphs.count ?? 0)").font(.footnote)
                }
                Section {
                    Text("In plain English, here is what these sites' terms say. It is a summary, not legal advice.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(TermsSummary.sections) { section in
                        DisclosureGroup(section.title) {
                            ForEach(section.bullets, id: \.self) { Text("• " + $0).font(.footnote) }
                        }
                    }
                    Text(TermsSummary.basis).font(.caption2).foregroundStyle(.secondary)
                } header: {
                    Text("What you would be agreeing to")
                }
                .accessibilityIdentifier("terms-tldr")
                Section("What stays off the table") {
                    Label("Terms that ban or imply automated access", systemImage: "nosign")
                    Label("Anything a reviewer ruled out", systemImage: "nosign")
                    Label("Any paragraph nobody has reviewed, including a changed one", systemImage: "nosign")
                }
                Section("You stay in control") {
                    Label("Approval covers this list version only; a change asks you again", systemImage: "arrow.triangle.2.circlepath")
                    Label("Every acceptance is logged on this phone", systemImage: "list.bullet.rectangle")
                    Label("Turn it off any time", systemImage: "hand.raised")
                }
                Section {
                    Button("Allow") { model.approveTerms(); dismiss() }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("terms-allow")
                } footer: {
                    Text("You are agreeing to those terms through this app. If you would rather read each site's terms yourself, leave this off.")
                }
            }
            .navigationTitle("Accept terms for you?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } } }
        }
    }
}

struct ConsentLogView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            if model.consentLog.isEmpty { Text("Nothing has been accepted for you yet.") }
            ForEach(Array(model.consentLog.enumerated().reversed()), id: \.offset) { _, e in
                VStack(alignment: .leading) {
                    Text(e.domain).font(.headline)
                    Text("\(e.date.formatted(date: .abbreviated, time: .shortened)) · \(e.paragraphs) paragraphs · list \(e.libraryVersion)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Acceptance log")
    }
}
