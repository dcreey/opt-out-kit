import SwiftUI
import OptOutKitCore

/// What automatic protection does, in plain words. Shown at first use and in Settings, before anything is switched on.
struct AutoExplainer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Every day, it checks the sites it can for your name.", systemImage: "dot.radiowaves.left.and.right")
            Label("Every week, it sends opt-out requests. For each site where we found the opt-out form, it fills that form in with only what it asks for (like name, email and city) and sends it. If a recent look found you are not listed there, it sends nothing.", systemImage: "paperplane")
            Label("It never solves a CAPTCHA, never makes an account or pays, and leaves anything that needs a login, ID, a phone call or a certification to you. Some sites email you a link to confirm; that click is yours.", systemImage: "hand.raised")
            Label("Most sites guard their forms with bot checks, so expect many to need you. The app tells you which.", systemImage: "info.circle")
            Label("It runs when the app is open and, when iOS allows, in the background. You can turn either off any time.", systemImage: "switch.2")
        }
        .font(.footnote)
    }
}

/// The two switches. Used by the first-run page, the Queue banner and Settings.
struct AutoToggles: View {
    @Binding var scan: Bool
    @Binding var optOut: Bool

    var body: some View {
        Toggle("Check for my listings every day", isOn: $scan).accessibilityIdentifier("auto-scan-toggle")
        Toggle("Send opt-out requests every week", isOn: $optOut).accessibilityIdentifier("auto-optout-toggle")
    }
}

struct AutoProtectionView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scan = true
    @State private var optOut = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AutoExplainer()
                }
                Section {
                    AutoToggles(scan: $scan, optOut: $optOut)
                }
                Section {
                    Button("Turn on") { model.setAuto(scan: scan, optOut: optOut); dismiss() }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("auto-turn-on")
                    Button("Not now") { model.setAuto(scan: false, optOut: false); dismiss() }
                        .accessibilityIdentifier("auto-not-now")
                } footer: {
                    Text("Only family members you added are included, and minors and public figures are never searched (opt-out requests still go out for them).")
                }
            }
            .navigationTitle("Automatic protection")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The automatic opt-out: one button, working in the background. It only asks the person about the sites that did not go through,
/// and those move to semi-automated or guided.
struct AutoActivityView: View {
    @EnvironmentObject var model: AppModel
    /// The sites a plan task says this run handles, listed at the bottom when it is opened from the plan.
    var handles: [String] = []

    private var rows: [AppModel.AutoOptOutRow] { model.selectedPerson.flatMap { model.optOutRun[$0.id] } ?? [] }
    private var busy: Bool { model.autoBusy == "optout" }

    private func isSent(_ r: AppModel.AutoOptOutRow) -> Bool { if case .submitted = r.result { return true } else { return false } }
    /// The ones the person has to do something about.
    private func needsPerson(_ r: AppModel.AutoOptOutRow) -> Bool {
        switch r.result { case .challenged, .needsYou, .needsData, .rejected, .failed: return true; default: return false }
    }

    var body: some View {
        List {
            if let person = model.selectedPerson {
                Section {
                    if busy {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Working in the background", systemImage: "hourglass").font(.headline)
                            if let p = model.autoProgress {
                                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                                Text("\(p.done) of \(p.total) sites. You can leave this screen.").font(.footnote).foregroundStyle(.secondary)
                            } else {
                                ProgressView()
                            }
                        }
                        .accessibilityIdentifier("auto-working")
                    }
                    Button { model.runAutomaticNow() } label: {
                        Label(busy ? Loc.t("Working…") : Loc.t("Run now"), systemImage: "bolt.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(busy)
                    .accessibilityIdentifier("auto-run-now")
                    if let last = model.autoSettings.lastOptOut {
                        Text("Last run: \(Loc.date(last, time: true))").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text(person.displayName) } footer: {
                    Text("It fills in and sends each form in the background, with no website opened. You are only asked about a site if it does not go through, and that site then moves to semi-automated or guided.")
                }
                if !rows.isEmpty {
                    let sent = rows.filter(isSent).count
                    let attention = rows.filter(needsPerson)
                    Section {
                        Text("Sent \(sent) of \(rows.count) sites. \(attention.count) need you.").font(.headline).accessibilityIdentifier("auto-summary")
                    }
                    if !attention.isEmpty {
                        Section("Needs you (\(attention.count))") {
                            ForEach(attention) { r in
                                if let entry = model.directory.first(where: { $0.id == r.id }) {
                                    NavigationLink(value: entry) { attentionRow(r) }
                                } else { attentionRow(r) }
                            }
                        }
                    }
                    DisclosureGroup("Sent (\(sent))") {
                        ForEach(rows.filter(isSent)) { r in Text(r.domain).font(.footnote) }
                    }
                    let other = rows.filter { !isSent($0) && !needsPerson($0) }
                    if !other.isEmpty {
                        DisclosureGroup("Skipped or sent recently (\(other.count))") {
                            ForEach(other) { r in
                                VStack(alignment: .leading, spacing: 2) { Text(r.domain).font(.footnote); Text(r.result.label).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                } else if !busy {
                    Section { Text("Nothing has run yet for \(person.displayName).").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            if !handles.isEmpty {
                Section("Sites in this run (\(handles.count))") {
                    ForEach(handles, id: \.self) { Text($0).font(.footnote) }
                }
            }
        }
        .navigationTitle("Automatic opt-out")
        .navigationDestination(for: DirectoryEntry.self) { DirectoryInfoView(entry: $0) }
    }

    private func attentionRow(_ r: AppModel.AutoOptOutRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(r.domain)
            Text(r.result.label).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}
